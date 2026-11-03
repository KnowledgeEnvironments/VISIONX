// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

#include "CXOrgBridge/visionx_ddx.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/socket.h>
#include <unistd.h>

#define VISIONX_XAUTH_FAMILY_WILD 65535
#endif

struct visionx_ddx_screen {
    uint32_t width;
    uint32_t height;
    visionx_surface_callbacks_t callbacks;
};

typedef struct visionx_server_state {
    int running;
    visionx_server_config_t config;
    visionx_surface_callbacks_t callbacks;
    uint8_t cookie[16];
    visionx_ddx_screen_t *screen;
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    pthread_t thread;
    int thread_started;
    int thread_detached;
    int stopping;
    int argc;
    char *argv[24];
    char display_arg[16];
    char screen_arg[32];
    char display_fd_arg[16];
    char auth_path[1024];
    char bind_address[64];
    int display_fd;
#endif
} visionx_server_state_t;

static visionx_server_state_t g_server;
static int g_log_enabled = 1;
static visionx_log_callback_t g_log_callback;
static void *g_log_context;

static void visionx_log(const char *format, ...) __attribute__((format(printf, 1, 2)));

static void visionx_log(const char *format, ...) {
    char message[2048];
    va_list args;

    if (!g_log_enabled) {
        return;
    }

    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    fprintf(stderr, "[VisionX C] %s\n", message);
    fflush(stderr);

    if (g_log_callback != NULL) {
        g_log_callback(g_log_context, message);
    }
}

static int visionx_should_log_hot_path(uint64_t *counter) {
    if (counter == NULL) {
        return 0;
    }
    *counter += 1;
    return *counter <= 12 || (*counter % 2400) == 0;
}

#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
extern int VisionXQueueClientOnOpenFD(int fd);
#endif

static void set_error(char *buffer, size_t capacity, const char *message) {
    if (buffer == NULL || capacity == 0) {
        return;
    }

    snprintf(buffer, capacity, "%s", message);
}

const char *visionx_ddx_version(void) {
    return "visionx-ddx/0.2 xorg-server/" VISIONX_XORG_SERVER_VERSION;
}

const char *visionx_xorg_server_version(void) {
    return VISIONX_XORG_SERVER_VERSION;
}

void visionx_server_set_logging_enabled(int enabled) {
    g_log_enabled = enabled != 0 ? 1 : 0;
}

void visionx_server_set_log_callback(visionx_log_callback_t callback, void *user_context) {
    g_log_callback = callback;
    g_log_context = user_context;
}

void visionx_ddx_log_message(const char *message) {
    visionx_log("%s", message == NULL ? "" : message);
}

int visionx_ddx_add_client_fd(int fd) {
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    if (fd < 0) {
        visionx_log("add client fd rejected invalid fd=%d", fd);
        return 0;
    }
    if (!g_server.running) {
        visionx_log("add client fd rejected server not running fd=%d", fd);
        close(fd);
        return 0;
    }
    int result = VisionXQueueClientOnOpenFD(fd);
    visionx_log("add client fd queued fd=%d result=%d", fd, result);
    return result;
#else
    (void)fd;
    return 0;
#endif
}

visionx_surface_callbacks_t visionx_ddx_current_surface_callbacks(void) {
    if (!g_server.running) {
        visionx_surface_callbacks_t callbacks;
        memset(&callbacks, 0, sizeof(callbacks));
        return callbacks;
    }

    return g_server.callbacks;
}

visionx_ddx_screen_t *visionx_ddx_current_screen(void) {
    return g_server.screen;
}

visionx_ddx_screen_t *visionx_ddx_create_screen(uint32_t width, uint32_t height, visionx_surface_callbacks_t callbacks) {
    visionx_ddx_screen_t *screen = (visionx_ddx_screen_t *)calloc(1, sizeof(visionx_ddx_screen_t));
    if (screen == NULL) {
        visionx_log("ddx create screen failed width=%u height=%u", (unsigned)width, (unsigned)height);
        return NULL;
    }

    screen->width = width;
    screen->height = height;
    screen->callbacks = callbacks;
    g_server.screen = screen;
    visionx_log("ddx create screen width=%u height=%u callbacks=%p", (unsigned)width, (unsigned)height, (void *)callbacks.map_window);
    return screen;
}

#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
extern int dix_main(int argc, char *argv[], char *envp[]);
extern void GiveUp(int sig);
extern int visionx_ddx_copy_window_pixels(visionx_xid_t window, uint8_t *destination, size_t destination_length, visionx_pixel_buffer_info_t *info);
extern int visionx_ddx_copy_window_pixel_region(visionx_xid_t window, visionx_rect_t region, uint8_t *destination, size_t destination_length, visionx_pixel_region_info_t *info);
extern int visionx_ddx_window_root_origin(visionx_xid_t window, int32_t *root_x, int32_t *root_y);
extern int visionx_ddx_queue_pointer_event(visionx_pointer_event_kind_t kind, uint8_t detail, int32_t root_x, int32_t root_y);
extern int visionx_ddx_queue_key_event(visionx_key_event_kind_t kind, uint8_t keycode);
extern int visionx_ddx_focus_window(visionx_xid_t window);
extern int visionx_ddx_activate_window(visionx_xid_t window, int should_raise);
extern int VisionXQueueClientOnOpenFD(int fd);
extern volatile char dispatchException;
extern volatile char isItTimeToYield;
extern int NoListenAll;

