#include "include/gphotoc.h"

#include <gphoto2/gphoto2-camera.h>
#include <gphoto2/gphoto2-context.h>
#include <gphoto2/gphoto2-widget.h>
#include <gphoto2/gphoto2-file.h>
#include <gphoto2/gphoto2-list.h>
#include <gphoto2/gphoto2.h>
#include <gphoto2/gphoto2-abilities-list.h>
#include <gphoto2/gphoto2-port-info-list.h>
#include <gphoto2/gphoto2-setting.h>
#include <gphoto2/gphoto2-port-log.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <ifaddrs.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <strings.h>
#include <time.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/resource.h>
#include <sys/socket.h>

typedef struct {
    Camera   *cam;
    GPContext *ctx;
} zv_handle;

/* ---------- helpers ---------- */

static int zv_map(int r) {
    switch (r) {
    case GP_ERROR_IO: case GP_ERROR_IO_LOCK: case GP_ERROR_IO_READ:
    case GP_ERROR_IO_WRITE: case GP_ERROR_IO_USB_CLAIM: case GP_ERROR_IO_USB_FIND:
    case GP_ERROR_IO_USB_CLEAR_HALT: case GP_ERROR_TIMEOUT:
        return ZV_SESSION_DEAD;
    default:
        return r;
    }
}

static int widget_for(zv_handle *h, const char *name, CameraWidget **out) {
    *out = NULL;
    if (!h || !h->cam || !h->ctx) return GP_ERROR_NOT_SUPPORTED;
    return zv_map(gp_camera_get_single_config(h->cam, name, out, h->ctx));
}

const char *zv_err_string(int r) {
    return gp_result_as_string(r);
}

/* ---------- lifecycle ---------- */

/* Set ZVE10_GPHOTO_LOG=/some/file to get libgphoto2's own debug log there. */
static void log_line(GPLogLevel level, const char *domain, const char *str, void *data) {
    (void)level;
    fprintf((FILE *)data, "%s: %s\n", domain, str);
    fflush((FILE *)data);
}

static void enable_log_once(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    const char *path = getenv("ZVE10_GPHOTO_LOG");
    FILE *f = (path && *path) ? fopen(path, "a") : NULL;
    if (f) gp_log_add_func(GP_LOG_DEBUG, log_line, f);
}

void *zv_open(void) {
    enable_log_once();
    zv_handle *h = calloc(1, sizeof(zv_handle));
    if (!h) return NULL;
    if (gp_camera_new(&h->cam) < 0) { free(h); return NULL; }
    h->ctx = gp_context_new();
    return h;
}

void zv_close(void *vh) {
    zv_handle *h = vh;
    if (!h) return;
    if (h->cam) {
        if (h->ctx) gp_camera_exit(h->cam, h->ctx);
        gp_camera_free(h->cam);
    }
    if (h->ctx) gp_context_unref(h->ctx);
    free(h);
}

int zv_init(void *vh) {
    zv_handle *h = vh;
    if (!h || !h->cam || !h->ctx) return GP_ERROR_NOT_SUPPORTED;
    return zv_map(gp_camera_init(h->cam, h->ctx));
}

/* ---------- reads ---------- */

int zv_has_widget(void *h, const char *name) {
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0) return 0;
    if (w) gp_widget_free(w);
    return 1;
}

int zv_widget_info(void *vh, const char *name, int *wtype, int *ro) {
    zv_handle *h = vh;
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;
    CameraWidgetType t = GP_WIDGET_WINDOW;
    gp_widget_get_type(w, &t);
    int ronly = 0;
    gp_widget_get_readonly(w, &ronly);
    if (wtype) *wtype = (int)t;
    if (ro) *ro = ronly;
    gp_widget_free(w);
    return GP_OK;
}

int zv_current_string(void *vh, const char *name, char *buf, size_t buflen) {
    zv_handle *h = vh;
    if (!buf || buflen == 0) return GP_ERROR_BAD_PARAMETERS;
    buf[0] = '\0';
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;
    const char *s = NULL;
    r = gp_widget_get_value(w, &s);
    if (r >= 0 && s) snprintf(buf, buflen, "%s", s);
    gp_widget_free(w);
    return zv_map(r);
}

int zv_current_float(void *vh, const char *name, float *out) {
    zv_handle *h = vh;
    if (!out) return GP_ERROR_BAD_PARAMETERS;
    *out = 0;
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;
    float v = 0;
    r = gp_widget_get_value(w, &v);
    if (r >= 0) *out = v;
    gp_widget_free(w);
    return zv_map(r);
}

int zv_current_toggle(void *vh, const char *name, int *out) {
    zv_handle *h = vh;
    if (!out) return GP_ERROR_BAD_PARAMETERS;
    *out = 0;
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;
    int v = 0;
    r = gp_widget_get_value(w, &v);
    if (r >= 0) *out = v;
    gp_widget_free(w);
    return zv_map(r);
}

int zv_choices(void *vh, const char *name, char *buf, size_t buflen) {
    zv_handle *h = vh;
    if (!buf || buflen == 0) return GP_ERROR_BAD_PARAMETERS;
    buf[0] = '\0';
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;

    size_t used = 0;
    int n = gp_widget_count_choices(w);
    for (int i = 0; i < n; i++) {
        const char *c = NULL;
        if (gp_widget_get_choice(w, i, &c) >= 0 && c) {
            size_t len = strlen(c);
            if (used + len + 2 >= buflen) break;
            if (used > 0) buf[used++] = '\n';
            memcpy(buf + used, c, len);
            used += len;
            buf[used] = '\0';
        }
    }
    gp_widget_free(w);
    return GP_OK;
}

int zv_range(void *vh, const char *name, float *mn, float *mx, float *step) {
    zv_handle *h = vh;
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;
    float a = 0, b = 0, c = 1;
    r = gp_widget_get_range(w, &a, &b, &c);
    if (r >= 0) {
        if (mn) *mn = a;
        if (mx) *mx = b;
        if (step) *step = c;
    }
    gp_widget_free(w);
    return zv_map(r);
}

