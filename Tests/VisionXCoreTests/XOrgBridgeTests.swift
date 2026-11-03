// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import CXOrgBridge
import Testing

@testable import VisionXCore

@Test
func ddxSurfaceCallbacksPublishWindowLifecycleEvents() {
    let recorder = DDXCallbackRecorder()
    let context = Unmanaged.passUnretained(recorder).toOpaque()
    let callbacks = visionx_surface_callbacks_t(
        user_context: context,
        map_window: { context, window, rect, metadata in
            ddxRecorder(from: context)?.events.append("map:\(window):\(rect.width)x\(rect.height):\(ddxString(metadata.title))")
        },
        unmap_window: { context, window in
            ddxRecorder(from: context)?.events.append("unmap:\(window)")
        },
        configure_window: { context, window, rect in
            ddxRecorder(from: context)?.events.append("configure:\(window):\(rect.x),\(rect.y)")
        },
        window_metadata_changed: { context, window, metadata in
            ddxRecorder(from: context)?.events.append("metadata:\(window):\(ddxString(metadata.wm_class))")
        },
        damage_window: { context, window, rect in
            ddxRecorder(from: context)?.events.append("damage:\(window):\(rect.width)x\(rect.height)")
        },
        damage_window_regions: { context, window, rects, rectCount, fullRefresh in
            guard let rects else {
                ddxRecorder(from: context)?.events.append("damageRegions:\(window):nil:\(fullRefresh)")
                return
            }
            var dimensions: [String] = []
            for index in 0..<rectCount {
                dimensions.append("\(rects[index].width)x\(rects[index].height)")
            }
            ddxRecorder(from: context)?.events.append("damageRegions:\(window):\(dimensions.joined(separator: ",")):\(fullRefresh)")
        },
        destroy_window: { context, window in
            ddxRecorder(from: context)?.events.append("destroy:\(window)")
        },
        server_exited: { context, result in
            ddxRecorder(from: context)?.events.append("exit:\(result)")
        },
        glx_create_context: nil,
        glx_destroy_context: nil,
        glx_create_drawable: nil,
        glx_destroy_drawable: nil,
        glx_resize_drawable: nil,
        glx_make_current: nil,
        glx_swap_buffers: nil,
        glx_execute_render: nil,
        glx_new_list: nil,
        glx_end_list: nil,
        glx_delete_lists: nil,
        glx_gen_lists: nil
    )

    guard let screen = visionx_ddx_create_screen(800, 600, callbacks) else {
        Issue.record("expected DDX screen")
        return
    }
    defer {
        visionx_ddx_destroy_screen(screen)
    }

    let frame = visionx_rect_t(x: 10, y: 20, width: 320, height: 240)
    "xterm".withCString { title in
        "XTerm".withCString { className in
            let metadata = visionx_window_metadata_t(
                title: title,
                wm_instance: nil,
                wm_class: className,
                transient_for: 0,
                has_transient_for: 0,
                override_redirect: 0,
                accepts_delete_window: 1,
                has_min_size: 0,
                has_max_size: 0,
                has_resize_increment: 0,
                has_base_size: 0,
                min_width: 0,
                min_height: 0,
                max_width: 0,
                max_height: 0,
                width_increment: 0,
                height_increment: 0,
                base_width: 0,
                base_height: 0
            )
            visionx_ddx_map_window(screen, 42, frame, metadata)
            visionx_ddx_update_window_metadata(screen, 42, metadata)
        }
    }
    visionx_ddx_configure_window(screen, 42, visionx_rect_t(x: 30, y: 40, width: 320, height: 240))
    visionx_ddx_mark_damage(screen, 42, visionx_rect_t(x: 0, y: 0, width: 64, height: 48))
    let regions = [
        visionx_rect_t(x: 0, y: 0, width: 8, height: 8),
        visionx_rect_t(x: 16, y: 16, width: 4, height: 4),
    ]
    regions.withUnsafeBufferPointer { buffer in
        visionx_ddx_mark_damage_regions(screen, 42, buffer.baseAddress, buffer.count, 0)
    }
    visionx_ddx_unmap_window(screen, 42)
    visionx_ddx_destroy_window(screen, 42)

    #expect(recorder.events == [
        "map:42:320x240:xterm",
        "metadata:42:XTerm",
        "configure:42:30,40",
        "damageRegions:42:64x48:0",
        "damageRegions:42:8x8,4x4:0",
        "unmap:42",
        "destroy:42",
    ])
}

