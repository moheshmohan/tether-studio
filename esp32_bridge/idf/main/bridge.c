// ZV-E10 Wi-Fi bridge for an ESP32-C3 on its built-in USB port, on ESP-IDF.
//
// The camera's phone service only exists on the camera's own DIRECT-... Wi-Fi network. This board joins that
// network and carries TCP connections between the camera and the computer on the USB cable, so the computer's
// own Wi-Fi can stay on the router. The computer side is relay.py one folder up, or the Tether Studio app.
//
// Same USB protocol as the Arduino version (esp32_bridge.ino), which this replaces for speed:
//   frame = A5 5A  type  channel  length(2, little endian)  check  payload
//   check = type ^ channel ^ length low ^ length high ^ FF
//
// The Wi-Fi name and password arrive over USB and are kept in memory only (WIFI_STORAGE_RAM).
//
// Build and flash (ESP-IDF 5.3):  idf.py -p /dev/cu.usbmodemXXXX flash
#include <errno.h>
#include <fcntl.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "driver/usb_serial_jtag.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "lwip/priv/tcp_priv.h"
#include "lwip/sockets.h"
#include "lwip/tcpip.h"
#include "nvs_flash.h"

#define VERSION 5
#define CHANNELS 6
#define MAX_PAYLOAD 4096
#define HOST_WRITE_TIMEOUT_MS 3000
#define CAMERA_WRITE_TIMEOUT_S 10
#define CONNECT_TIMEOUT_S 5

enum {
    T_WIFI = 0x01,    // payload: name, 0, password        -> R_WIFI
    T_OPEN = 0x02,    // payload: IPv4 (4), port (2, LE)   -> R_OPENED
    T_DATA = 0x03,    // payload: bytes for the connection
    T_CLOSE = 0x04,   //                                   -> R_CLOSED
    T_STATUS = 0x05,  //                                   -> R_HELLO, R_WIFI
    T_ECHO = 0x06,    // payload: anything                 -> R_ECHO with the same payload
    T_SCAN = 0x07,    //                                   -> R_SCAN (takes a few seconds)
    T_FLOOD = 0x08,   // payload: frame count (2, LE)      -> that many full R_FLOOD frames, for a speed test
    T_DRAIN = 0x09,   // count what the camera sends next and throw it away -> R_DRAIN once it has stopped for 1 s
    R_WIFI = 0x81,    // payload: state, reason, IP (4), gateway (4), signal (int8)
    R_OPENED = 0x82,  // payload: 1 connected, 0 failed
    R_DATA = 0x83,
    R_CLOSED = 0x84,
    R_ECHO = 0x86,
    R_SCAN = 0x87,    // payload: count (FF = failed), then per network: signal (int8), channel, security, name length, name
    R_HELLO = 0x88,   // payload: version, boot id (4)
    R_FLOOD = 0x89,
    R_DRAIN = 0x8A,   // payload: bytes (4, LE), microseconds from the first to the last of them (4, LE)
};
enum { WIFI_IDLE = 0, WIFI_JOINING = 1, WIFI_JOINED = 2 };
enum { CLOSE_NONE = 0, CLOSE_AND_TELL = 1, CLOSE_QUIETLY = 2 };

static int socks[CHANNELS];                   // -1 = free. Only the network task closes sockets.
static volatile uint8_t close_request[CHANNELS];
static SemaphoreHandle_t channel_lock;
static SemaphoreHandle_t usb_lock;            // one frame at a time on USB
static uint8_t frame_out[7 + MAX_PAYLOAD];    // under usb_lock
static volatile bool host_active;             // a valid frame has arrived and writes to the host have not failed since
static volatile bool wifi_started, wifi_has_address, wifi_changed;
static volatile uint8_t last_reason;
static char wifi_name[33];
static esp_netif_t *netif;
static uint32_t boot_id;
// Speed test of the Wi-Fi side alone (T_DRAIN): bytes from the camera are counted, not passed on.
static volatile bool draining;
static uint32_t drain_bytes;                  // network task only, while draining
static int64_t drain_first, drain_last;

// ---- USB side -----------------------------------------------------------------------------------------------

static void send_frame(uint8_t type, uint8_t channel, const uint8_t *payload, size_t length) {
    if (!host_active) return;
    xSemaphoreTake(usb_lock, portMAX_DELAY);
    frame_out[0] = 0xA5;
    frame_out[1] = 0x5A;
    frame_out[2] = type;
    frame_out[3] = channel;
    frame_out[4] = (uint8_t)length;
    frame_out[5] = (uint8_t)(length >> 8);
    frame_out[6] = type ^ channel ^ frame_out[4] ^ frame_out[5] ^ 0xFF;
    if (length) memcpy(frame_out + 7, payload, length);
    // All or nothing: 0 means nobody has read the USB port for the whole timeout.
    if (usb_serial_jtag_write_bytes(frame_out, 7 + length, pdMS_TO_TICKS(HOST_WRITE_TIMEOUT_MS)) == 0) {
        host_active = false;                  // the network task then drops every connection
    }
    xSemaphoreGive(usb_lock);
}