/* ---------- writes ---------- */

int zv_set_choice(void *vh, const char *name, int idx) {
    zv_handle *h = vh;
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;

    const char *choice = NULL;
    if (gp_widget_get_choice(w, idx, &choice) < 0 || !choice) {
        gp_widget_free(w);
        return GP_ERROR_BAD_PARAMETERS;
    }
    char *dup = strdup(choice);
    r = gp_widget_set_value(w, dup);
    if (r >= 0) r = gp_camera_set_single_config(h->cam, name, w, h->ctx);
    free(dup);
    gp_widget_free(w);
    return zv_map(r);
}

int zv_set_float(void *vh, const char *name, float v) {
    zv_handle *h = vh;
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;
    r = gp_widget_set_value(w, &v);
    if (r >= 0) r = gp_camera_set_single_config(h->cam, name, w, h->ctx);
    gp_widget_free(w);
    return zv_map(r);
}

int zv_set_toggle(void *vh, const char *name, int v) {
    zv_handle *h = vh;
    CameraWidget *w = NULL;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;
    int val = v ? 1 : 0;
    r = gp_widget_set_value(w, &val);
    if (r >= 0) r = gp_camera_set_single_config(h->cam, name, w, h->ctx);
    gp_widget_free(w);
    return zv_map(r);
}

int zv_set_text(void *vh, const char *name, const char *text) {
    zv_handle *h = vh;
    CameraWidget *w = NULL;
    if (!text) return GP_ERROR_BAD_PARAMETERS;
    int r = widget_for(h, name, &w);
    if (r < 0 || !w) return (r < 0) ? r : GP_ERROR_NOT_SUPPORTED;
    CameraWidgetType t = GP_WIDGET_WINDOW;
    gp_widget_get_type(w, &t);
    if (t != GP_WIDGET_TEXT) {
        gp_widget_free(w);
        return GP_ERROR_BAD_PARAMETERS;
    }
    r = gp_widget_set_value(w, text);
    if (r >= 0) r = gp_camera_set_single_config(h->cam, name, w, h->ctx);
    gp_widget_free(w);
    return zv_map(r);
}

/* ---------- preview ---------- */

int zv_preview(void *vh, unsigned char **data, size_t *size) {
    zv_handle *h = vh;
    if (!data || !size) return GP_ERROR_BAD_PARAMETERS;
    *data = NULL; *size = 0;
    if (!h || !h->cam || !h->ctx) return GP_ERROR_NOT_SUPPORTED;

    CameraFile *f = NULL;
    int r = gp_file_new(&f);
    if (r < 0 || !f) return r;
    r = gp_camera_capture_preview(h->cam, f, h->ctx);   // NOTE: single pointer — passing &f corrupts the stack (crashed on-device once; never again)
    if (r < 0) { gp_file_free(f); return zv_map(r); }

    const char *ptr = NULL;
    unsigned long sz = 0;
    r = gp_file_get_data_and_size(f, &ptr, &sz);
    if (r >= 0 && ptr && sz > 0) {
        unsigned char *out = malloc(sz);
        if (!out) { gp_file_free(f); return GP_ERROR_NO_MEMORY; }
        memcpy(out, ptr, sz);
        *data = out; *size = sz;
    } else if (r >= 0) {
        r = GP_ERROR_CORRUPTED_DATA;
    }
    gp_file_free(f);
    return zv_map(r);
}

void zv_free(void *p) { free(p); }

/* ---------- files ---------- */

static int append_line(char *buf, size_t buflen, size_t *used,
                       const char *folder, const char *name,
                       unsigned long size, long mtime) {
    char line[1024];
    int n = snprintf(line, sizeof(line), "%s\t%s\t%lu\t%ld\n", folder, name, size, mtime);
    if (n < 0 || *used + (size_t)n >= buflen) return -1;
    memcpy(buf + *used, line, (size_t)n);
    *used += (size_t)n;
    buf[*used] = '\0';
    return 0;
}

int zv_list_files(void *vh, char *buf, size_t buflen) {
    zv_handle *h = vh;
    if (!buf || buflen == 0) return GP_ERROR_BAD_PARAMETERS;
    buf[0] = '\0';
    if (!h || !h->cam || !h->ctx) return GP_ERROR_NOT_SUPPORTED;

    size_t used = 0;
    int r;

    CameraList *stores = NULL;
    gp_list_new(&stores);
    r = gp_camera_folder_list_folders(h->cam, "/", stores, h->ctx);
    if (r < 0) { gp_list_free(stores); return zv_map(r); }

    int storeCount = gp_list_count(stores);
    for (int si = 0; si < storeCount; si++) {
        const char *sn = NULL;
        if (gp_list_get_name(stores, si, &sn) < 0 || !sn) continue;
        if (strncmp(sn, "store_", 6) != 0) continue;

        char dayPath[256];
        snprintf(dayPath, sizeof(dayPath), "/%s", sn);

        CameraList *days = NULL;
        gp_list_new(&days);
        r = gp_camera_folder_list_folders(h->cam, dayPath, days, h->ctx);
        if (r < 0) { gp_list_free(days); continue; }

        int dayCount = gp_list_count(days);
        for (int di = 0; di < dayCount; di++) {
            const char *dn = NULL;
            if (gp_list_get_name(days, di, &dn) < 0 || !dn) continue;
            char folder[512];
            snprintf(folder, sizeof(folder), "%s/%s", dayPath, dn);

            CameraList *files = NULL;
            gp_list_new(&files);
            r = gp_camera_folder_list_files(h->cam, folder, files, h->ctx);
            if (r < 0) { gp_list_free(files); continue; }

            int fileCount = gp_list_count(files);
            for (int fi = 0; fi < fileCount; fi++) {
                const char *fn = NULL;
                if (gp_list_get_name(files, fi, &fn) < 0 || !fn) continue;

                unsigned long size = 0;
                long mtime = 0;
                CameraFileInfo info;
                memset(&info, 0, sizeof(info));
                if (gp_camera_file_get_info(h->cam, folder, fn, &info, h->ctx) >= 0) {
                    size = info.file.size;
                    mtime = (long)info.file.mtime;
                }
                if (append_line(buf, buflen, &used, folder, fn, size, mtime) != 0) {
                    gp_list_free(files); gp_list_free(days); gp_list_free(stores);
                    return GP_OK; /* buffer full: return what we have */
                }
            }
            gp_list_free(files);
        }
        gp_list_free(days);
    }
    gp_list_free(stores);
    return GP_OK;
}