static void reset_xorg_dispatch_state(void) {
    dispatchException = 0;
    isItTimeToYield = 0;
    NoListenAll = 0;
    visionx_log("reset X.Org dispatch state before start");
}

static void clear_callbacks(void) {
    visionx_log("clearing DDX callbacks");
    visionx_surface_callbacks_t callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    g_server.callbacks = callbacks;
    if (g_server.screen != NULL) {
        g_server.screen->callbacks = callbacks;
    }
}

static void clear_server_argv(void) {
    for (int i = 0; i < g_server.argc; i++) {
        g_server.argv[i] = NULL;
    }
    g_server.argc = 0;
}

static int open_display_ready_fd(char *error_message, size_t error_message_capacity) {
    g_server.display_fd = open("/dev/null", O_WRONLY);
    if (g_server.display_fd < 0) {
        visionx_log("failed to open /dev/null for X.Org displayfd errno=%d message=%s", errno, strerror(errno));
        set_error(error_message, error_message_capacity, "failed to open /dev/null for embedded X.Org display readiness");
        return 0;
    }

    snprintf(g_server.display_fd_arg, sizeof(g_server.display_fd_arg), "%d", g_server.display_fd);
    visionx_log("using X.Org -displayfd %s to disable global /tmp display locking", g_server.display_fd_arg);
    return 1;
}

static void append_server_arg(const char *argument) {
    if (g_server.argc < (int)(sizeof(g_server.argv) / sizeof(g_server.argv[0])) - 1) {
        g_server.argv[g_server.argc++] = (char *)argument;
        g_server.argv[g_server.argc] = NULL;
    }
}

static int write_u16(FILE *file, uint16_t value) {
    uint8_t bytes[2] = {
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)(value & 0xff),
    };
    return fwrite(bytes, 1, sizeof(bytes), file) == sizeof(bytes);
}

static int write_bytes(FILE *file, const void *bytes, uint16_t length) {
    if (!write_u16(file, length)) {
        return 0;
    }
    if (length == 0) {
        return 1;
    }
    return fwrite(bytes, 1, length, file) == length;
}

static int write_auth_file(const visionx_server_config_t *config, char *error_message, size_t error_message_capacity) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }

    snprintf(g_server.auth_path, sizeof(g_server.auth_path), "%s/visionx-xauth-XXXXXX", tmpdir);
    visionx_log("creating Xauthority file template=%s", g_server.auth_path);

    int fd = mkstemp(g_server.auth_path);
    if (fd < 0) {
        visionx_log("failed to create Xauthority file errno=%d message=%s", errno, strerror(errno));
        set_error(error_message, error_message_capacity, "failed to create temporary Xauthority file");
        return 0;
    }

    FILE *file = fdopen(fd, "wb");
    if (file == NULL) {
        visionx_log("failed to open Xauthority file path=%s errno=%d message=%s", g_server.auth_path, errno, strerror(errno));
        close(fd);
        unlink(g_server.auth_path);
        g_server.auth_path[0] = '\0';
        set_error(error_message, error_message_capacity, "failed to open temporary Xauthority file");
        return 0;
    }

    char display_number[16];
    snprintf(display_number, sizeof(display_number), "%u", config->display_number);
    const char auth_name[] = "MIT-MAGIC-COOKIE-1";
    int ok =
        write_u16(file, VISIONX_XAUTH_FAMILY_WILD) &&
        write_bytes(file, NULL, 0) &&
        write_bytes(file, display_number, (uint16_t)strlen(display_number)) &&
        write_bytes(file, auth_name, (uint16_t)(sizeof(auth_name) - 1)) &&
        write_bytes(file, config->mit_magic_cookie, (uint16_t)config->mit_magic_cookie_length);

    if (fclose(file) != 0) {
        ok = 0;
    }

    if (!ok) {
        visionx_log("failed to write Xauthority file path=%s", g_server.auth_path);
        unlink(g_server.auth_path);
        g_server.auth_path[0] = '\0';
        set_error(error_message, error_message_capacity, "failed to write temporary Xauthority file");
        return 0;
    }

    visionx_log("wrote Xauthority file path=%s display=:%u cookieLength=%zu", g_server.auth_path, (unsigned)config->display_number, config->mit_magic_cookie_length);
    return 1;
}

static void remove_auth_file(void) {
    if (g_server.auth_path[0] != '\0') {
        visionx_log("removing Xauthority file path=%s", g_server.auth_path);
        unlink(g_server.auth_path);
        g_server.auth_path[0] = '\0';
    }
}

static void wake_xorg_listener(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        visionx_log("wake listener socket failed errno=%d message=%s", errno, strerror(errno));
        return;
    }

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(g_server.config.tcp_port);
    if (g_server.config.bind_address != NULL &&
        g_server.config.bind_address[0] != '\0' &&
        inet_pton(AF_INET, g_server.config.bind_address, &address.sin_addr) == 1) {
        visionx_log("wake listener using bind address=%s", g_server.config.bind_address);
    } else {
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    }

    int result = connect(fd, (const struct sockaddr *)&address, sizeof(address));
    if (result != 0) {
        visionx_log("wake listener connect failed port=%u errno=%d message=%s", (unsigned)g_server.config.tcp_port, errno, strerror(errno));
    } else {
        visionx_log("wake listener connected port=%u", (unsigned)g_server.config.tcp_port);
    }
    close(fd);
}

