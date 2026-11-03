// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

#ifndef VISIONX_DDX_H
#define VISIONX_DDX_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VISIONX_XORG_SERVER_VERSION "21.1.25"

typedef uint32_t visionx_xid_t;

typedef struct visionx_rect {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
} visionx_rect_t;

typedef enum visionx_auth_mode {
    VISIONX_AUTH_MODE_MIT_MAGIC_COOKIE = 0,
    VISIONX_AUTH_MODE_DISABLED = 1
} visionx_auth_mode_t;

typedef enum visionx_pointer_event_kind {
    VISIONX_POINTER_EVENT_MOTION = 0,
    VISIONX_POINTER_EVENT_BUTTON_PRESS = 1,
    VISIONX_POINTER_EVENT_BUTTON_RELEASE = 2,
    VISIONX_POINTER_EVENT_ENTER = 3,
    VISIONX_POINTER_EVENT_LEAVE = 4
} visionx_pointer_event_kind_t;

typedef enum visionx_key_event_kind {
    VISIONX_KEY_EVENT_PRESS = 0,
    VISIONX_KEY_EVENT_RELEASE = 1
} visionx_key_event_kind_t;

typedef enum visionx_glx_drawable_kind {
    VISIONX_GLX_DRAWABLE_WINDOW = 0,
    VISIONX_GLX_DRAWABLE_PIXMAP = 1
} visionx_glx_drawable_kind_t;

typedef struct visionx_glx_context_config {
    visionx_xid_t context;
    uint32_t visual_id;
    visionx_xid_t share_context;
    uint8_t has_share_context;
    uint8_t direct;
} visionx_glx_context_config_t;

typedef struct visionx_glx_drawable_config {
    visionx_xid_t drawable;
    visionx_xid_t backing_xid;
    visionx_xid_t presentation_xid;
    visionx_glx_drawable_kind_t kind;
    uint32_t visual_id;
    uint32_t width;
    uint32_t height;
    int32_t presentation_x;
    int32_t presentation_y;
} visionx_glx_drawable_config_t;

typedef struct visionx_window_metadata {
    const char *title;
    const char *wm_instance;
    const char *wm_class;
    uint32_t transient_for;
    uint8_t has_transient_for;
    uint8_t override_redirect;
    uint8_t accepts_delete_window;
    uint8_t has_min_size;
    uint8_t has_max_size;
    uint8_t has_resize_increment;
    uint8_t has_base_size;
    int32_t min_width;
    int32_t min_height;
    int32_t max_width;
    int32_t max_height;
    int32_t width_increment;
    int32_t height_increment;
    int32_t base_width;
    int32_t base_height;
} visionx_window_metadata_t;

typedef struct visionx_pixel_buffer_info {
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
} visionx_pixel_buffer_info_t;

typedef struct visionx_pixel_region_info {
    uint32_t window_width;
    uint32_t window_height;
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
} visionx_pixel_region_info_t;

typedef struct visionx_surface_callbacks {
    void *user_context;
    void (*map_window)(void *user_context, visionx_xid_t window, visionx_rect_t rect, visionx_window_metadata_t metadata);
    void (*unmap_window)(void *user_context, visionx_xid_t window);
    void (*configure_window)(void *user_context, visionx_xid_t window, visionx_rect_t rect);
    void (*window_metadata_changed)(void *user_context, visionx_xid_t window, visionx_window_metadata_t metadata);
    void (*damage_window)(void *user_context, visionx_xid_t window, visionx_rect_t rect);
    void (*damage_window_regions)(void *user_context, visionx_xid_t window, const visionx_rect_t *rects, size_t rect_count, uint8_t full_refresh);
    void (*destroy_window)(void *user_context, visionx_xid_t window);
    void (*server_exited)(void *user_context, int result);
    int (*glx_create_context)(void *user_context, visionx_glx_context_config_t config);
    void (*glx_destroy_context)(void *user_context, visionx_xid_t context);
    int (*glx_create_drawable)(void *user_context, visionx_glx_drawable_config_t config);
    void (*glx_destroy_drawable)(void *user_context, visionx_xid_t drawable);
    int (*glx_resize_drawable)(void *user_context, visionx_xid_t drawable, uint32_t width, uint32_t height);
    int (*glx_make_current)(void *user_context, visionx_xid_t context, visionx_xid_t drawable);
    int (*glx_swap_buffers)(void *user_context, visionx_xid_t context, visionx_xid_t drawable, uint64_t swap_serial, uint8_t should_present);
    int (*glx_execute_render)(void *user_context, visionx_xid_t context, const uint8_t *commands, size_t command_length, uint8_t byte_swapped, uint8_t capture_draw_calls);
    int (*glx_new_list)(void *user_context, visionx_xid_t context, uint32_t list, uint32_t mode);
    int (*glx_end_list)(void *user_context, visionx_xid_t context);
    int (*glx_delete_lists)(void *user_context, visionx_xid_t context, uint32_t list, uint32_t range);
    uint32_t (*glx_gen_lists)(void *user_context, visionx_xid_t context, uint32_t range);
} visionx_surface_callbacks_t;

typedef struct visionx_server_config {
    uint32_t display_number;
    uint16_t tcp_port;
    const char *bind_address;
    visionx_auth_mode_t auth_mode;
    const uint8_t *mit_magic_cookie;
    size_t mit_magic_cookie_length;
    uint32_t screen_width;
    uint32_t screen_height;
    uint8_t experimental_glx;
} visionx_server_config_t;

typedef void (*visionx_log_callback_t)(void *user_context, const char *message);

typedef struct visionx_ddx_screen visionx_ddx_screen_t;