int zv_download(void *vh, const char *folder, const char *name, const char *dest) {
    zv_handle *h = vh;
    if (!h || !h->cam || !h->ctx) return GP_ERROR_NOT_SUPPORTED;

    int fd = open(dest, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return GP_ERROR_OS_FAILURE;

    CameraFile *f = NULL;
    int r = gp_file_new_from_fd(&f, fd);
    if (r < 0 || !f) { close(fd); return r; }

    r = gp_camera_file_get(h->cam, folder, name, GP_FILE_TYPE_NORMAL, f, h->ctx);
    gp_file_free(f);
    close(fd); /* fd ownership stays with us; libgphoto2 flushes on free */
    return zv_map(r);
}

/* ====================================================================== */
/* Photos                                                                 */
/* ====================================================================== */

/* Writes a photo libgphoto2 has just fetched (it holds the data in its own cache) into dest_dir
 * under the camera's own file name, without the "capt_" libgphoto2 puts in front. Never replaces a
 * file: a name in use gets "-2", "-3"... Then drops the photo from libgphoto2's cache (only the
 * cache: nothing is sent to the camera), so a long series does not pile up in memory. */
static int save_fetched(zv_handle *h, const char *folder, const char *name, const char *dest_dir,
                        char *out, size_t outlen, size_t *used) {
    const char *base = strncmp(name, "capt_", 5) == 0 ? name + 5 : name;
    const char *dot = strrchr(base, '.');
    size_t stem = dot ? (size_t)(dot - base) : strlen(base);
    char dest[4096];
    int fd = -1;
    for (int n = 1; n < 1000 && fd < 0; n++) {
        if (n == 1) snprintf(dest, sizeof dest, "%s/%s", dest_dir, base);
        else snprintf(dest, sizeof dest, "%s/%.*s-%d%s", dest_dir, (int)stem, base, n, dot ? dot : "");
        fd = open(dest, O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd < 0 && errno != EEXIST) return GP_ERROR_OS_FAILURE;
    }
    if (fd < 0) return GP_ERROR_OS_FAILURE;

    CameraFile *f = NULL;
    int r = gp_file_new_from_fd(&f, fd);
    if (r < 0 || !f) { close(fd); unlink(dest); return r < 0 ? r : GP_ERROR; }
    r = gp_camera_file_get(h->cam, folder, name, GP_FILE_TYPE_NORMAL, f, h->ctx);
    gp_file_free(f);
    close(fd);
    gp_filesystem_delete_file_noop(h->cam->fs, folder, name, h->ctx);
    if (r < 0) { unlink(dest); return zv_map(r); }   /* only the empty file this call just made */
    size_t n = strlen(dest);
    if (*used + n + 1 < outlen) {
        memcpy(out + *used, dest, n);
        *used += n;
        out[(*used)++] = '\n';
        out[*used] = '\0';
    }
    return GP_OK;
}

int zv_capture_photo(void *vh, const char *dest_dir, char *out, size_t outlen) {
    zv_handle *h = vh;
    if (!h || !h->cam || !h->ctx || !dest_dir || !out || outlen == 0) return GP_ERROR_BAD_PARAMETERS;
    out[0] = 0;
    size_t used = 0;
    int saved = 0;

    /* Photos taken earlier that the camera still holds for collection: fetched first, so that the
     * one taken below is not mistaken for one of them (libgphoto2 clears only a single one). */
    for (int i = 0; i < 40; i++) {
        CameraEventType type = GP_EVENT_UNKNOWN;
        void *data = NULL;
        int r = gp_camera_wait_for_event(h->cam, 30, &type, &data, h->ctx);
        if (r < 0) { free(data); return zv_map(r); }
        if (type == GP_EVENT_FILE_ADDED && data) {
            CameraFilePath *p = data;
            if (save_fetched(h, p->folder, p->name, dest_dir, out, outlen, &used) == GP_OK) saved++;
        }
        free(data);
        if (type == GP_EVENT_TIMEOUT) break;
    }

    CameraFilePath path;
    memset(&path, 0, sizeof path);
    int r = gp_camera_capture(h->cam, GP_CAPTURE_IMAGE, &path, h->ctx);
    if (r < 0) return zv_map(r);
    r = save_fetched(h, path.folder, path.name, dest_dir, out, outlen, &used);
    if (r < 0) return r;
    return saved + 1;
}

/* ====================================================================== */
/* Wi-Fi                                                                  */
/* ====================================================================== */

#define PTPIP_PORT 15740

static int relay_port_for(const char *host);

int zv_init_wifi(void *vh, const char *host) {
    zv_handle *h = vh;
    if (!h || !h->cam || !h->ctx || !host || !*host) return GP_ERROR_BAD_PARAMETERS;

    /* libgphoto2 does not talk to the camera directly but through the relay
     * below, which repairs one thing in the camera's answers (see there). */
    int relay = relay_port_for(host);
    if (relay <= 0) return GP_ERROR_IO;
    char path[160];
    snprintf(path, sizeof(path), "ptpip:127.0.0.1:%d:%d", relay, relay);    /* command port : event port */

    CameraAbilitiesList *models = NULL;
    GPPortInfoList *ports = NULL;
    CameraAbilities abilities;
    GPPortInfo port;
    int r, i;

    if ((r = gp_abilities_list_new(&models)) < 0) goto done;
    if ((r = gp_abilities_list_load(models, h->ctx)) < 0) goto done;
    if ((r = i = gp_abilities_list_lookup_model(models, "PTP/IP Camera")) < 0) goto done;
    if ((r = gp_abilities_list_get_abilities(models, i, &abilities)) < 0) goto done;
    if ((r = gp_camera_set_abilities(h->cam, abilities)) < 0) goto done;

    if ((r = gp_port_info_list_new(&ports)) < 0) goto done;
    if ((r = gp_port_info_list_load(ports)) < 0) goto done;
    if ((r = i = gp_port_info_list_lookup_path(ports, path)) < 0) goto done;
    if ((r = gp_port_info_list_get_info(ports, i, &port)) < 0) goto done;
    if ((r = gp_camera_set_port_info(h->cam, port)) < 0) goto done;

    r = gp_camera_init(h->cam, h->ctx);
done:
    if (models) gp_abilities_list_free(models);
    if (ports) gp_port_info_list_free(ports);
    return zv_map(r);
}

/* Same text form libgphoto2 uses for its PTP/IP GUID: 16 hex bytes joined by
 * colons, 47 characters. */
static int parse_guid(const char *text, unsigned char guid[16]) {
    if (strlen(text) != 47) return 0;
    for (int i = 0; i < 16; i++) {
        char *end = NULL;
        long v = strtol(text + i * 3, &end, 16);
        if (end != text + i * 3 + 2 || (*end != ':' && *end != '\0')) return 0;
        guid[i] = (unsigned char)v;
    }
    return 1;
}

int zv_wifi_identity(unsigned char guid[16], char *name, size_t namelen) {
    if (!guid || !name || namelen == 0) return GP_ERROR_BAD_PARAMETERS;

    char text[1024] = "";
    gp_setting_get("ptp2_ip", "guid", text);
    if (!parse_guid(text, guid)) {
        arc4random_buf(guid, 16);
        char *pos = text;
        for (int i = 0; i < 16; i++)
            pos += sprintf(pos, i ? ":%02x" : "%02x", guid[i]);
        gp_setting_set("ptp2_ip", "guid", text);   /* saved to libgphoto2's settings file */
    }
    if (gethostname(name, namelen) != 0) return GP_ERROR_OS_FAILURE;
    name[namelen - 1] = '\0';
    return GP_OK;
}

/* ---------- small socket helpers ---------- */

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void put32(unsigned char *p, unsigned int v) {
    p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; p[2] = (v >> 16) & 0xff; p[3] = (v >> 24) & 0xff;
}

static unsigned int get32(const unsigned char *p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | ((unsigned int)p[3] << 24);
}

/* "a.b.c.d" or "a.b.c.d:port" */
static int parse_host(const char *host, int default_port, struct sockaddr_in *out) {
    char ip[64];
    snprintf(ip, sizeof(ip), "%s", host ? host : "");
    int port = default_port;
    char *colon = strchr(ip, ':');
    if (colon) { *colon = '\0'; port = atoi(colon + 1); }
    memset(out, 0, sizeof(*out));
    out->sin_family = AF_INET;
    out->sin_port = htons((unsigned short)port);
    return inet_pton(AF_INET, ip, &out->sin_addr) == 1 && port > 0 && port < 65536;
}

/* Connected TCP socket, or -1 with errno set. */
static int tcp_connect(const struct sockaddr_in *addr, int timeout_ms) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int err = 0;
    if (connect(fd, (const struct sockaddr *)addr, sizeof(*addr)) != 0) {
        if (errno != EINPROGRESS) { err = errno; goto fail; }
        struct pollfd p = { .fd = fd, .events = POLLOUT };
        int n = poll(&p, 1, timeout_ms);
        if (n == 0) { err = ETIMEDOUT; goto fail; }
        if (n < 0) { err = errno; goto fail; }
        socklen_t len = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
        if (err) goto fail;
    }
    fcntl(fd, F_SETFL, flags);
    return fd;
fail:
    close(fd);
    errno = err;
    return -1;
}