static void log_server_argv(void) {
    for (int i = 0; i < g_server.argc; i++) {
        visionx_log("xorg argv[%d]=%s", i, g_server.argv[i] == NULL ? "(null)" : g_server.argv[i]);
    }
}

static void *run_xorg_server(void *context) {
    (void)context;
    char *envp[] = { NULL };
    visionx_log("dix_main entering argc=%d", g_server.argc);
    int result = dix_main(g_server.argc, g_server.argv, envp);
    visionx_log("dix_main returned result=%d", result);
    visionx_surface_callbacks_t callbacks = g_server.callbacks;
    void *callback_context = callbacks.user_context;
    g_server.running = 0;
    g_server.stopping = 0;
    g_server.thread_started = 0;
    g_server.thread_detached = 0;
    g_server.screen = NULL;
    remove_auth_file();
    if (callbacks.server_exited != NULL) {
        callbacks.server_exited(callback_context, result);
    }
    return (void *)(intptr_t)result;
}

static int start_embedded_xorg(const visionx_server_config_t *config, visionx_surface_callbacks_t callbacks, char *error_message, size_t error_message_capacity) {
    if (g_server.running || g_server.thread_started || g_server.stopping) {
        visionx_log("start rejected running=%d thread_started=%d stopping=%d", g_server.running, g_server.thread_started, g_server.stopping);
        set_error(error_message, error_message_capacity, "VisionX X.Org backend is still running or stopping");
        return 0;
    }

    uint32_t expected_port = 6000 + config->display_number;
    if (config->tcp_port != expected_port) {
        visionx_log("start rejected invalid port port=%u expected=%u display=:%u", (unsigned)config->tcp_port, (unsigned)expected_port, (unsigned)config->display_number);
        set_error(error_message, error_message_capacity, "X.Org TCP port must be 6000 + display number for the embedded backend");
        return 0;
    }

    visionx_log(
        "start embedded X.Org display=:%u port=%u bind=%s auth=%s screen=%ux%u experimentalGLX=%u callback=%p",
        (unsigned)config->display_number,
        (unsigned)config->tcp_port,
        (config->bind_address != NULL && config->bind_address[0] != '\0') ? config->bind_address : "all",
        config->auth_mode == VISIONX_AUTH_MODE_DISABLED ? "disabled" : "MIT-MAGIC-COOKIE-1",
        (unsigned)config->screen_width,
        (unsigned)config->screen_height,
        (unsigned)config->experimental_glx,
        (void *)callbacks.map_window
    );

    memset(&g_server, 0, sizeof(g_server));
    g_server.display_fd = -1;
    g_server.config = *config;
    if (config->bind_address != NULL && config->bind_address[0] != '\0') {
        strlcpy(g_server.bind_address, config->bind_address, sizeof(g_server.bind_address));
        g_server.config.bind_address = g_server.bind_address;
        setenv("VISIONX_XORG_BIND_ADDRESS", g_server.bind_address, 1);
        visionx_log("configured X.Org bind address=%s", g_server.bind_address);
    } else {
        unsetenv("VISIONX_XORG_BIND_ADDRESS");
        g_server.config.bind_address = NULL;
        visionx_log("configured X.Org bind address=all");
    }
    setenv("VISIONX_XKB_MINIMAL", "1", 1);
    visionx_log("configured X.Org minimal built-in XKB keymap");
    if (config->experimental_glx != 0) {
        setenv("VISIONX_EXPERIMENTAL_GLX", "1", 1);
        setenv("VISIONX_XORG_TCP_RCVBUF", "1024", 1);
        setenv("VISIONX_GLX_SWAP_PACE_MS", "0", 1);
        visionx_log("configured experimental GLX provider flag=enabled tcpReceiveBuffer=1024 swapPaceMs=0");
    } else {
        unsetenv("VISIONX_EXPERIMENTAL_GLX");
        unsetenv("VISIONX_XORG_TCP_RCVBUF");
        unsetenv("VISIONX_GLX_SWAP_PACE_MS");
        visionx_log("configured experimental GLX provider flag=disabled");
    }
    g_server.callbacks = callbacks;
    if (config->auth_mode == VISIONX_AUTH_MODE_MIT_MAGIC_COOKIE) {
        memcpy(g_server.cookie, config->mit_magic_cookie, sizeof(g_server.cookie));
        g_server.config.mit_magic_cookie = g_server.cookie;
    }

    if (config->auth_mode == VISIONX_AUTH_MODE_MIT_MAGIC_COOKIE &&
        !write_auth_file(&g_server.config, error_message, error_message_capacity)) {
        visionx_log("start failed while writing auth file");
        memset(&g_server, 0, sizeof(g_server));
        return 0;
    }

    if (!open_display_ready_fd(error_message, error_message_capacity)) {
        remove_auth_file();
        memset(&g_server, 0, sizeof(g_server));
        return 0;
    }

    snprintf(g_server.display_arg, sizeof(g_server.display_arg), ":%u", config->display_number);
    snprintf(
        g_server.screen_arg,
        sizeof(g_server.screen_arg),
        "%ux%ux24",
        config->screen_width,
        config->screen_height
    );

    clear_server_argv();
    reset_xorg_dispatch_state();
    const char *external_listener = getenv("VISIONX_XORG_EXTERNAL_LISTENER");
    if (external_listener != NULL && strcmp(external_listener, "1") == 0) {
        NoListenAll = 1;
        visionx_log("configured X.Org internal listeners=disabled externalListener=Swift bridge");
    } else {
        NoListenAll = 0;
        visionx_log("configured X.Org internal listeners=enabled");
    }
    append_server_arg("Xvisionx");
    append_server_arg(g_server.display_arg);
    append_server_arg("-screen");
    append_server_arg(g_server.screen_arg);
    append_server_arg("-listen");
    append_server_arg("inet");
    append_server_arg("-nolisten");
    append_server_arg("inet6");
    append_server_arg("-nolisten");
    append_server_arg("unix");
    append_server_arg("-nolisten");
    append_server_arg("local");
    append_server_arg("-noreset");
    append_server_arg("-displayfd");
    append_server_arg(g_server.display_fd_arg);

    const char *font_path = getenv("VISIONX_XORG_FONT_PATH");
    if (font_path != NULL && font_path[0] != '\0') {
        append_server_arg("-fp");
        append_server_arg((char *)font_path);
        visionx_log("configured X.Org font path=%s", font_path);
    } else {
        visionx_log("configured X.Org font path=built-ins");
    }

    if (config->auth_mode == VISIONX_AUTH_MODE_DISABLED) {
        append_server_arg("-ac");
    } else {
        append_server_arg("-auth");
        append_server_arg(g_server.auth_path);
    }
    log_server_argv();

    g_server.running = 1;
    int error = pthread_create(&g_server.thread, NULL, run_xorg_server, NULL);
    if (error != 0) {
        visionx_log("pthread_create failed error=%d message=%s", error, strerror(error));
        if (g_server.display_fd >= 0) {
            close(g_server.display_fd);
            g_server.display_fd = -1;
        }
        g_server.running = 0;
        remove_auth_file();
        memset(&g_server, 0, sizeof(g_server));
        set_error(error_message, error_message_capacity, strerror(error));
        return 0;
    }

    g_server.thread_started = 1;
    visionx_log("pthread_create succeeded");
    return 1;
}
#endif