const char *visionx_ddx_version(void);
const char *visionx_xorg_server_version(void);
void visionx_server_set_logging_enabled(int enabled);
void visionx_server_set_log_callback(visionx_log_callback_t callback, void *user_context);
void visionx_ddx_log_message(const char *message);
visionx_surface_callbacks_t visionx_ddx_current_surface_callbacks(void);
visionx_ddx_screen_t *visionx_ddx_current_screen(void);
visionx_ddx_screen_t *visionx_ddx_create_screen(uint32_t width, uint32_t height, visionx_surface_callbacks_t callbacks);
void visionx_ddx_destroy_screen(visionx_ddx_screen_t *screen);
void visionx_ddx_map_window(visionx_ddx_screen_t *screen, visionx_xid_t window, visionx_rect_t rect, visionx_window_metadata_t metadata);
void visionx_ddx_unmap_window(visionx_ddx_screen_t *screen, visionx_xid_t window);
void visionx_ddx_configure_window(visionx_ddx_screen_t *screen, visionx_xid_t window, visionx_rect_t rect);
void visionx_ddx_update_window_metadata(visionx_ddx_screen_t *screen, visionx_xid_t window, visionx_window_metadata_t metadata);
void visionx_ddx_mark_damage(visionx_ddx_screen_t *screen, visionx_xid_t window, visionx_rect_t rect);
void visionx_ddx_mark_damage_regions(visionx_ddx_screen_t *screen, visionx_xid_t window, const visionx_rect_t *rects, size_t rect_count, uint8_t full_refresh);
void visionx_ddx_destroy_window(visionx_ddx_screen_t *screen, visionx_xid_t window);
int visionx_ddx_glx_create_context(visionx_ddx_screen_t *screen, visionx_glx_context_config_t config);
void visionx_ddx_glx_destroy_context(visionx_ddx_screen_t *screen, visionx_xid_t context);
int visionx_ddx_glx_create_drawable(visionx_ddx_screen_t *screen, visionx_glx_drawable_config_t config);
void visionx_ddx_glx_destroy_drawable(visionx_ddx_screen_t *screen, visionx_xid_t drawable);
int visionx_ddx_glx_resize_drawable(visionx_ddx_screen_t *screen, visionx_xid_t drawable, uint32_t width, uint32_t height);
int visionx_ddx_glx_make_current(visionx_ddx_screen_t *screen, visionx_xid_t context, visionx_xid_t drawable);
int visionx_ddx_glx_swap_buffers(visionx_ddx_screen_t *screen, visionx_xid_t context, visionx_xid_t drawable, uint64_t swap_serial, uint8_t should_present);
void visionx_ddx_glx_swap_presented(visionx_xid_t drawable, uint64_t swap_serial);
int visionx_ddx_glx_execute_render(visionx_ddx_screen_t *screen, visionx_xid_t context, const uint8_t *commands, size_t command_length, uint8_t byte_swapped, uint8_t capture_draw_calls);
int visionx_ddx_glx_new_list(visionx_ddx_screen_t *screen, visionx_xid_t context, uint32_t list, uint32_t mode);
int visionx_ddx_glx_end_list(visionx_ddx_screen_t *screen, visionx_xid_t context);
int visionx_ddx_glx_delete_lists(visionx_ddx_screen_t *screen, visionx_xid_t context, uint32_t list, uint32_t range);
uint32_t visionx_ddx_glx_gen_lists(visionx_ddx_screen_t *screen, visionx_xid_t context, uint32_t range);
int visionx_ddx_copy_window_pixels(visionx_xid_t window, uint8_t *destination, size_t destination_length, visionx_pixel_buffer_info_t *info);
int visionx_ddx_copy_window_pixel_region(visionx_xid_t window, visionx_rect_t region, uint8_t *destination, size_t destination_length, visionx_pixel_region_info_t *info);
int visionx_ddx_window_root_origin(visionx_xid_t window, int32_t *root_x, int32_t *root_y);
int visionx_ddx_queue_pointer_event(visionx_pointer_event_kind_t kind, uint8_t detail, int32_t root_x, int32_t root_y);
int visionx_ddx_queue_key_event(visionx_key_event_kind_t kind, uint8_t keycode);
int visionx_ddx_focus_window(visionx_xid_t window);
int visionx_ddx_activate_window(visionx_xid_t window, int should_raise);

int visionx_server_start(const visionx_server_config_t *config, visionx_surface_callbacks_t callbacks, char *error_message, size_t error_message_capacity);
void visionx_server_stop(void);
int visionx_server_force_stop(uint32_t timeout_ms);
int visionx_server_wait_until_stopped(uint32_t timeout_ms);
int visionx_server_is_running(void);
int visionx_server_send_pointer(visionx_xid_t window, visionx_pointer_event_kind_t kind, uint8_t detail, int32_t x, int32_t y);
int visionx_server_send_key(visionx_xid_t window, visionx_key_event_kind_t kind, uint8_t keycode, uint32_t modifiers);
int visionx_server_focus_window(visionx_xid_t window);
int visionx_server_activate_window(visionx_xid_t window, int should_raise);
int visionx_server_configure_window(visionx_xid_t window, visionx_rect_t rect);
int visionx_server_close_window(visionx_xid_t window);
int visionx_server_copy_window_pixels(visionx_xid_t window, uint8_t *destination, size_t destination_length, visionx_pixel_buffer_info_t *info);
int visionx_server_copy_window_pixel_region(visionx_xid_t window, visionx_rect_t region, uint8_t *destination, size_t destination_length, visionx_pixel_region_info_t *info);
int visionx_ddx_add_client_fd(int fd);

#ifdef __cplusplus
}
#endif

#endif