static int send_all(int fd, const void *data, size_t len) {
    const unsigned char *p = data;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; }
        p += n; len -= (size_t)n;
    }
    return 0;
}

/* 0 = got all of it, 1 = deadline passed, -1 = closed or failed. */
static int recv_all(int fd, void *data, size_t len, long long deadline) {
    unsigned char *p = data;
    while (len > 0) {
        long long left = deadline - now_ms();
        if (left <= 0) return 1;
        struct pollfd pf = { .fd = fd, .events = POLLIN };
        int n = poll(&pf, 1, (int)(left > 1000 ? 1000 : left));
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) continue;
        ssize_t got = recv(fd, p, len, 0);
        if (got == 0) return -1;
        if (got < 0) { if (errno == EINTR || errno == EAGAIN) continue; return -1; }
        p += got; len -= (size_t)got;
    }
    return 0;
}

/* One PTP/IP packet: type via *type, payload (up to cap bytes kept) in body. */
static int recv_packet(int fd, unsigned int *type, unsigned char *body, size_t cap, size_t *got,
                       long long deadline) {
    unsigned char hdr[8];
    int r = recv_all(fd, hdr, sizeof(hdr), deadline);
    if (r != 0) return r;
    unsigned int len = get32(hdr);
    *type = get32(hdr + 4);
    if (len < 8 || len > 65536) return -1;
    size_t payload = len - 8, keep = payload < cap ? payload : cap;
    if ((r = recv_all(fd, body, keep, deadline)) != 0) return r;
    for (size_t rest = payload - keep; rest > 0; ) {            /* drop what does not fit */
        unsigned char skip[256];
        size_t n = rest < sizeof(skip) ? rest : sizeof(skip);
        if ((r = recv_all(fd, skip, n, deadline)) != 0) return r;
        rest -= n;
    }
    if (got) *got = keep;
    return 0;
}

/* ---------- pairing handshake ---------- */

enum { PKT_INIT_CMD_REQ = 1, PKT_INIT_CMD_ACK = 2, PKT_INIT_EVT_REQ = 3, PKT_INIT_EVT_ACK = 4, PKT_INIT_FAIL = 5 };