void visionx_ddx_destroy_screen(visionx_ddx_screen_t *screen) {
    visionx_log("ddx destroy screen screen=%p", (void *)screen);
    if (g_server.screen == screen) {
        g_server.screen = NULL;
    }
    free(screen);
}

void visionx_ddx_map_window(visionx_ddx_screen_t *screen, visionx_xid_t window, visionx_rect_t rect, visionx_window_metadata_t metadata) {
    if (screen == NULL || screen->callbacks.map_window == NULL) {
        visionx_log("ddx map skipped window=%u screen=%p callback=%p", (unsigned)window, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.map_window);
        return;
    }

    visionx_log("ddx map window=%u rect=%dx%d+%d+%d title=%s class=%s", (unsigned)window, rect.width, rect.height, rect.x, rect.y, metadata.title == NULL ? "" : metadata.title, metadata.wm_class == NULL ? "" : metadata.wm_class);
    screen->callbacks.map_window(screen->callbacks.user_context, window, rect, metadata);
}

void visionx_ddx_unmap_window(visionx_ddx_screen_t *screen, visionx_xid_t window) {
    if (screen == NULL || screen->callbacks.unmap_window == NULL) {
        visionx_log("ddx unmap skipped window=%u screen=%p callback=%p", (unsigned)window, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.unmap_window);
        return;
    }

    visionx_log("ddx unmap window=%u", (unsigned)window);
    screen->callbacks.unmap_window(screen->callbacks.user_context, window);
}

void visionx_ddx_configure_window(visionx_ddx_screen_t *screen, visionx_xid_t window, visionx_rect_t rect) {
    if (screen == NULL || screen->callbacks.configure_window == NULL) {
        visionx_log("ddx configure skipped window=%u screen=%p callback=%p", (unsigned)window, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.configure_window);
        return;
    }

    visionx_log("ddx configure window=%u rect=%dx%d+%d+%d", (unsigned)window, rect.width, rect.height, rect.x, rect.y);
    screen->callbacks.configure_window(screen->callbacks.user_context, window, rect);
}

void visionx_ddx_update_window_metadata(visionx_ddx_screen_t *screen, visionx_xid_t window, visionx_window_metadata_t metadata) {
    if (screen == NULL || screen->callbacks.window_metadata_changed == NULL) {
        visionx_log("ddx metadata skipped window=%u screen=%p callback=%p", (unsigned)window, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.window_metadata_changed);
        return;
    }

    visionx_log("ddx metadata window=%u title=%s class=%s", (unsigned)window, metadata.title == NULL ? "" : metadata.title, metadata.wm_class == NULL ? "" : metadata.wm_class);
    screen->callbacks.window_metadata_changed(screen->callbacks.user_context, window, metadata);
}

void visionx_ddx_mark_damage(visionx_ddx_screen_t *screen, visionx_xid_t window, visionx_rect_t rect) {
    visionx_ddx_mark_damage_regions(screen, window, &rect, 1, 0);
}

