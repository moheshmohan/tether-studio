// ZV-E10 Wi-Fi bridge for an ESP32 with its own USB port (written for an ESP32-C3, USB-Serial/JTAG).
//
// The camera's phone service only exists on the camera's own DIRECT-... Wi-Fi network. This board joins that
// network and carries TCP connections between the camera and the computer on the USB cable, so the computer's
// own Wi-Fi can stay on the router. The computer side is relay.py in this folder.
//
// The Wi-Fi name and password arrive over USB each time relay.py starts and are kept in memory only.
//
// USB framing, both directions:  A5 5A  type  channel  length(2, little endian)  check  payload
//   check = type ^ channel ^ length low ^ length high ^ FF
//
// Build:  arduino-cli compile -b esp32:esp32:esp32c3:CDCOnBoot=cdc esp32_bridge
#include <WiFi.h>
#include "lwip/tcpip.h"
#include "lwip/priv/tcp_priv.h"

static const uint8_t MAGIC0 = 0xA5, MAGIC1 = 0x5A;
static const uint8_t VERSION = 3;
enum : uint8_t {
  T_WIFI = 0x01,    // payload: name, 0, password        -> R_WIFI
  T_OPEN = 0x02,    // payload: IPv4 (4), port (2, LE)   -> R_OPENED
  T_DATA = 0x03,    // payload: bytes for the connection
  T_CLOSE = 0x04,   //                                   -> R_CLOSED
  T_STATUS = 0x05,  //                                   -> R_HELLO, R_WIFI
  T_ECHO = 0x06,    // payload: anything                 -> R_ECHO with the same payload
  T_SCAN = 0x07,    //                                   -> R_SCAN (takes a few seconds)
  T_FLOOD = 0x08,   // payload: frame count (2, LE)      -> that many full R_FLOOD frames, for a speed test
  R_WIFI = 0x81,    // payload: state, reason, IP (4), gateway (4), signal (int8)
  R_OPENED = 0x82,  // payload: 1 connected, 0 failed
  R_DATA = 0x83,
  R_CLOSED = 0x84,
  R_ECHO = 0x86,
  R_SCAN = 0x87,    // payload: count (FF = scan failed), then per network: signal (int8), channel, security, name length, name
  R_HELLO = 0x88,   // payload: version, boot id (4)
  R_FLOOD = 0x89,
};
enum : uint8_t { WIFI_IDLE = 0, WIFI_JOINING = 1, WIFI_JOINED = 2 };

static const int CHANNELS = 6;
static const size_t MAX_PAYLOAD = 4096;
static const uint32_t HOST_WRITE_TIMEOUT_MS = 3000;
static const uint32_t CAMERA_WRITE_TIMEOUT_MS = 10000;

static WiFiClient clients[CHANNELS];
static bool isOpen[CHANNELS];
static uint8_t rxPayload[MAX_PAYLOAD];
static uint8_t txPayload[MAX_PAYLOAD];
static uint8_t header[7];
static size_t headerFill = 0, payloadNeed = 0, payloadGot = 0;
static bool inPayload = false;
static bool hostActive = false;      // a valid frame has arrived and writes to the host have not failed since
static bool wifiStarted = false;
static volatile uint8_t lastReason = 0;
static uint8_t reportedState = 0xFF;
static uint32_t bootId = 0;
static String wifiName;

static bool writeAll(const uint8_t *data, size_t length) {
  uint32_t last = millis();
  while (length) {
    size_t sent = Serial.write(data, length);
    if (sent) {
      data += sent;
      length -= sent;
      last = millis();
    } else {
      if (millis() - last > HOST_WRITE_TIMEOUT_MS) return false;
      delay(1);
    }
  }
  return true;
}

// The camera sends a short answer as several small packets and holds each one back until the packet
// before it has been acknowledged. This board's network stack delays its acknowledgements by up to 250 ms
// (measured: every short command took 250 ms), and that delay is fixed in the prebuilt Arduino libraries.
// So the main loop sends every pending acknowledgement at once instead.
static void acknowledgeNow() {
  LOCK_TCPIP_CORE();
  for (struct tcp_pcb *pcb = tcp_active_pcbs; pcb != NULL; pcb = pcb->next) {
    if (pcb->flags & TF_ACK_DELAY) {
      tcp_ack_now(pcb);
      tcp_output(pcb);
    }
  }
  UNLOCK_TCPIP_CORE();
}