int zv_wifi_handshake(const char *host, const unsigned char guid[16], const char *name,
                      int wait_seconds, int *sys_errno) {
    if (sys_errno) *sys_errno = 0;
    struct sockaddr_in addr;
    if (!guid || !name || !parse_host(host, PTPIP_PORT, &addr)) return ZV_PAIR_ERROR;

    int cmd = tcp_connect(&addr, 3000);
    if (cmd < 0) {
        if (sys_errno) *sys_errno = errno;
        return ZV_PAIR_UNREACHABLE;
    }

    /* Init Command Request, byte for byte what libgphoto2 sends:
     * GUID, name as UTF-16LE with terminator, protocol version 1.0. */
    unsigned char req[8 + 16 + 2 * 128 + 4];
    size_t n = strlen(name);
    if (n > 126) n = 126;
    size_t len = 8 + 16 + (n + 1) * 2 + 4;
    memset(req, 0, sizeof(req));
    put32(req, (unsigned int)len);
    put32(req + 4, PKT_INIT_CMD_REQ);
    memcpy(req + 8, guid, 16);
    for (size_t i = 0; i < n; i++) req[24 + i * 2] = (unsigned char)name[i];
    put32(req + len - 4, 0x00010000);

    int result = ZV_PAIR_ERROR;
    int evt = -1;
    unsigned char body[512];
    unsigned int type = 0;
    size_t got = 0;

    if (send_all(cmd, req, len) != 0) goto out;

    /* The camera holds this answer while its screen asks to confirm pairing. */
    int r = recv_packet(cmd, &type, body, sizeof(body), &got, now_ms() + (long long)wait_seconds * 1000);
    if (r == 1) { result = ZV_PAIR_TIMEOUT; goto out; }
    if (r != 0) goto out;
    if (type == PKT_INIT_FAIL) { result = ZV_PAIR_REFUSED; goto out; }
    if (type != PKT_INIT_CMD_ACK || got < 4) goto out;

    /* Finish the handshake properly (event channel) before hanging up. */
    evt = tcp_connect(&addr, 3000);
    if (evt >= 0) {
        unsigned char ereq[12];
        put32(ereq, 12);
        put32(ereq + 4, PKT_INIT_EVT_REQ);
        memcpy(ereq + 8, body, 4);                          /* connection number from the ack */
        if (send_all(evt, ereq, sizeof(ereq)) == 0)
            recv_packet(evt, &type, body, sizeof(body), &got, now_ms() + 3000);
    }
    result = ZV_PAIR_OK;
out:
    if (evt >= 0) close(evt);
    close(cmd);
    return result;
}

/* ---------- discovery ---------- */

#define SSDP_TARGET "urn:schemas-sony-com:service:DigitalImaging:1"

static void add_location(char *buf, size_t buflen, size_t *used, int *count, const char *packet) {
    for (const char *line = packet; line && *line; ) {
        if (strncasecmp(line, "LOCATION:", 9) == 0) {
            const char *v = line + 9;
            while (*v == ' ' || *v == '\t') v++;
            size_t n = strcspn(v, "\r\n \t");
            if (n == 0 || n > 300) return;
            char url[304];
            memcpy(url, v, n);
            url[n] = '\n'; url[n + 1] = '\0';
            if (strstr(buf, url) || *used + n + 2 >= buflen) return;    /* seen already, or no room */
            memcpy(buf + *used, url, n + 2);
            *used += n + 1;
            (*count)++;
            return;
        }
        line = strchr(line, '\n');
        if (line) line++;
    }
}

int zv_ssdp_search(char *buf, size_t buflen, int wait_ms) {
    if (!buf || buflen == 0) return -EINVAL;
    buf[0] = '\0';

    static const char search[] =
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"
        "ST: " SSDP_TARGET "\r\n\r\n";
    struct sockaddr_in group;
    memset(&group, 0, sizeof(group));
    group.sin_family = AF_INET;
    group.sin_port = htons(1900);
    inet_pton(AF_INET, "239.255.255.250", &group.sin_addr);

    /* One socket per IPv4 interface, so the search goes out on Wi-Fi even when
     * another interface is the default route. */
    enum { MAX_SOCKS = 8 };
    struct pollfd socks[MAX_SOCKS];
    int nsocks = 0, send_error = 0;

    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *i = ifs; i && nsocks < MAX_SOCKS; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
            if (!(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK)) continue;
            struct sockaddr_in local = *(struct sockaddr_in *)i->ifa_addr;
            local.sin_port = 0;
            int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
            if (fd < 0) continue;
            unsigned char ttl = 2;
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &local.sin_addr, sizeof(local.sin_addr));
            if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0 ||
                sendto(fd, search, sizeof(search) - 1, 0, (struct sockaddr *)&group, sizeof(group)) < 0) {
                send_error = errno;
                close(fd);
                continue;
            }
            socks[nsocks].fd = fd;
            socks[nsocks].events = POLLIN;
            nsocks++;
        }
        freeifaddrs(ifs);
    }
    if (nsocks == 0) return send_error ? -send_error : -ENETDOWN;

    size_t used = 0;
    int count = 0, resent = 0;
    long long start = now_ms(), deadline = start + wait_ms;
    while (now_ms() < deadline) {
        if (poll(socks, (nfds_t)nsocks, 100) > 0) {
            for (int s = 0; s < nsocks; s++) {
                if (!(socks[s].revents & POLLIN)) continue;
                char packet[2048];
                ssize_t n = recv(socks[s].fd, packet, sizeof(packet) - 1, 0);
                if (n <= 0) continue;
                packet[n] = '\0';
                int before = count;
                add_location(buf, buflen, &used, &count, packet);
                if (count > before && before == 0) {            /* first camera: allow others 400 ms more */
                    long long soon = now_ms() + 400;
                    if (soon < deadline) deadline = soon;
                }
            }
        }
        if (!resent && count == 0 && now_ms() - start > 800) {  /* UDP may be lost: ask once more */
            resent = 1;
            for (int s = 0; s < nsocks; s++)
                sendto(socks[s].fd, search, sizeof(search) - 1, 0, (struct sockaddr *)&group, sizeof(group));
        }
    }
    for (int s = 0; s < nsocks; s++) close(socks[s].fd);
    return count;
}