static uint8_t wifi_state(void) {
    if (!wifi_started) return WIFI_IDLE;
    return wifi_has_address ? WIFI_JOINED : WIFI_JOINING;
}

static void send_wifi(void) {
    uint8_t p[11] = {0};
    p[0] = wifi_state();
    p[1] = last_reason;
    if (p[0] == WIFI_JOINED) {
        esp_netif_ip_info_t ip;
        wifi_ap_record_t ap;
        if (esp_netif_get_ip_info(netif, &ip) == ESP_OK) {
            memcpy(p + 2, &ip.ip.addr, 4);    // already in network order: a.b.c.d
            memcpy(p + 6, &ip.gw.addr, 4);
        }
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) p[10] = (uint8_t)ap.rssi;
    }
    send_frame(R_WIFI, 0, p, sizeof p);
}

static void send_hello(void) {
    uint8_t p[5] = {VERSION, (uint8_t)boot_id, (uint8_t)(boot_id >> 8), (uint8_t)(boot_id >> 16), (uint8_t)(boot_id >> 24)};
    send_frame(R_HELLO, 0, p, sizeof p);
}

// ---- Wi-Fi --------------------------------------------------------------------------------------------------

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        uint8_t reason = ((wifi_event_sta_disconnected_t *)data)->reason;
        if (reason != WIFI_REASON_ASSOC_LEAVE) last_reason = reason;      // "leave" is this program's own doing
        wifi_has_address = false;
        wifi_changed = true;
        if (wifi_started) esp_wifi_connect();                             // keep trying: the camera's network comes and goes
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        wifi_has_address = true;
        wifi_changed = true;
    }
}

static void close_all(uint8_t how) {
    for (int ch = 0; ch < CHANNELS; ch++) {
        if (socks[ch] >= 0) close_request[ch] = how;
    }
}

static void join(const uint8_t *p, size_t length) {
    size_t split = 0;
    while (split < length && p[split]) split++;
    size_t pass_length = split < length ? length - split - 1 : 0;
    wifi_config_t config = {0};
    if (split > 32 || pass_length > 63) return;
    memcpy(config.sta.ssid, p, split);
    if (pass_length) memcpy(config.sta.password, p + split + 1, pass_length);
    config.sta.pmf_cfg.capable = true;

    bool same = strlen(wifi_name) == split && memcmp(wifi_name, p, split) == 0;
    if (!(wifi_started && wifi_has_address && same)) {
        close_all(CLOSE_QUIETLY);
        wifi_started = false;                 // so the disconnect below does not start a reconnect with the old details
        esp_wifi_disconnect();
        last_reason = 0;
        wifi_has_address = false;
        memcpy(wifi_name, p, split);
        wifi_name[split] = 0;
        esp_wifi_set_config(WIFI_IF_STA, &config);
        wifi_started = true;
        esp_wifi_connect();
    }
    send_wifi();
}

static void scan(void) {
    static uint8_t out[MAX_PAYLOAD];
    static wifi_ap_record_t found[40];
    if (wifi_started && !wifi_has_address) {
        wifi_started = false;                 // a scan cannot run while the radio keeps trying to join
        esp_wifi_disconnect();
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    uint16_t count = 40;
    size_t fill = 1;
    out[0] = 0xFF;
    if (esp_wifi_scan_start(NULL, true) == ESP_OK && esp_wifi_scan_get_ap_records(&count, found) == ESP_OK) {
        out[0] = (uint8_t)count;
        for (int i = 0; i < count; i++) {
            size_t n = strnlen((const char *)found[i].ssid, 32);
            out[fill++] = (uint8_t)found[i].rssi;
            out[fill++] = found[i].primary;
            out[fill++] = (uint8_t)found[i].authmode;
            out[fill++] = (uint8_t)n;
            memcpy(out + fill, found[i].ssid, n);
            fill += n;
        }
    }
    send_frame(R_SCAN, 0, out, fill);
}

// ---- TCP side -----------------------------------------------------------------------------------------------

// The camera sends a short answer as several small packets and holds each one back until the packet before
// it has been acknowledged. The network stack delays acknowledgements by up to 250 ms (measured: every short
// command took 250 ms), so pending acknowledgements are sent as soon as the data has been taken.
static void acknowledge_now(void) {
    LOCK_TCPIP_CORE();
    for (struct tcp_pcb *pcb = tcp_active_pcbs; pcb != NULL; pcb = pcb->next) {
        if (pcb->flags & TF_ACK_DELAY) {
            tcp_ack_now(pcb);
            tcp_output(pcb);
        }
    }
    UNLOCK_TCPIP_CORE();
}

static int open_socket(const uint8_t *p) {
    struct sockaddr_in to = {.sin_family = AF_INET, .sin_port = htons((uint16_t)(p[4] | (p[5] << 8)))};
    memcpy(&to.sin_addr.s_addr, p, 4);
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    int flags = fcntl(s, F_GETFL, 0);
    fcntl(s, F_SETFL, flags | O_NONBLOCK);
    int result = connect(s, (struct sockaddr *)&to, sizeof to);
    if (result != 0 && errno == EINPROGRESS) {
        fd_set writable;
        FD_ZERO(&writable);
        FD_SET(s, &writable);
        struct timeval wait = {.tv_sec = CONNECT_TIMEOUT_S};
        result = -1;
        if (select(s + 1, NULL, &writable, NULL, &wait) == 1) {
            int error = 0;
            socklen_t size = sizeof error;
            if (getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0) result = 0;
        }
    }
    if (result != 0) {
        close(s);
        return -1;
    }
    fcntl(s, F_SETFL, flags);                 // sends block, with a limit; reads use MSG_DONTWAIT
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    struct timeval limit = {.tv_sec = CAMERA_WRITE_TIMEOUT_S};
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof limit);
    return s;
}