static void closeAll() {
  for (int ch = 0; ch < CHANNELS; ch++) {
    if (isOpen[ch]) clients[ch].stop();
    isOpen[ch] = false;
  }
}

static void sendFrame(uint8_t type, uint8_t channel, const uint8_t *payload, size_t length) {
  if (!hostActive) return;
  uint8_t head[7] = {MAGIC0, MAGIC1, type, channel, (uint8_t)length, (uint8_t)(length >> 8), 0};
  head[6] = head[2] ^ head[3] ^ head[4] ^ head[5] ^ 0xFF;
  if (!writeAll(head, sizeof head) || (length && !writeAll(payload, length))) {
    hostActive = false;               // nobody is reading the USB port: drop everything and wait for the host
    closeAll();
  }
}

static uint8_t wifiState() {
  if (!wifiStarted) return WIFI_IDLE;
  return WiFi.status() == WL_CONNECTED ? WIFI_JOINED : WIFI_JOINING;
}

static void sendWifi() {
  uint8_t p[11] = {0};
  p[0] = wifiState();
  p[1] = lastReason;
  if (p[0] == WIFI_JOINED) {
    IPAddress ip = WiFi.localIP(), gw = WiFi.gatewayIP();
    for (int i = 0; i < 4; i++) {
      p[2 + i] = ip[i];
      p[6 + i] = gw[i];
    }
    p[10] = (uint8_t)(int8_t)WiFi.RSSI();
  }
  reportedState = p[0];
  sendFrame(R_WIFI, 0, p, sizeof p);
}

static void sendHello() {
  uint8_t p[5] = {VERSION, (uint8_t)bootId, (uint8_t)(bootId >> 8), (uint8_t)(bootId >> 16), (uint8_t)(bootId >> 24)};
  sendFrame(R_HELLO, 0, p, sizeof p);
}

static void closeChannel(uint8_t ch) {
  if (isOpen[ch]) clients[ch].stop();
  isOpen[ch] = false;
  sendFrame(R_CLOSED, ch, nullptr, 0);
}

static void handleFrame(uint8_t type, uint8_t ch, const uint8_t *p, size_t length) {
  hostActive = true;
  switch (type) {
    case T_STATUS:
      sendHello();
      sendWifi();
      break;
    case T_ECHO:
      sendFrame(R_ECHO, ch, p, length);
      break;
    case T_WIFI: {
      size_t split = 0;
      while (split < length && p[split]) split++;
      String name = String((const char *)p, split);
      String password = split < length ? String((const char *)p + split + 1, length - split - 1) : String();
      if (!(wifiStarted && name == wifiName && WiFi.status() == WL_CONNECTED)) {
        closeAll();
        WiFi.disconnect();
        lastReason = 0;
        wifiName = name;
        WiFi.begin(name.c_str(), password.c_str());
        wifiStarted = true;
      }
      sendWifi();
      break;
    }
    case T_OPEN: {
      if (ch >= CHANNELS) break;
      if (isOpen[ch]) clients[ch].stop();
      isOpen[ch] = false;
      uint8_t ok = 0;
      if (length == 6 && WiFi.status() == WL_CONNECTED) {
        IPAddress ip(p[0], p[1], p[2], p[3]);
        uint16_t port = p[4] | (p[5] << 8);
        if (clients[ch].connect(ip, port, 5000)) {
          clients[ch].setNoDelay(true);
          isOpen[ch] = true;
          ok = 1;
        }
      }
      sendFrame(R_OPENED, ch, &ok, 1);
      break;
    }
    case T_DATA: {
      if (ch >= CHANNELS || !isOpen[ch]) break;
      uint32_t last = millis();
      size_t done = 0;
      while (done < length) {
        size_t sent = clients[ch].write(p + done, length - done);
        if (sent) {
          done += sent;
          last = millis();
        } else if (!clients[ch].connected() || millis() - last > CAMERA_WRITE_TIMEOUT_MS) {
          closeChannel(ch);
          break;
        } else {
          delay(1);
        }
      }
      break;
    }
    case T_CLOSE:
      if (ch < CHANNELS) closeChannel(ch);
      break;
    case T_FLOOD: {
      uint16_t count = length >= 2 ? (p[0] | (p[1] << 8)) : 0;
      for (size_t i = 0; i < MAX_PAYLOAD; i++) txPayload[i] = (uint8_t)(i * 31 + 7);
      for (uint16_t i = 0; i < count && hostActive; i++) sendFrame(R_FLOOD, 0, txPayload, MAX_PAYLOAD);
      break;
    }
    case T_SCAN: {
      if (wifiStarted && WiFi.status() != WL_CONNECTED) {
        WiFi.disconnect();            // a scan cannot run while the radio keeps trying to join
        wifiStarted = false;
        delay(100);
      }
      int found = WiFi.scanNetworks(false, true);
      size_t fill = 1;
      uint8_t count = 0;
      for (int i = 0; i < found && count < 250; i++) {
        String name = WiFi.SSID(i);
        size_t n = name.length() > 32 ? 32 : name.length();
        if (fill + 4 + n > MAX_PAYLOAD) break;
        txPayload[fill++] = (uint8_t)(int8_t)WiFi.RSSI(i);
        txPayload[fill++] = (uint8_t)WiFi.channel(i);
        txPayload[fill++] = (uint8_t)WiFi.encryptionType(i);
        txPayload[fill++] = (uint8_t)n;
        memcpy(txPayload + fill, name.c_str(), n);
        fill += n;
        count++;
      }
      txPayload[0] = found < 0 ? 0xFF : count;
      WiFi.scanDelete();
      sendFrame(R_SCAN, 0, txPayload, fill);
      break;
    }
  }
}