/* Connects to hosts first..last (host byte order) at once; appends those that accept. */
static void scan_range(unsigned int first, unsigned int last, unsigned int self, int port, int timeout_ms,
                       char *buf, size_t buflen, size_t *used, int *count) {
    enum { BATCH = 254 };
    struct pollfd fds[BATCH];
    unsigned int addrs[BATCH];
    int n = 0;

    for (unsigned int a = first; a <= last && n < BATCH; a++) {
        if (a == self) continue;
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) break;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        struct sockaddr_in to;
        memset(&to, 0, sizeof(to));
        to.sin_family = AF_INET;
        to.sin_port = htons((unsigned short)port);
        to.sin_addr.s_addr = htonl(a);
        if (connect(fd, (struct sockaddr *)&to, sizeof(to)) != 0 && errno != EINPROGRESS) {
            close(fd);
            continue;
        }
        fds[n].fd = fd; fds[n].events = POLLOUT; fds[n].revents = 0;
        addrs[n] = a;
        n++;
    }

    long long deadline = now_ms() + timeout_ms;
    int open_left = n;
    while (open_left > 0) {
        long long left = deadline - now_ms();
        if (left <= 0 || poll(fds, (nfds_t)n, (int)left) <= 0) break;
        for (int i = 0; i < n; i++) {
            if (fds[i].fd < 0 || fds[i].revents == 0) continue;
            int err = 0;
            socklen_t len = sizeof(err);
            getsockopt(fds[i].fd, SOL_SOCKET, SO_ERROR, &err, &len);
            if (err == 0 && (fds[i].revents & POLLOUT)) {
                struct in_addr ia = { .s_addr = htonl(addrs[i]) };
                char line[32];
                int l = snprintf(line, sizeof(line), "%s\n", inet_ntoa(ia));
                if (*used + (size_t)l < buflen) {
                    memcpy(buf + *used, line, (size_t)l + 1);
                    *used += (size_t)l;
                    (*count)++;
                }
            }
            close(fds[i].fd);
            fds[i].fd = -1;                 /* poll ignores negative descriptors */
            open_left--;
        }
    }
    for (int i = 0; i < n; i++)
        if (fds[i].fd >= 0) close(fds[i].fd);
}

int zv_scan_subnets(int port, int timeout_ms, char *buf, size_t buflen) {
    if (!buf || buflen == 0) return -EINVAL;
    buf[0] = '\0';
    size_t used = 0;
    int count = 0;

    /* A whole /24 is tried at once (a camera on Wi-Fi can take over a second
     * to accept, so going in small rounds would be slow); apps start with room
     * for only 256 open files. */
    struct rlimit lim;
    if (getrlimit(RLIMIT_NOFILE, &lim) == 0 && lim.rlim_cur < 1024) {
        lim.rlim_cur = lim.rlim_max < 1024 ? lim.rlim_max : 1024;
        setrlimit(RLIMIT_NOFILE, &lim);
    }

    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) != 0) return -errno;
    unsigned int done[8];
    int ndone = 0;
    for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || !i->ifa_netmask) continue;
        if (!(i->ifa_flags & IFF_UP) || (i->ifa_flags & (IFF_LOOPBACK | IFF_POINTOPOINT))) continue;
        unsigned int self = ntohl(((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr);
        unsigned int mask = ntohl(((struct sockaddr_in *)i->ifa_netmask)->sin_addr.s_addr);
        if ((self >> 24) == 169) continue;                      /* link-local: no router, no camera */
        if ((mask & 0xffffff00u) != 0xffffff00u) mask = 0xffffff00u;    /* never more than a /24 */
        unsigned int net = self & mask, first = net + 1, last = (net | ~mask) - 1;
        int seen = 0;
        for (int d = 0; d < ndone; d++) seen |= (done[d] == net);
        if (seen || ndone == 8 || first > last) continue;
        done[ndone++] = net;
        scan_range(first, last, self, port, timeout_ms, buf, buflen, &used, &count);
    }
    freeifaddrs(ifs);
    return count;
}

int zv_tcp_reachable(const char *host, int port, int timeout_ms) {
    struct sockaddr_in addr;
    if (!parse_host(host, port, &addr)) return -EINVAL;
    int fd = tcp_connect(&addr, timeout_ms);
    if (fd < 0) return -(errno ? errno : EIO);
    close(fd);
    return 0;
}

int zv_http_get(const char *host, int port, const char *path, char *buf, size_t buflen, int timeout_ms) {
    if (!buf || buflen < 2 || !path) return -EINVAL;
    buf[0] = '\0';
    struct sockaddr_in addr;
    if (!parse_host(host, port, &addr)) return -EINVAL;
    addr.sin_port = htons((unsigned short)port);

    int fd = tcp_connect(&addr, timeout_ms);
    if (fd < 0) return -(errno ? errno : EIO);

    char req[512];
    int rl = snprintf(req, sizeof(req), "GET %s HTTP/1.0\r\nHost: %s:%d\r\nConnection: close\r\n\r\n",
                      path, host, port);
    int result = -EIO;
    if (rl <= 0 || rl >= (int)sizeof(req) || send_all(fd, req, (size_t)rl) != 0) goto out;

    size_t used = 0;
    long long deadline = now_ms() + timeout_ms;
    while (used < buflen - 1) {
        long long left = deadline - now_ms();
        if (left <= 0) break;
        struct pollfd pf = { .fd = fd, .events = POLLIN };
        int n = poll(&pf, 1, (int)left);
        if (n <= 0) break;
        ssize_t got = recv(fd, buf + used, buflen - 1 - used, 0);
        if (got <= 0) break;                                    /* server closed: complete */
        used += (size_t)got;
    }
    buf[used] = '\0';

    char *body = strstr(buf, "\r\n\r\n");
    int status = 0;
    if (!body || sscanf(buf, "HTTP/%*s %d", &status) != 1 || status != 200) goto out;
    body += 4;
    size_t blen = used - (size_t)(body - buf);
    memmove(buf, body, blen + 1);
    result = (int)blen;
out:
    close(fd);
    return result;
}