static void handle_frame(uint8_t type, uint8_t ch, const uint8_t *p, size_t length) {
    host_active = true;
    switch (type) {
        case T_STATUS:
            send_hello();
            send_wifi();
            break;
        case T_ECHO:
            send_frame(R_ECHO, ch, p, length);
            break;
        case T_FLOOD: {
            static uint8_t pattern[MAX_PAYLOAD];
            uint16_t count = length >= 2 ? (uint16_t)(p[0] | (p[1] << 8)) : 0;
            for (size_t i = 0; i < MAX_PAYLOAD; i++) pattern[i] = (uint8_t)(i * 31 + 7);
            for (uint16_t i = 0; i < count && host_active; i++) send_frame(R_FLOOD, 0, pattern, MAX_PAYLOAD);
            break;
        }
        case T_DRAIN:
            draining = false;
            drain_bytes = 0;
            draining = true;
            break;
        case T_WIFI:
            join(p, length);
            break;
        case T_SCAN:
            scan();
            break;
        case T_OPEN: {
            if (ch >= CHANNELS) break;
            if (socks[ch] >= 0) {             // should not happen: the computer reuses a channel only after R_CLOSED
                close_request[ch] = CLOSE_QUIETLY;
                for (int i = 0; i < 100 && socks[ch] >= 0; i++) vTaskDelay(pdMS_TO_TICKS(5));
            }
            int s = length == 6 && wifi_has_address && socks[ch] < 0 ? open_socket(p) : -1;
            uint8_t ok = s >= 0;
            send_frame(R_OPENED, ch, &ok, 1); // before the network task can pass on anything from this connection
            if (s >= 0) {
                xSemaphoreTake(channel_lock, portMAX_DELAY);
                close_request[ch] = CLOSE_NONE;
                socks[ch] = s;
                xSemaphoreGive(channel_lock);
            }
            break;
        }
        case T_DATA: {
            if (ch >= CHANNELS) break;
            xSemaphoreTake(channel_lock, portMAX_DELAY);
            int s = close_request[ch] == CLOSE_NONE ? socks[ch] : -1;
            xSemaphoreGive(channel_lock);
            size_t done = 0;
            while (s >= 0 && done < length) {
                int sent = send(s, p + done, length - done, 0);
                if (sent <= 0) {
                    close_request[ch] = CLOSE_AND_TELL;
                    break;
                }
                done += (size_t)sent;
            }
            break;
        }
        case T_CLOSE:
            if (ch < CHANNELS) close_request[ch] = CLOSE_AND_TELL;        // answered by the network task
            break;
    }
}

static void usb_task(void *arg) {
    static uint8_t chunk[2048];
    static uint8_t payload[MAX_PAYLOAD];
    uint8_t header[7];
    size_t header_fill = 0, need = 0, got = 0;
    bool in_payload = false;
    for (;;) {
        int n = usb_serial_jtag_read_bytes(chunk, sizeof chunk, pdMS_TO_TICKS(50));
        int at = 0;
        while (at < n) {
            if (in_payload) {
                size_t take = need - got < (size_t)(n - at) ? need - got : (size_t)(n - at);
                memcpy(payload + got, chunk + at, take);
                got += take;
                at += (int)take;
                if (got == need) {
                    in_payload = false;
                    handle_frame(header[2], header[3], payload, need);
                }
                continue;
            }
            header[header_fill++] = chunk[at++];
            if (header_fill == 1 && header[0] != 0xA5) {
                header_fill = 0;
            } else if (header_fill == 2 && header[1] != 0x5A) {
                header_fill = header[1] == 0xA5 ? 1 : 0;
                header[0] = 0xA5;
            } else if (header_fill == 7) {
                header_fill = 0;
                if ((header[2] ^ header[3] ^ header[4] ^ header[5] ^ 0xFF) != header[6]) continue;
                need = (size_t)(header[4] | (header[5] << 8));
                if (need > MAX_PAYLOAD) continue;
                got = 0;
                if (need == 0) handle_frame(header[2], header[3], payload, 0);
                else in_payload = true;
            }
        }
    }
}