void visionx_ddx_mark_damage_regions(visionx_ddx_screen_t *screen, visionx_xid_t window, const visionx_rect_t *rects, size_t rect_count, uint8_t full_refresh) {
    if (screen == NULL) {
        visionx_log("ddx damage skipped window=%u screen=%p callback=%p", (unsigned)window, (void *)screen, NULL);
        return;
    }

    if (screen->callbacks.damage_window_regions != NULL) {
        screen->callbacks.damage_window_regions(screen->callbacks.user_context, window, rects, rect_count, full_refresh);
        return;
    }

    if (screen->callbacks.damage_window == NULL || rects == NULL || rect_count == 0) {
        visionx_log("ddx damage skipped window=%u screen=%p callback=%p", (unsigned)window, (void *)screen, (void *)screen->callbacks.damage_window);
        return;
    }

    for (size_t i = 0; i < rect_count; i++) {
        screen->callbacks.damage_window(screen->callbacks.user_context, window, rects[i]);
    }
}

void visionx_ddx_destroy_window(visionx_ddx_screen_t *screen, visionx_xid_t window) {
    if (screen == NULL || screen->callbacks.destroy_window == NULL) {
        visionx_log("ddx destroy skipped window=%u screen=%p callback=%p", (unsigned)window, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.destroy_window);
        return;
    }

    visionx_log("ddx destroy window=%u", (unsigned)window);
    screen->callbacks.destroy_window(screen->callbacks.user_context, window);
}

int visionx_ddx_glx_create_context(visionx_ddx_screen_t *screen, visionx_glx_context_config_t config) {
    if (screen == NULL || screen->callbacks.glx_create_context == NULL) {
        visionx_log("ddx GLX create context skipped context=%u screen=%p callback=%p", (unsigned)config.context, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_create_context);
        return 0;
    }

    visionx_log("ddx GLX create context=%u visual=%u share=%u direct=%u", (unsigned)config.context, (unsigned)config.visual_id, (unsigned)config.share_context, (unsigned)config.direct);
    return screen->callbacks.glx_create_context(screen->callbacks.user_context, config);
}

void visionx_ddx_glx_destroy_context(visionx_ddx_screen_t *screen, visionx_xid_t context) {
    if (screen == NULL || screen->callbacks.glx_destroy_context == NULL) {
        visionx_log("ddx GLX destroy context skipped context=%u screen=%p callback=%p", (unsigned)context, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_destroy_context);
        return;
    }

    visionx_log("ddx GLX destroy context=%u", (unsigned)context);
    screen->callbacks.glx_destroy_context(screen->callbacks.user_context, context);
}

int visionx_ddx_glx_create_drawable(visionx_ddx_screen_t *screen, visionx_glx_drawable_config_t config) {
    if (screen == NULL || screen->callbacks.glx_create_drawable == NULL) {
        visionx_log("ddx GLX create drawable skipped drawable=%u screen=%p callback=%p", (unsigned)config.drawable, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_create_drawable);
        return 0;
    }

    visionx_log(
        "ddx GLX create drawable=%u backing=%u presentation=%u+%d+%d kind=%u visual=%u size=%ux%u",
        (unsigned)config.drawable,
        (unsigned)config.backing_xid,
        (unsigned)config.presentation_xid,
        (int)config.presentation_x,
        (int)config.presentation_y,
        (unsigned)config.kind,
        (unsigned)config.visual_id,
        (unsigned)config.width,
        (unsigned)config.height
    );
    return screen->callbacks.glx_create_drawable(screen->callbacks.user_context, config);
}

void visionx_ddx_glx_destroy_drawable(visionx_ddx_screen_t *screen, visionx_xid_t drawable) {
    if (screen == NULL || screen->callbacks.glx_destroy_drawable == NULL) {
        visionx_log("ddx GLX destroy drawable skipped drawable=%u screen=%p callback=%p", (unsigned)drawable, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_destroy_drawable);
        return;
    }

    visionx_log("ddx GLX destroy drawable=%u", (unsigned)drawable);
    screen->callbacks.glx_destroy_drawable(screen->callbacks.user_context, drawable);
}

int visionx_ddx_glx_resize_drawable(visionx_ddx_screen_t *screen, visionx_xid_t drawable, uint32_t width, uint32_t height) {
    if (screen == NULL || screen->callbacks.glx_resize_drawable == NULL) {
        visionx_log("ddx GLX resize drawable skipped drawable=%u screen=%p callback=%p", (unsigned)drawable, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_resize_drawable);
        return 0;
    }

    visionx_log("ddx GLX resize drawable=%u size=%ux%u", (unsigned)drawable, (unsigned)width, (unsigned)height);
    return screen->callbacks.glx_resize_drawable(screen->callbacks.user_context, drawable, width, height);
}

int visionx_ddx_glx_make_current(visionx_ddx_screen_t *screen, visionx_xid_t context, visionx_xid_t drawable) {
    if (screen == NULL || screen->callbacks.glx_make_current == NULL) {
        visionx_log("ddx GLX make current skipped context=%u drawable=%u screen=%p callback=%p", (unsigned)context, (unsigned)drawable, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_make_current);
        return 0;
    }

    visionx_log("ddx GLX make current context=%u drawable=%u", (unsigned)context, (unsigned)drawable);
    return screen->callbacks.glx_make_current(screen->callbacks.user_context, context, drawable);
}