/* ---------- relay between libgphoto2 and the camera ---------- */

/* Why this exists (seen on a ZV-E10, firmware 2.03, libgphoto2 2.5.32): in
 * Wi-Fi PC Remote the camera has no card to offer, and it answers
 * GetStorageIDs with an announced data length of 0, then an EMPTY data packet,
 * an end-of-data packet and the response "StoreNotAvailable". libgphoto2's
 * PTP/IP reader does not expect the empty data packet: it takes it for the
 * response, and from then on every answer is read one transaction late, so
 * the session opens but no setting can be read. Dropping the empty data
 * packets (they carry nothing) keeps libgphoto2 in step. Everything else is
 * passed through untouched, in both directions. */

#define PKT_DATA 10

#define PKT_CMD_REQUEST 6
#define PKT_CMD_RESPONSE 7
#define PKT_START_DATA 9
#define PKT_END_DATA 12

typedef struct {
    int client, camera;
    int users;                  /* pump threads still running */
    pthread_mutex_t lock;
    pthread_mutex_t to_camera;  /* one writer at a time towards the camera */
} relay_pair;

static pthread_mutex_t relay_lock = PTHREAD_MUTEX_INITIALIZER;
static int relay_listener = -1;
static int relay_port = 0;
static struct sockaddr_in relay_camera;

/* The connection carrying commands (the other one carries events), and the
 * one command this relay sends itself: see zv_wifi_zoom. Its transaction IDs
 * are taken from a range libgphoto2 never reaches, and its response is kept
 * here instead of being passed on. */
#define OWN_TID_BASE 0x7A000000u
static relay_pair *relay_command = NULL;
static pthread_cond_t relay_answer = PTHREAD_COND_INITIALIZER;
static unsigned int own_tid = OWN_TID_BASE;
static unsigned int own_answer_tid = 0;
static int own_answer_code = 0;

static void pair_done(relay_pair *p) {
    /* Wake the other direction, then close once both have finished. */
    shutdown(p->client, SHUT_RDWR);
    shutdown(p->camera, SHUT_RDWR);
    pthread_mutex_lock(&p->lock);
    int left = --p->users;
    pthread_mutex_unlock(&p->lock);
    if (left == 0) {
        pthread_mutex_lock(&relay_lock);
        if (relay_command == p) relay_command = NULL;
        pthread_mutex_unlock(&relay_lock);
        close(p->client);
        close(p->camera);
        pthread_mutex_destroy(&p->lock);
        pthread_mutex_destroy(&p->to_camera);
        free(p);
    }
}

static int read_full(int fd, unsigned char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = recv(fd, buf, len, 0);
        if (n == 0) return -1;
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        buf += n; len -= (size_t)n;
    }
    return 0;
}

/* Computer to camera: byte for byte. */
static void *pump_up(void *arg) {
    relay_pair *p = arg;
    unsigned char buf[16384];
    int first = 1;
    for (;;) {
        ssize_t n = recv(p->client, buf, sizeof(buf), 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        if (first && n >= 8 && get32(buf + 4) == PKT_INIT_CMD_REQ) {    /* this is the command connection */
            pthread_mutex_lock(&relay_lock);
            relay_command = p;
            pthread_mutex_unlock(&relay_lock);
        }
        first = 0;
        pthread_mutex_lock(&p->to_camera);
        int failed = send_all(p->camera, buf, (size_t)n) != 0;
        pthread_mutex_unlock(&p->to_camera);
        if (failed) break;
    }
    pair_done(p);
    return NULL;
}

/* Camera to computer: packet by packet, minus empty data packets. */
static void *pump_down(void *arg) {
    relay_pair *p = arg;
    unsigned char hdr[8], buf[16384];
    for (;;) {
        if (read_full(p->camera, hdr, sizeof(hdr)) != 0) break;
        unsigned int len = get32(hdr), type = get32(hdr + 4);
        if (len < 8) break;
        size_t rest = len - 8;
        if (type == PKT_DATA && rest == 4) {                /* transaction ID only, no data */
            if (read_full(p->camera, buf, rest) != 0) break;
            continue;
        }
        if (type == PKT_CMD_RESPONSE && rest >= 6 && rest <= 64) {
            if (read_full(p->camera, buf, rest) != 0) break;
            unsigned int tid = get32(buf + 2);
            if (tid >= OWN_TID_BASE) {                      /* answer to this relay's own command */
                pthread_mutex_lock(&relay_lock);
                own_answer_tid = tid;
                own_answer_code = buf[0] | (buf[1] << 8);
                pthread_cond_broadcast(&relay_answer);
                pthread_mutex_unlock(&relay_lock);
                continue;
            }
            if (send_all(p->client, hdr, sizeof(hdr)) != 0 || send_all(p->client, buf, rest) != 0) break;
            continue;
        }
        if (send_all(p->client, hdr, sizeof(hdr)) != 0) break;
        int failed = 0;
        while (rest > 0 && !failed) {
            size_t n = rest < sizeof(buf) ? rest : sizeof(buf);
            failed = read_full(p->camera, buf, n) != 0 || send_all(p->client, buf, n) != 0;
            rest -= n;
        }
        if (failed) break;
    }
    pair_done(p);
    return NULL;
}

static void *relay_accept(void *arg) {
    int listener = (int)(intptr_t)arg;
    for (;;) {
        int client = accept(listener, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            return NULL;
        }
        pthread_mutex_lock(&relay_lock);
        struct sockaddr_in camera = relay_camera;
        pthread_mutex_unlock(&relay_lock);

        int one = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        int cam = tcp_connect(&camera, 3000);
        relay_pair *p = cam >= 0 ? calloc(1, sizeof(*p)) : NULL;
        if (!p) {
            if (cam >= 0) close(cam);
            close(client);                                  /* libgphoto2 sees the camera as gone */
            continue;
        }
        p->client = client; p->camera = cam; p->users = 2;
        pthread_mutex_init(&p->lock, NULL);
        pthread_mutex_init(&p->to_camera, NULL);
        pthread_t up, down;
        pthread_attr_t detached;
        pthread_attr_init(&detached);
        pthread_attr_setdetachstate(&detached, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&up, &detached, pump_up, p) != 0) {
            close(client); close(cam);
            pthread_mutex_destroy(&p->lock); pthread_mutex_destroy(&p->to_camera); free(p);
        } else if (pthread_create(&down, &detached, pump_down, p) != 0) {
            pair_done(p);                                   /* lets pump_up finish and clean up */
        }
        pthread_attr_destroy(&detached);
    }
}