static void network_task(void *arg) {
    static uint8_t buffer[MAX_PAYLOAD];
    uint8_t reported = 0xFF;
    for (;;) {
        // Closing: asked for by the computer, or because the computer or the Wi-Fi network has gone.
        bool gone = !host_active || !wifi_has_address;
        for (int ch = 0; ch < CHANNELS; ch++) {
            uint8_t how = close_request[ch];
            if (how == CLOSE_NONE && !(gone && socks[ch] >= 0)) continue;
            xSemaphoreTake(channel_lock, portMAX_DELAY);
            int s = socks[ch];
            socks[ch] = -1;
            close_request[ch] = CLOSE_NONE;
            xSemaphoreGive(channel_lock);
            if (s >= 0) close(s);
            if (how == CLOSE_AND_TELL || (how == CLOSE_NONE && host_active)) send_frame(R_CLOSED, (uint8_t)ch, NULL, 0);
        }
        if (host_active && (wifi_changed || wifi_state() != reported)) {
            wifi_changed = false;
            reported = wifi_state();
            send_wifi();
        }

        if (draining && drain_bytes > 0 && esp_timer_get_time() - drain_last > 1000000) {
            uint32_t took = (uint32_t)(drain_last - drain_first);
            uint8_t p[8] = {(uint8_t)drain_bytes, (uint8_t)(drain_bytes >> 8), (uint8_t)(drain_bytes >> 16), (uint8_t)(drain_bytes >> 24),
                            (uint8_t)took, (uint8_t)(took >> 8), (uint8_t)(took >> 16), (uint8_t)(took >> 24)};
            draining = false;
            send_frame(R_DRAIN, 0, p, sizeof p);
        }

        fd_set readable;
        FD_ZERO(&readable);
        int highest = -1;
        for (int ch = 0; ch < CHANNELS; ch++) {
            if (socks[ch] >= 0) {
                FD_SET(socks[ch], &readable);
                if (socks[ch] > highest) highest = socks[ch];
            }
        }
        if (highest < 0) {
            vTaskDelay(pdMS_TO_TICKS(5));
            continue;
        }
        struct timeval wait = {.tv_usec = 10000};
        if (select(highest + 1, &readable, NULL, NULL, &wait) <= 0) continue;
        for (int ch = 0; ch < CHANNELS; ch++) {
            int s = socks[ch];
            if (s < 0 || !FD_ISSET(s, &readable)) continue;
            int n = recv(s, buffer, sizeof buffer, MSG_DONTWAIT);
            if (n > 0) {
                acknowledge_now();      // also while draining: without it the test measured 2.2–2.6 MB/s, with it 2.7–2.9
                if (draining) {
                    drain_last = esp_timer_get_time();
                    if (drain_bytes == 0) drain_first = drain_last;
                    drain_bytes += (uint32_t)n;
                } else {
                    send_frame(R_DATA, (uint8_t)ch, buffer, (size_t)n);
                }
            } else if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
                close_request[ch] = CLOSE_AND_TELL;   // the camera closed its end, and everything it sent has been passed on
            }
        }
    }
}

void app_main(void) {
    for (int ch = 0; ch < CHANNELS; ch++) socks[ch] = -1;
    channel_lock = xSemaphoreCreateMutex();
    usb_lock = xSemaphoreCreateMutex();
    boot_id = esp_random();

    usb_serial_jtag_driver_config_t usb = {.tx_buffer_size = 32768, .rx_buffer_size = 16384};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb));

    esp_err_t nvs = nvs_flash_init();         // the radio keeps its calibration here; the Wi-Fi details are not stored
    if (nvs == ESP_ERR_NVS_NO_FREE_PAGES || nvs == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    netif = esp_netif_create_default_wifi_sta();
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));      // never write the camera's Wi-Fi password to flash
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_wifi_event, NULL));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    esp_wifi_set_ps(WIFI_PS_NONE);            // no power saving: it adds up to 100 ms to every answer

    xTaskCreate(network_task, "network", 6144, NULL, 6, NULL);
    xTaskCreate(usb_task, "usb", 6144, NULL, 5, NULL);
}