int visionx_ddx_glx_swap_buffers(visionx_ddx_screen_t *screen, visionx_xid_t context, visionx_xid_t drawable, uint64_t swap_serial, uint8_t should_present) {
    if (screen == NULL || screen->callbacks.glx_swap_buffers == NULL) {
        visionx_log("ddx GLX swap buffers skipped context=%u drawable=%u serial=%llu present=%u screen=%p callback=%p", (unsigned)context, (unsigned)drawable, (unsigned long long)swap_serial, (unsigned)should_present, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_swap_buffers);
        return 0;
    }

    static uint64_t swap_log_count = 0;
    if (visionx_should_log_hot_path(&swap_log_count)) {
        visionx_log("ddx GLX swap buffers context=%u drawable=%u serial=%llu present=%u count=%llu", (unsigned)context, (unsigned)drawable, (unsigned long long)swap_serial, (unsigned)should_present, (unsigned long long)swap_log_count);
    }
    return screen->callbacks.glx_swap_buffers(screen->callbacks.user_context, context, drawable, swap_serial, should_present);
}

#if !defined(VISIONX_ENABLE_EMBEDDED_XORG)
void visionx_ddx_glx_swap_presented(visionx_xid_t drawable, uint64_t swap_serial) {
    (void)drawable;
    (void)swap_serial;
}
#endif

int visionx_ddx_glx_execute_render(visionx_ddx_screen_t *screen, visionx_xid_t context, const uint8_t *commands, size_t command_length, uint8_t byte_swapped, uint8_t capture_draw_calls) {
    if (screen == NULL || screen->callbacks.glx_execute_render == NULL) {
        visionx_log("ddx GLX render skipped context=%u length=%zu capture=%u screen=%p callback=%p", (unsigned)context, command_length, (unsigned)capture_draw_calls, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_execute_render);
        return 0;
    }

    static uint64_t render_log_count = 0;
    if (visionx_should_log_hot_path(&render_log_count)) {
        visionx_log(
            "ddx GLX render context=%u length=%zu swapped=%u capture=%u count=%llu",
            (unsigned)context,
            command_length,
            (unsigned)byte_swapped,
            (unsigned)capture_draw_calls,
            (unsigned long long)render_log_count
        );
    }
    return screen->callbacks.glx_execute_render(screen->callbacks.user_context, context, commands, command_length, byte_swapped, capture_draw_calls);
}

int visionx_ddx_glx_new_list(visionx_ddx_screen_t *screen, visionx_xid_t context, uint32_t list, uint32_t mode) {
    if (screen == NULL || screen->callbacks.glx_new_list == NULL) {
        visionx_log("ddx GLX new list skipped context=%u list=%u mode=%u screen=%p callback=%p", (unsigned)context, (unsigned)list, (unsigned)mode, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_new_list);
        return 0;
    }

    visionx_log("ddx GLX new list context=%u list=%u mode=%u", (unsigned)context, (unsigned)list, (unsigned)mode);
    return screen->callbacks.glx_new_list(screen->callbacks.user_context, context, list, mode);
}

int visionx_ddx_glx_end_list(visionx_ddx_screen_t *screen, visionx_xid_t context) {
    if (screen == NULL || screen->callbacks.glx_end_list == NULL) {
        visionx_log("ddx GLX end list skipped context=%u screen=%p callback=%p", (unsigned)context, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_end_list);
        return 0;
    }

    visionx_log("ddx GLX end list context=%u", (unsigned)context);
    return screen->callbacks.glx_end_list(screen->callbacks.user_context, context);
}

int visionx_ddx_glx_delete_lists(visionx_ddx_screen_t *screen, visionx_xid_t context, uint32_t list, uint32_t range) {
    if (screen == NULL || screen->callbacks.glx_delete_lists == NULL) {
        visionx_log("ddx GLX delete lists skipped context=%u list=%u range=%u screen=%p callback=%p", (unsigned)context, (unsigned)list, (unsigned)range, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_delete_lists);
        return 0;
    }

    visionx_log("ddx GLX delete lists context=%u list=%u range=%u", (unsigned)context, (unsigned)list, (unsigned)range);
    return screen->callbacks.glx_delete_lists(screen->callbacks.user_context, context, list, range);
}

uint32_t visionx_ddx_glx_gen_lists(visionx_ddx_screen_t *screen, visionx_xid_t context, uint32_t range) {
    if (screen == NULL || screen->callbacks.glx_gen_lists == NULL) {
        visionx_log("ddx GLX gen lists skipped context=%u range=%u screen=%p callback=%p", (unsigned)context, (unsigned)range, (void *)screen, screen == NULL ? NULL : (void *)screen->callbacks.glx_gen_lists);
        return 0;
    }

    visionx_log("ddx GLX gen lists context=%u range=%u", (unsigned)context, (unsigned)range);
    return screen->callbacks.glx_gen_lists(screen->callbacks.user_context, context, range);
}