/* Local port that leads to the camera at `host`; starts the relay on first use. */
static int relay_port_for(const char *host) {
    struct sockaddr_in camera;
    if (!parse_host(host, PTPIP_PORT, &camera)) return -1;

    pthread_mutex_lock(&relay_lock);
    relay_camera = camera;
    if (relay_listener < 0) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in local;
        memset(&local, 0, sizeof(local));
        local.sin_family = AF_INET;
        local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);     /* this computer only */
        socklen_t len = sizeof(local);
        pthread_t thread;
        if (fd >= 0 && bind(fd, (struct sockaddr *)&local, sizeof(local)) == 0 && listen(fd, 8) == 0 &&
            getsockname(fd, (struct sockaddr *)&local, &len) == 0 &&
            pthread_create(&thread, NULL, relay_accept, (void *)(intptr_t)fd) == 0) {
            pthread_detach(thread);
            relay_listener = fd;
            relay_port = ntohs(local.sin_port);
        } else if (fd >= 0) {
            close(fd);
        }
    }
    int port = relay_listener >= 0 ? relay_port : -1;
    pthread_mutex_unlock(&relay_lock);
    return port;
}

/* ---------- the commands this app sends itself ---------- */

/* libgphoto2 has no setting for these, so the relay sends them on the command
 * connection of the open session. All are Sony's vendor operation
 * ControlDevice (0x9207, the operation libgphoto2 itself uses for the record
 * button) with one of three control codes, as Sony's own phone app sends
 * them; the camera lists all three among its controls. Checked on a ZV-E10,
 * firmware 2.03:
 *
 *   0xD2DD ZoomOperation        +1 in, -1 out, 0 stop, as a 16-bit value (an
 *                               8-bit +1 is accepted and ignored); zooming
 *                               continues until the stop
 *   0xD2E4 RemoteTouchOperation a point on the picture, x 0..639 and
 *                               y 0..479, packed as x << 16 | y (32 bits):
 *                               touch focus or touch tracking, whichever the
 *                               camera is set to
 *   0xD2E5 CancelRemoteTouchOperation   button down (2), then up (1)
 *
 * Nothing else can be sent this way: the operation is fixed, the control code
 * comes from the functions below only, and the values are clamped. In
 * particular the camera also lists a format-card control; it is not here.
 *
 * Each must be called while libgphoto2 is idle (the app's camera queue), so
 * that the command does not land in the middle of one of its transactions.
 * They return 0 when the camera answered OK, the camera's response code when
 * it did not, or a negative number when there is no Wi-Fi session or no
 * answer. */
static int relay_control(unsigned int control, const unsigned char *value, unsigned int size) {
    if (size == 0 || size > 4) return -EINVAL;

    pthread_mutex_lock(&relay_lock);
    relay_pair *p = relay_command;
    if (!p) {
        pthread_mutex_unlock(&relay_lock);
        return -ENOTCONN;
    }
    unsigned int tid = ++own_tid;
    if (own_tid > 0x7AFFFFF0u) own_tid = OWN_TID_BASE;

    unsigned char pkt[22 + 20 + 12 + 4];
    unsigned char *q = pkt;
    put32(q, 22); put32(q + 4, PKT_CMD_REQUEST);            /* command: data goes to the camera */
    put32(q + 8, 2);
    q[12] = 0x07; q[13] = 0x92;                             /* 0x9207 ControlDevice */
    put32(q + 14, tid);
    put32(q + 18, control);
    q += 22;
    put32(q, 20); put32(q + 4, PKT_START_DATA);
    put32(q + 8, tid); put32(q + 12, size); put32(q + 16, 0);
    q += 20;
    put32(q, 12 + size); put32(q + 4, PKT_END_DATA);
    put32(q + 8, tid);
    memcpy(q + 12, value, size);

    pthread_mutex_lock(&p->to_camera);
    int failed = send_all(p->camera, pkt, 22 + 20 + 12 + size) != 0;
    pthread_mutex_unlock(&p->to_camera);

    int result = -EIO;
    if (!failed) {
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += 3;
        result = -ETIMEDOUT;
        while (own_answer_tid != tid) {
            if (pthread_cond_timedwait(&relay_answer, &relay_lock, &until) != 0) break;
        }
        if (own_answer_tid == tid) result = own_answer_code == 0x2001 ? 0 : own_answer_code;
    }
    pthread_mutex_unlock(&relay_lock);
    return result;
}

int zv_wifi_zoom(int direction) {
    short value = direction > 0 ? 1 : direction < 0 ? -1 : 0;
    unsigned char data[2] = { (unsigned char)(value & 0xff), (unsigned char)((value >> 8) & 0xff) };
    return relay_control(0xD2DD, data, 2);
}

int zv_wifi_touch(int x, int y) {
    if (x < 0) x = 0; else if (x > 639) x = 639;
    if (y < 0) y = 0; else if (y > 479) y = 479;
    unsigned char data[4];
    put32(data, ((unsigned int)x << 16) | (unsigned int)y);
    return relay_control(0xD2E4, data, 4);
}

int zv_wifi_touch_cancel(void) {
    unsigned char down[2] = { 2, 0 }, up[2] = { 1, 0 };
    int r = relay_control(0xD2E5, down, 2);
    int r2 = relay_control(0xD2E5, up, 2);
    return r != 0 ? r : r2;
}
