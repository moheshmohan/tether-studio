#ifndef GPHOTOC_H
#define GPHOTOC_H

#include <stddef.h>

/* Widget types (mirrors libgphoto2's CameraWidgetType values). */
enum {
    ZV_WTYPE_TEXT   = 2,
    ZV_WTYPE_RANGE  = 3,
    ZV_WTYPE_TOGGLE = 4,
    ZV_WTYPE_RADIO  = 5,
    ZV_WTYPE_MENU   = 6,
};

/* Sentinel result: the USB session died (unplug / mode flip) — caller should
 * drop the handle and reopen. */
#define ZV_SESSION_DEAD (-9000)

#ifdef __cplusplus
extern "C" {
#endif

/* Handle wraps { Camera*, GPContext* }. All functions return GP result codes
 * (>= 0 = OK) unless noted. */

void       *zv_open(void);
void        zv_close(void *h);          /* exit + free + NULL-safe */
int         zv_init(void *h);

int         zv_has_widget(void *h, const char *name);
int         zv_widget_info(void *h, const char *name, int *wtype, int *ro);

/* Current values. */
int         zv_current_string(void *h, const char *name, char *buf, size_t buflen);
int         zv_current_float(void *h, const char *name, float *out);
int         zv_current_toggle(void *h, const char *name, int *out);

/* RADIO/MENU choices as newline-joined text. */
int         zv_choices(void *h, const char *name, char *buf, size_t buflen);

int         zv_range(void *h, const char *name, float *mn, float *mx, float *step);

/* Writes. */
int         zv_set_choice(void *h, const char *name, int idx);
int         zv_set_float(void *h, const char *name, float v);
int         zv_set_toggle(void *h, const char *name, int v);
/* A text setting (the camera's date and time). */
int         zv_set_text(void *h, const char *name, const char *text);

/* Preview: malloc'd buffer + size; caller frees with zv_free. */
int         zv_preview(void *h, unsigned char **data, size_t *size);
void        zv_free(void *p);

/* File listing (MTP mode): "folder\tname\tsize\tmtime\n" lines. */
int         zv_list_files(void *h, char *buf, size_t buflen);

/* Streamed download to a filesystem path. */
int         zv_download(void *h, const char *folder, const char *name, const char *dest);

/* Takes one photo (libgphoto2's capture: half press, full press, let go) and saves it to dest_dir,
 * with any photo taken earlier that the camera still held for collection. `out` gets the saved paths,
 * one per line, the new photo last. Returns how many were saved, or an error below 0. Reads only:
 * nothing on the camera's card is changed or deleted, and no file on the Mac is replaced. */
int         zv_capture_photo(void *h, const char *dest_dir, char *out, size_t outlen);

const char *zv_err_string(int r);

/* ---------- Wi-Fi (camera in PC Remote, Cnct Method: Wi-Fi Access Point) ---------- */

/* Open a PTP/IP session to "a.b.c.d" (or "a.b.c.d:port") instead of USB.
 * The session runs through a relay on 127.0.0.1 inside this process that
 * removes the camera's empty data packets, which libgphoto2 cannot read. */
int         zv_init_wifi(void *h, const char *host);

/* The identity libgphoto2 presents to the camera: the 16-byte GUID kept in
 * its settings file (~/Library/Application Support/gphoto/settings on macOS,
 * created on first use) and this computer's host name,
 * which is what the camera shows on its pairing screen. */
int         zv_wifi_identity(unsigned char guid[16], char *name, size_t namelen);

/* The commands sent outside libgphoto2, over the open Wi-Fi session only (see
 * gphotoc.c for what exactly goes out). Call them only from the thread that
 * makes the other camera calls. 0 = OK, >0 = the camera's refusal code,
 * <0 = no session or no answer.
 *
 * Zoom: +1 in, -1 out, 0 stop; zooming continues until the stop is sent. */
int         zv_wifi_zoom(int direction);
/* Touch focus / touch tracking at a point of the picture: x 0..639, y 0..479. */
int         zv_wifi_touch(int x, int y);
/* Ends the touch focus or tracking started by zv_wifi_touch. */
int         zv_wifi_touch_cancel(void);

/* Results of zv_wifi_handshake. */
enum {
    ZV_PAIR_OK          = 0,   /* the camera knows this computer */
    ZV_PAIR_REFUSED     = 1,   /* unknown computer and the camera is not on its Pairing screen */
    ZV_PAIR_TIMEOUT     = 2,   /* on the Pairing screen, but nobody confirmed in time */
    ZV_PAIR_UNREACHABLE = 3,   /* no TCP connection; *sys_errno says why */
    ZV_PAIR_ERROR       = 4,   /* the camera answered something unexpected or hung up */
};

/* Runs the PTP/IP opening handshake with the given identity and closes again.
 * libgphoto2 gives the camera 2.5 s to answer, too short for a person to
 * confirm pairing on the camera, so pairing is done here with a long wait and
 * libgphoto2 connects afterwards as an already known computer. */
int         zv_wifi_handshake(const char *host, const unsigned char guid[16], const char *name,
                              int wait_seconds, int *sys_errno);

/* Sony camera search on every local network (SSDP). Writes the answering
 * cameras' description URLs, one per line. Returns how many, or -errno when
 * the search could not be sent at all. */
int         zv_ssdp_search(char *buf, size_t buflen, int wait_ms);

/* Fallback search that needs no incoming packets (the macOS firewall drops
 * SSDP answers for apps it has not been told to allow): tries a TCP
 * connection to `port` on every address of this computer's own /24 networks.
 * Writes the addresses that accepted, one per line; returns how many. */
int         zv_scan_subnets(int port, int timeout_ms, char *buf, size_t buflen);

/* 0 when something accepts TCP connections at host:port, else -errno. */
int         zv_tcp_reachable(const char *host, int port, int timeout_ms);

/* Plain HTTP GET of a small document (the camera's description files).
 * Returns the body length, or a negative number on failure. */
int         zv_http_get(const char *host, int port, const char *path,
                        char *buf, size_t buflen, int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* GPHOTOC_H */