#if !defined(VISIONX_ENABLE_EMBEDDED_XORG)
int visionx_ddx_copy_window_pixels(visionx_xid_t window, uint8_t *destination, size_t destination_length, visionx_pixel_buffer_info_t *info) {
    (void)window;
    (void)destination;
    (void)destination_length;
    if (info != NULL) {
        memset(info, 0, sizeof(*info));
    }
    return 0;
}

int visionx_ddx_copy_window_pixel_region(visionx_xid_t window, visionx_rect_t region, uint8_t *destination, size_t destination_length, visionx_pixel_region_info_t *info) {
    (void)window;
    (void)region;
    (void)destination;
    (void)destination_length;
    if (info != NULL) {
        memset(info, 0, sizeof(*info));
    }
    return 0;
}
#endif

int visionx_server_start(const visionx_server_config_t *config, visionx_surface_callbacks_t callbacks, char *error_message, size_t error_message_capacity) {
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    if (g_server.running || g_server.thread_started || g_server.stopping) {
#else
    if (g_server.running) {
#endif
        visionx_log("server_start rejected: already running/stopping");
        set_error(error_message, error_message_capacity, "VisionX X.Org backend is already running");
        return 0;
    }

    if (config == NULL) {
        visionx_log("server_start rejected: missing config");
        set_error(error_message, error_message_capacity, "missing VisionX server configuration");
        return 0;
    }

    if (config->tcp_port == 0) {
        visionx_log("server_start rejected: zero TCP port");
        set_error(error_message, error_message_capacity, "TCP port must be non-zero");
        return 0;
    }

    if (config->screen_width == 0 || config->screen_height == 0) {
        visionx_log("server_start rejected: invalid screen %ux%u", (unsigned)config->screen_width, (unsigned)config->screen_height);
        set_error(error_message, error_message_capacity, "screen size must be non-zero");
        return 0;
    }

    if (config->auth_mode == VISIONX_AUTH_MODE_MIT_MAGIC_COOKIE) {
        if (config->mit_magic_cookie == NULL || config->mit_magic_cookie_length != sizeof(g_server.cookie)) {
            visionx_log("server_start rejected: invalid cookie length=%zu", config->mit_magic_cookie_length);
            set_error(error_message, error_message_capacity, "MIT-MAGIC-COOKIE-1 requires a 16-byte cookie");
            return 0;
        }
    }
    else if (config->auth_mode != VISIONX_AUTH_MODE_DISABLED) {
        visionx_log("server_start rejected: unsupported auth mode=%d", config->auth_mode);
        set_error(error_message, error_message_capacity, "unsupported VisionX authentication mode");
        return 0;
    }

#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    return start_embedded_xorg(config, callbacks, error_message, error_message_capacity);
#else
    (void)callbacks;
    visionx_log("server_start failed: embedded X.Org backend not linked");
    set_error(
        error_message,
        error_message_capacity,
        "embedded X.Org backend is not linked; build/link hw/visionx before starting the production X11 server"
    );
    return 0;
#endif
}

void visionx_server_stop(void) {
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    visionx_log("server_stop requested running=%d thread_started=%d stopping=%d detached=%d screen=%p", g_server.running, g_server.thread_started, g_server.stopping, g_server.thread_detached, (void *)g_server.screen);
    if (!g_server.running && !g_server.thread_started) {
        remove_auth_file();
        return;
    }

    clear_callbacks();

    if (g_server.thread_started) {
        if (!g_server.stopping) {
            g_server.stopping = 1;
            visionx_log("server_stop signaling GiveUp");
            GiveUp(0);
            wake_xorg_listener();
        }
        if (!g_server.thread_detached) {
            visionx_log("server_stop detaching X.Org thread");
            pthread_detach(g_server.thread);
            g_server.thread_detached = 1;
        }
        visionx_log("server_stop returning while X.Org thread exits asynchronously");
        return;
    }
#else
    if (!g_server.running) {
        return;
    }
#endif

    if (g_server.screen != NULL) {
        visionx_ddx_destroy_screen(g_server.screen);
    }
    memset(&g_server, 0, sizeof(g_server));
    visionx_log("server_stop completed synchronous cleanup");
}

int visionx_server_force_stop(uint32_t timeout_ms) {
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    visionx_log("server_force_stop requested timeout_ms=%u running=%d thread_started=%d stopping=%d detached=%d screen=%p", (unsigned)timeout_ms, g_server.running, g_server.thread_started, g_server.stopping, g_server.thread_detached, (void *)g_server.screen);
    clear_callbacks();

    if (!g_server.running && !g_server.thread_started) {
        remove_auth_file();
        return 1;
    }

    if (g_server.thread_started) {
        g_server.stopping = 1;
        visionx_log("server_force_stop signaling GiveUp and waking listener");
        GiveUp(0);
        wake_xorg_listener();
        if (!g_server.thread_detached) {
            visionx_log("server_force_stop detaching X.Org thread");
            pthread_detach(g_server.thread);
            g_server.thread_detached = 1;
        }
        if (visionx_server_wait_until_stopped(timeout_ms)) {
            return 1;
        }

        visionx_log("server_force_stop timed out; embedded X.Org thread still active, app relaunch required before restart");
        return 0;
    }
#else
    (void)timeout_ms;
    if (!g_server.running) {
        return 1;
    }
#endif

    if (g_server.screen != NULL) {
        visionx_ddx_destroy_screen(g_server.screen);
    }
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    remove_auth_file();
#endif
    memset(&g_server, 0, sizeof(g_server));
    visionx_log("server_force_stop completed synchronous cleanup");
    return 1;
}

int visionx_server_wait_until_stopped(uint32_t timeout_ms) {
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    const uint32_t interval_ms = 10;
    uint32_t elapsed_ms = 0;

    while (g_server.running || g_server.thread_started || g_server.stopping) {
        if (elapsed_ms >= timeout_ms) {
            visionx_log(
                "wait_until_stopped timed out timeout_ms=%u running=%d thread_started=%d stopping=%d",
                (unsigned)timeout_ms,
                g_server.running,
                g_server.thread_started,
                g_server.stopping
            );
            return 0;
        }

        usleep(interval_ms * 1000);
        elapsed_ms += interval_ms;
    }

    visionx_log("wait_until_stopped completed elapsed_ms=%u", (unsigned)elapsed_ms);
    return 1;
#else
    (void)timeout_ms;
    return !g_server.running;
#endif
}

int visionx_server_is_running(void) {
    return g_server.running;
}

int visionx_server_send_pointer(visionx_xid_t window, visionx_pointer_event_kind_t kind, uint8_t detail, int32_t x, int32_t y) {
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    int32_t root_x = x;
    int32_t root_y = y;
    int32_t origin_x = 0;
    int32_t origin_y = 0;

    if (!g_server.running || g_server.stopping || g_server.screen == NULL) {
        return 0;
    }

    if (window != 0 && visionx_ddx_window_root_origin(window, &origin_x, &origin_y)) {
        root_x += origin_x;
        root_y += origin_y;
    }

    int queued = visionx_ddx_queue_pointer_event(kind, detail, root_x, root_y);
    if (kind != VISIONX_POINTER_EVENT_MOTION) {
        visionx_log(
            "input pointer window=%u kind=%d detail=%u local=%d,%d origin=%d,%d root=%d,%d queued=%d",
            (unsigned)window,
            (int)kind,
            (unsigned)detail,
            x,
            y,
            origin_x,
            origin_y,
            root_x,
            root_y,
            queued
        );
    }
    return queued;
#else
    (void)window;
    (void)kind;
    (void)detail;
    (void)x;
    (void)y;
    return g_server.running;
#endif
}

int visionx_server_send_key(visionx_xid_t window, visionx_key_event_kind_t kind, uint8_t keycode, uint32_t modifiers) {
    (void)window;
    (void)modifiers;
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    if (!g_server.running || g_server.stopping || g_server.screen == NULL) {
        return 0;
    }

    int queued = visionx_ddx_queue_key_event(kind, keycode);
    visionx_log(
        "input key window=%u kind=%d keycode=%u modifiers=%u queued=%d",
        (unsigned)window,
        (int)kind,
        (unsigned)keycode,
        (unsigned)modifiers,
        queued
    );
    return queued;
#else
    (void)kind;
    (void)keycode;
    return g_server.running;
#endif
}

int visionx_server_focus_window(visionx_xid_t window) {
    return visionx_server_activate_window(window, 0);
}

int visionx_server_activate_window(visionx_xid_t window, int should_raise) {
#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    if (!g_server.running || g_server.stopping || g_server.screen == NULL) {
        return 0;
    }

    int queued = visionx_ddx_activate_window(window, should_raise);
    visionx_log(
        "input activate window=%u raise=%d queued=%d",
        (unsigned)window,
        should_raise != 0,
        queued
    );
    return queued;
#else
    (void)window;
    (void)should_raise;
    return 0;
#endif
}