@Test
func ddxGLXCallbacksPublishBridgeEvents() {
    let recorder = DDXCallbackRecorder()
    let context = Unmanaged.passUnretained(recorder).toOpaque()
    let callbacks = visionx_surface_callbacks_t(
        user_context: context,
        map_window: nil,
        unmap_window: nil,
        configure_window: nil,
        window_metadata_changed: nil,
        damage_window: nil,
        damage_window_regions: nil,
        destroy_window: nil,
        server_exited: nil,
        glx_create_context: { context, config in
            ddxRecorder(from: context)?.events.append("glxContext:\(config.context):\(config.visual_id)")
            return 1
        },
        glx_destroy_context: { context, glxContext in
            ddxRecorder(from: context)?.events.append("glxDestroyContext:\(glxContext)")
        },
        glx_create_drawable: { context, config in
            ddxRecorder(from: context)?.events.append("glxDrawable:\(config.drawable):\(config.width)x\(config.height)")
            return 1
        },
        glx_destroy_drawable: { context, drawable in
            ddxRecorder(from: context)?.events.append("glxDestroyDrawable:\(drawable)")
        },
        glx_resize_drawable: { context, drawable, width, height in
            ddxRecorder(from: context)?.events.append("glxResize:\(drawable):\(width)x\(height)")
            return 1
        },
        glx_make_current: { context, glxContext, drawable in
            ddxRecorder(from: context)?.events.append("glxMakeCurrent:\(glxContext):\(drawable)")
            return 1
        },
        glx_swap_buffers: { context, glxContext, drawable, swapSerial, shouldPresent in
            ddxRecorder(from: context)?.events.append("glxSwap:\(glxContext):\(drawable):\(swapSerial):\(shouldPresent)")
            return 1
        },
        glx_execute_render: { context, glxContext, commands, commandLength, byteSwapped, captureDrawCalls in
            guard commands != nil else {
                return 0
            }
            ddxRecorder(from: context)?.events.append("glxRender:\(glxContext):\(commandLength):\(byteSwapped):\(captureDrawCalls)")
            return 1
        },
        glx_new_list: { context, glxContext, list, mode in
            ddxRecorder(from: context)?.events.append("glxNewList:\(glxContext):\(list):\(mode)")
            return 1
        },
        glx_end_list: { context, glxContext in
            ddxRecorder(from: context)?.events.append("glxEndList:\(glxContext)")
            return 1
        },
        glx_delete_lists: { context, glxContext, list, range in
            ddxRecorder(from: context)?.events.append("glxDeleteLists:\(glxContext):\(list):\(range)")
            return 1
        },
        glx_gen_lists: { context, glxContext, range in
            ddxRecorder(from: context)?.events.append("glxGenLists:\(glxContext):\(range)")
            return 700
        }
    )

    guard let screen = visionx_ddx_create_screen(800, 600, callbacks) else {
        Issue.record("expected DDX screen")
        return
    }
    defer {
        visionx_ddx_destroy_screen(screen)
    }

    let contextConfig = visionx_glx_context_config_t(
        context: 100,
        visual_id: 0x21,
        share_context: 0,
        has_share_context: 0,
        direct: 0
    )
    let drawableConfig = visionx_glx_drawable_config_t(
        drawable: 200,
        backing_xid: 200,
        presentation_xid: 200,
        kind: VISIONX_GLX_DRAWABLE_WINDOW,
        visual_id: 0x21,
        width: 640,
        height: 480,
        presentation_x: 0,
        presentation_y: 0
    )

    #expect(visionx_ddx_glx_create_context(screen, contextConfig) == 1)
    #expect(visionx_ddx_glx_create_drawable(screen, drawableConfig) == 1)
    #expect(visionx_ddx_glx_resize_drawable(screen, 200, 800, 600) == 1)
    #expect(visionx_ddx_glx_make_current(screen, 100, 200) == 1)
    #expect(visionx_ddx_glx_swap_buffers(screen, 100, 200, 900, 1) == 1)
    let renderBytes: [UInt8] = [4, 0, 23, 0]
    let renderStatus = renderBytes.withUnsafeBufferPointer { buffer in
        visionx_ddx_glx_execute_render(screen, 100, buffer.baseAddress, buffer.count, 0, 1)
    }
    #expect(renderStatus == 1)
    #expect(visionx_ddx_glx_new_list(screen, 100, 701, 0x1300) == 1)
    #expect(visionx_ddx_glx_end_list(screen, 100) == 1)
    #expect(visionx_ddx_glx_delete_lists(screen, 100, 701, 1) == 1)
    #expect(visionx_ddx_glx_gen_lists(screen, 100, 2) == 700)
    visionx_ddx_glx_destroy_drawable(screen, 200)
    visionx_ddx_glx_destroy_context(screen, 100)

    #expect(recorder.events == [
        "glxContext:100:33",
        "glxDrawable:200:640x480",
        "glxResize:200:800x600",
        "glxMakeCurrent:100:200",
        "glxSwap:100:200:900:1",
        "glxRender:100:4:0:1",
        "glxNewList:100:701:4864",
        "glxEndList:100",
        "glxDeleteLists:100:701:1",
        "glxGenLists:100:2",
        "glxDestroyDrawable:200",
        "glxDestroyContext:100",
    ])
}