static bool pumpSerial() {
  bool worked = false;
  int budget = 8192;                  // then give the camera side a turn
  while (budget > 0 && Serial.available() > 0) {
    worked = true;
    if (!inPayload) {
      int b = Serial.read();
      if (b < 0) break;
      budget--;
      header[headerFill++] = (uint8_t)b;
      if (headerFill == 1 && header[0] != MAGIC0) {
        headerFill = 0;
      } else if (headerFill == 2 && header[1] != MAGIC1) {
        headerFill = header[1] == MAGIC0 ? 1 : 0;
        header[0] = MAGIC0;
      } else if (headerFill == 7) {
        headerFill = 0;
        if ((header[2] ^ header[3] ^ header[4] ^ header[5] ^ 0xFF) != header[6]) continue;
        payloadNeed = header[4] | (header[5] << 8);
        if (payloadNeed > MAX_PAYLOAD) continue;
        payloadGot = 0;
        if (payloadNeed == 0) handleFrame(header[2], header[3], rxPayload, 0);
        else inPayload = true;
      }
    } else {
      size_t n = Serial.read(rxPayload + payloadGot, payloadNeed - payloadGot);
      if (n == 0) break;
      payloadGot += n;
      budget -= (int)n;
      if (payloadGot == payloadNeed) {
        inPayload = false;
        handleFrame(header[2], header[3], rxPayload, payloadNeed);
      }
    }
  }
  return worked;
}

static bool pumpCamera() {
  bool worked = false;
  for (int ch = 0; ch < CHANNELS; ch++) {
    if (!isOpen[ch]) continue;
    int waiting = clients[ch].available();
    if (waiting > 0) {
      int n = clients[ch].read(txPayload, waiting > (int)MAX_PAYLOAD ? MAX_PAYLOAD : (size_t)waiting);
      if (n > 0) {
        sendFrame(R_DATA, ch, txPayload, (size_t)n);
        worked = true;
      }
    } else if (!clients[ch].connected()) {
      closeChannel(ch);               // the camera closed its end, and everything it sent has been passed on
      worked = true;
    }
  }
  return worked;
}

void setup() {
  Serial.setRxBufferSize(16384);
  Serial.setTxBufferSize(16384);
  Serial.begin(115200);
  Serial.setDebugOutput(false);
  bootId = esp_random();
  WiFi.persistent(false);             // never write the camera's Wi-Fi password to flash
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.onEvent([](WiFiEvent_t event, WiFiEventInfo_t info) {
    if (event == ARDUINO_EVENT_WIFI_STA_DISCONNECTED) lastReason = info.wifi_sta_disconnected.reason;
  });
}

void loop() {
  bool worked = pumpSerial();
  worked |= pumpCamera();
  bool anyOpen = false;
  for (int ch = 0; ch < CHANNELS; ch++) anyOpen |= isOpen[ch];
  if (anyOpen) acknowledgeNow();
  uint8_t state = wifiState();
  if (state != reportedState && hostActive) {
    if (state != WIFI_JOINED) closeAll();
    sendWifi();
  }
  if (!worked) delay(1);
}