int visionx_server_configure_window(visionx_xid_t window, visionx_rect_t rect) {
    if (!g_server.running || g_server.screen == NULL) {
        return 0;
    }

    visionx_ddx_configure_window(g_server.screen, window, rect);
    return 1;
}

int visionx_server_close_window(visionx_xid_t window) {
    if (!g_server.running || g_server.screen == NULL) {
        return 0;
    }

    visionx_ddx_destroy_window(g_server.screen, window);
    return 1;
}

int visionx_server_copy_window_pixels(visionx_xid_t window, uint8_t *destination, size_t destination_length, visionx_pixel_buffer_info_t *info) {
    if (info != NULL) {
        memset(info, 0, sizeof(*info));
    }

    if (!g_server.running || info == NULL) {
        return 0;
    }

#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    if (g_server.stopping || g_server.screen == NULL) {
        return 0;
    }
    return visionx_ddx_copy_window_pixels(window, destination, destination_length, info);
#else
    (void)window;
    (void)destination;
    (void)destination_length;
    return 0;
#endif
}

int visionx_server_copy_window_pixel_region(visionx_xid_t window, visionx_rect_t region, uint8_t *destination, size_t destination_length, visionx_pixel_region_info_t *info) {
    if (info != NULL) {
        memset(info, 0, sizeof(*info));
    }

    if (!g_server.running || info == NULL) {
        return 0;
    }

#if defined(VISIONX_ENABLE_EMBEDDED_XORG)
    if (g_server.stopping || g_server.screen == NULL) {
        return 0;
    }
    return visionx_ddx_copy_window_pixel_region(window, region, destination, destination_length, info);
#else
    (void)window;
    (void)region;
    (void)destination;
    (void)destination_length;
    return 0;
#endif
}