@Test
func embeddedXOrgBackendFailsClearlyWhenXOrgObjectsAreNotLinked() {
    var cookie = [UInt8](repeating: 0xab, count: MITMagicCookie.byteCount)
    let cookieLength = cookie.count
    var error = [CChar](repeating: 0, count: 256)
    let callbacks = visionx_surface_callbacks_t()

    let status = cookie.withUnsafeMutableBufferPointer { cookieBuffer in
        var config = visionx_server_config_t(
            display_number: 0,
            tcp_port: 6000,
            bind_address: nil,
            auth_mode: VISIONX_AUTH_MODE_MIT_MAGIC_COOKIE,
            mit_magic_cookie: cookieBuffer.baseAddress,
            mit_magic_cookie_length: cookieLength,
            screen_width: 1280,
            screen_height: 720,
            experimental_glx: 0
        )

        return error.withUnsafeMutableBufferPointer { errorBuffer in
            visionx_server_start(&config, callbacks, errorBuffer.baseAddress, errorBuffer.count)
        }
    }

    #expect(status == 0)
    #expect(visionx_server_is_running() == 0)
    let messageBytes = error.map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }
    #expect(String(decoding: messageBytes, as: UTF8.self).contains("embedded X.Org backend is not linked"))
}

@Test
func xorgBackendPixelCopyReturnsNilWhenServerIsStopped() {
    let backend = XOrgServerBackend()
    #expect(backend.copyPixels(window: 42) == nil)
}

@Test
func xorgBackendFocusReturnsFalseWhenServerIsStopped() {
    let backend = XOrgServerBackend()
    #expect(backend.focus(window: 42) == false)
}

@Test
func xorgBackendActivateReturnsFalseWhenServerIsStopped() {
    let backend = XOrgServerBackend()
    #expect(backend.activate(window: 42) == false)
}

private final class DDXCallbackRecorder: @unchecked Sendable {
    var events: [String] = []
}

private func ddxRecorder(from context: UnsafeMutableRawPointer?) -> DDXCallbackRecorder? {
    guard let context else {
        return nil
    }
    return Unmanaged<DDXCallbackRecorder>.fromOpaque(context).takeUnretainedValue()
}

private func ddxString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else {
        return ""
    }
    return String(cString: pointer)
}
