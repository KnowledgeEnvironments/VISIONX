// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import CXOrgBridge
import CoreGraphics
import Dispatch
import Foundation
import VisionGL

private let visionXGLXFrameTraceEnabled = ProcessInfo.processInfo.environment["VISIONX_GLX_FRAME_TRACE"] == "1"

#if canImport(Darwin)
import Darwin
#endif

public enum XOrgBridge {
    public static var ddxVersion: String {
        String(cString: visionx_ddx_version())
    }

    public static var expectedServerVersion: String {
        String(cString: visionx_xorg_server_version())
    }

    public static func installRuntimeLogCallback() {
        visionx_server_set_logging_enabled(VisionXRuntimeLog.isEnabled ? 1 : 0)
        guard VisionXRuntimeLog.isEnabled else {
            visionx_server_set_log_callback(nil, nil)
            return
        }

        visionx_server_set_log_callback({ _, message in
            guard let message else {
                return
            }
            VisionXRuntimeLog.writeCLog(String(cString: message))
        }, nil)
    }

    public static func reportGLXSwapPresented(drawable: XID, swapSerial: UInt64) {
        guard drawable != 0, swapSerial != 0 else {
            return
        }
        GLXTimelineLog.shared.logAck(drawable: drawable, swapSerial: swapSerial)
        visionx_ddx_glx_swap_presented(drawable, swapSerial)
    }

    public static func setGLXWindowPresenterActive(window: XID, active: Bool) {
        GLXWindowPresentationTracker.shared.setActive(window: window, active: active)
    }
}

private final class GLXTimelineLog: @unchecked Sendable {
    static let shared = GLXTimelineLog()

    private let lock = NSLock()
    private var eventCount: UInt64 = 0
    private var lastEventTime: TimeInterval = 0

    private init() {}

    func log(_ message: @autoclosure () -> String, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        eventCount &+= 1
        let count = eventCount
        let delta = lastEventTime == 0 ? 0 : now - lastEventTime
        lastEventTime = now
        lock.unlock()

        if force || count <= 24 || delta > 0.250 || count.isMultiple(of: 1200) {
            VisionXRuntimeLog.write(
                String(format: "GLX timeline t=%.6f dt=%.6f %@", now, delta, message())
            )
        }
    }

    func logAck(drawable: XID, swapSerial: UInt64) {
        log("ack drawable=\(drawable) swapSerial=\(swapSerial)")
    }
}

private final class GLXWindowPresentationTracker: @unchecked Sendable {
    static let shared = GLXWindowPresentationTracker()

    private let lock = NSLock()
    private var activeWindows: Set<XID> = []

    func setActive(window: XID, active: Bool) {
        guard window != 0 else {
            return
        }
        lock.lock()
        if active {
            activeWindows.insert(window)
        } else {
            activeWindows.remove(window)
        }
        lock.unlock()
    }

    func isActive(window: XID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeWindows.contains(window)
    }

    func consumeFallbackCompletion(window: XID) -> Bool {
        guard window != 0 else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return !activeWindows.contains(window)
    }
}

public struct XOrgWindowMetadata: Equatable, Sendable {
    public var title: String
    public var wmClass: WMClass
    public var normalHints: WMNormalHints
    public var transientFor: XID?
    public var overrideRedirect: Bool
    public var acceptsDeleteWindow: Bool

    public init(
        title: String = "",
        wmClass: WMClass = WMClass(),
        normalHints: WMNormalHints = WMNormalHints(),
        transientFor: XID? = nil,
        overrideRedirect: Bool = false,
        acceptsDeleteWindow: Bool = false
    ) {
        self.title = title
        self.wmClass = wmClass
        self.normalHints = normalHints
        self.transientFor = transientFor
        self.overrideRedirect = overrideRedirect
        self.acceptsDeleteWindow = acceptsDeleteWindow
    }

    public var protocols: Set<WMProtocol> {
        acceptsDeleteWindow ? [.deleteWindow] : []
    }
}

public enum XOrgWindowEvent: Equatable, Sendable {
    case mapped(window: XID, frame: XRectangle, metadata: XOrgWindowMetadata)
    case unmapped(window: XID)
    case configured(window: XID, frame: XRectangle)
    case metadataChanged(window: XID, metadata: XOrgWindowMetadata)
    case damaged(window: XID, rect: XRectangle)
    case damagedRegions(window: XID, rects: [XRectangle])
    case destroyed(window: XID)
}

public enum XOrgGLXDrawableKind: Equatable, Sendable {
    case window
    case pixmap
}

public struct XOrgGLXDrawablePlacement: Equatable, Sendable {
    public var presentationXID: XID
    public var x: Int
    public var y: Int

    public init(presentationXID: XID, x: Int, y: Int) {
        self.presentationXID = presentationXID
        self.x = x
        self.y = y
    }
}

public enum XOrgGLXEvent: Equatable, Sendable {
    case contextCreated(context: XID, visualID: UInt32, shareContext: XID?)
    case contextDestroyed(context: XID)
    case drawableCreated(drawable: XID, backingXID: XID, kind: XOrgGLXDrawableKind, visualID: UInt32, width: Int, height: Int, placement: XOrgGLXDrawablePlacement?)
    case drawableDestroyed(drawable: XID)
    case drawableResized(drawable: XID, width: Int, height: Int)
    case madeCurrent(context: XID, drawable: XID)
    case swapBuffers(drawable: XID)
}

public struct XWindowPixelBuffer: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var bgraData: Data

    public init(width: Int, height: Int, bytesPerRow: Int, bgraData: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bgraData = bgraData
    }
}

public struct XWindowPixelRegion: Equatable, Sendable {
    public var windowWidth: Int
    public var windowHeight: Int
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var bgraData: Data

    public init(
        windowWidth: Int,
        windowHeight: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bgraData: Data
    ) {
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bgraData = bgraData
    }
}

public struct XWindowPixelRegionDescriptor: Equatable, Sendable {
    public var windowWidth: Int
    public var windowHeight: Int
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int

    init?(_ info: visionx_pixel_region_info_t) {
        let windowWidth = Int(info.window_width)
        let windowHeight = Int(info.window_height)
        let x = Int(info.x)
        let y = Int(info.y)
        let width = Int(info.width)
        let height = Int(info.height)
        let bytesPerRow = Int(info.bytes_per_row)
        guard windowWidth > 0,
              windowHeight > 0,
              width > 0,
              height > 0,
              bytesPerRow >= width * 4 else {
            return nil
        }
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    public var requiredByteCount: Int {
        bytesPerRow * height
    }

    public var rectangle: XRectangle {
        XRectangle(x: x, y: y, width: width, height: height)
    }
}

public enum XOrgServerBackendError: Error, Equatable, LocalizedError {
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .startFailed(let message):
            return message
        }
    }
}

public final class XOrgServerBackend: @unchecked Sendable {
    public var onWindowEvent: @Sendable (XOrgWindowEvent) -> Void = { _ in }
    public var onGLXEvent: @Sendable (XOrgGLXEvent) -> Void = { _ in }
    public var onServerExit: @Sendable (Int32) -> Void = { _ in }

    private let callbackBox = XOrgCallbackBox()
    private var isStarted = false
    private var tcpBridge: XOrgTCPBridge?
    private var unixBridge: XOrgUnixSocketBridge?
    private var reverseBridge: XOrgReverseTCPBridge?

    public init() {}

    deinit {
        stop()
    }

    public func start(configuration: VisionXServerConfiguration, screenSize: CGSize = CGSize(width: 1280, height: 720)) throws {
        guard !isStarted else {
            VisionXRuntimeLog.write("XOrgServerBackend.start ignored because backend is already started")
            return
        }

        VisionXRuntimeLog.write("XOrgServerBackend.start entering")
        callbackBox.onWindowEvent = { [weak self] event in
            self?.onWindowEvent(event)
        }
        callbackBox.onGLXEvent = { [weak self] event in
            self?.onGLXEvent(event)
        }
        callbackBox.onServerExit = { [weak self] result in
            self?.isStarted = false
            self?.tcpBridge?.stop()
            self?.tcpBridge = nil
            self?.unixBridge?.stop()
            self?.unixBridge = nil
            self?.reverseBridge?.stop()
            self?.reverseBridge = nil
            self?.onServerExit(result)
        }

        let unixConfiguration = Self.unixBridgeConfigurationFromLaunchOptions()
        let reverseConfiguration = Self.reverseBridgeConfigurationFromLaunchOptions()
        let tcpBridgeRequested = Self.tcpBridgeRequestedFromLaunchOptions()
        if unixConfiguration != nil || reverseConfiguration != nil || tcpBridgeRequested {
            setenv("VISIONX_XORG_EXTERNAL_LISTENER", "1", 1)
        } else {
            unsetenv("VISIONX_XORG_EXTERNAL_LISTENER")
        }

        let authMode: visionx_auth_mode_t = configuration.requireMITMagicCookie
            ? VISIONX_AUTH_MODE_MIT_MAGIC_COOKIE
            : VISIONX_AUTH_MODE_DISABLED
        let cookieBytes = configuration.requireMITMagicCookie ? configuration.cookie.bytes : []
        var errorBytes = [CChar](repeating: 0, count: 512)
        let status: Int32 = cookieBytes.withUnsafeBufferPointer { cookieBuffer in
            let startWithBindAddress: (UnsafePointer<CChar>?) -> Int32 = { bindAddress in
                var cConfiguration = visionx_server_config_t(
                    display_number: UInt32(max(0, configuration.displayNumber)),
                    tcp_port: configuration.listenPort,
                    bind_address: bindAddress,
                    auth_mode: authMode,
                    mit_magic_cookie: cookieBuffer.baseAddress,
                    mit_magic_cookie_length: cookieBytes.count,
                    screen_width: UInt32(max(1, Int(screenSize.width.rounded()))),
                    screen_height: UInt32(max(1, Int(screenSize.height.rounded()))),
                    experimental_glx: configuration.experimentalGLXEnabled ? 1 : 0
                )
                let callbacks = Self.makeCallbacks(context: Unmanaged.passUnretained(self.callbackBox).toOpaque())
                return errorBytes.withUnsafeMutableBufferPointer { errorBuffer in
                    visionx_server_start(&cConfiguration, callbacks, errorBuffer.baseAddress, errorBuffer.count)
                }
            }

            if let bindAddress = configuration.bindAddress, !bindAddress.isEmpty {
                return bindAddress.withCString { startWithBindAddress($0) }
            }

            return startWithBindAddress(nil)
        }

        guard status != 0 else {
            let message = errorBytes.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return "failed to start embedded X.Org backend"
                }
                return String(cString: baseAddress)
            }
            VisionXRuntimeLog.write("XOrgServerBackend.start failed status=0 message=\(message)")
            throw XOrgServerBackendError.startFailed(message)
        }

        if let unixConfiguration {
            let unixBridge = XOrgUnixSocketBridge()
            do {
                try unixBridge.start(path: unixConfiguration.path)
            } catch {
                VisionXRuntimeLog.write("XOrgServerBackend.start Unix socket bridge failed: \(error.localizedDescription)")
                visionx_server_stop()
                throw XOrgServerBackendError.startFailed(error.localizedDescription)
            }
            self.unixBridge = unixBridge
            VisionXRuntimeLog.write(
                "XOrgServerBackend.start Unix socket bridge enabled path=\(unixConfiguration.path) publicPort=\(configuration.listenPort)"
            )
        } else if let reverseConfiguration {
            let reverseBridge = XOrgReverseTCPBridge()
            do {
                try reverseBridge.start(
                    host: reverseConfiguration.host,
                    port: reverseConfiguration.port,
                    channelCount: reverseConfiguration.channelCount
                )
            } catch {
                VisionXRuntimeLog.write("XOrgServerBackend.start reverse TCP bridge failed: \(error.localizedDescription)")
                visionx_server_stop()
                throw XOrgServerBackendError.startFailed(error.localizedDescription)
            }
            self.reverseBridge = reverseBridge
            VisionXRuntimeLog.write(
                "XOrgServerBackend.start reverse TCP bridge enabled host=\(reverseConfiguration.host) port=\(reverseConfiguration.port) channels=\(reverseConfiguration.channelCount) publicPort=\(configuration.listenPort)"
            )
        } else if tcpBridgeRequested {
            let tcpBridge = XOrgTCPBridge()
            do {
                try tcpBridge.start(port: configuration.listenPort, bindAddress: configuration.bindAddress)
            } catch {
                VisionXRuntimeLog.write("XOrgServerBackend.start TCP bridge failed: \(error.localizedDescription)")
                visionx_server_stop()
                throw XOrgServerBackendError.startFailed(error.localizedDescription)
            }
            self.tcpBridge = tcpBridge
        } else {
            VisionXRuntimeLog.write(
                "XOrgServerBackend.start native X.Org TCP listener publicPort=\(configuration.listenPort) bind=\(configuration.bindAddress ?? "all")"
            )
        }

        isStarted = true
        VisionXRuntimeLog.write("XOrgServerBackend.start completed")
    }

    @discardableResult
    public func stop(timeoutMilliseconds: UInt32 = 8_000) -> Bool {
        guard isStarted || visionx_server_is_running() != 0 else {
            VisionXRuntimeLog.write("XOrgServerBackend.stop ignored because backend is not running")
            return true
        }

        VisionXRuntimeLog.write("XOrgServerBackend.stop entering")
        tcpBridge?.stop()
        tcpBridge = nil
        unixBridge?.stop()
        unixBridge = nil
        reverseBridge?.stop()
        reverseBridge = nil
        visionx_server_stop()
        let didStop = visionx_server_wait_until_stopped(timeoutMilliseconds) != 0
        if didStop {
            isStarted = false
            VisionXRuntimeLog.write("XOrgServerBackend.stop completed")
        } else {
            VisionXRuntimeLog.write("XOrgServerBackend.stop timed out")
        }
        return didStop
    }

    private struct ReverseBridgeConfiguration {
        var host: String
        var port: UInt16
        var channelCount: Int
    }

    private struct UnixBridgeConfiguration {
        var path: String
    }

    private static func unixBridgeConfigurationFromLaunchOptions() -> UnixBridgeConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        guard let path = stringArgument(named: "--visionx-unix-bridge-path", in: arguments)
            ?? environment["VISIONX_UNIX_BRIDGE_PATH"],
            !path.isEmpty
        else {
            return nil
        }
        return UnixBridgeConfiguration(path: path)
    }

    private static func reverseBridgeConfigurationFromLaunchOptions() -> ReverseBridgeConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment

        let portString = stringArgument(named: "--visionx-reverse-bridge-port", in: arguments)
            ?? environment["VISIONX_REVERSE_BRIDGE_PORT"]
        guard let portString, let port = UInt16(portString), port > 0 else {
            return nil
        }

        let host = stringArgument(named: "--visionx-reverse-bridge-host", in: arguments)
            ?? environment["VISIONX_REVERSE_BRIDGE_HOST"]
            ?? "127.0.0.1"
        let channelCountString = stringArgument(named: "--visionx-reverse-bridge-channels", in: arguments)
            ?? environment["VISIONX_REVERSE_BRIDGE_CHANNELS"]
        let channelCount = channelCountString.flatMap(Int.init).map { max(1, min($0, 32)) } ?? 8
        return ReverseBridgeConfiguration(host: host, port: port, channelCount: channelCount)
    }

    private static func tcpBridgeRequestedFromLaunchOptions() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        return arguments.contains("--visionx-tcp-bridge") || environment["VISIONX_TCP_BRIDGE"] == "1"
    }

    private static func stringArgument(named name: String, in arguments: [String]) -> String? {
        let prefix = "\(name)="
        for argument in arguments where argument.hasPrefix(prefix) {
            return String(argument.dropFirst(prefix.count))
        }

        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    @discardableResult
    public func forceStop(timeoutMilliseconds: UInt32 = 1_000) -> Bool {
        guard isStarted || visionx_server_is_running() != 0 else {
            VisionXRuntimeLog.write("XOrgServerBackend.forceStop ignored because backend is not running")
            return true
        }

        VisionXRuntimeLog.write("XOrgServerBackend.forceStop entering timeoutMilliseconds=\(timeoutMilliseconds)")
        tcpBridge?.stop()
        tcpBridge = nil
        unixBridge?.stop()
        unixBridge = nil
        reverseBridge?.stop()
        reverseBridge = nil
        let didStop = visionx_server_force_stop(timeoutMilliseconds) != 0
        if didStop {
            isStarted = false
            VisionXRuntimeLog.write("XOrgServerBackend.forceStop completed")
        } else {
            VisionXRuntimeLog.write("XOrgServerBackend.forceStop timed out; app relaunch required before restart")
        }
        return didStop
    }

    @discardableResult
    public func send(pointer event: XPointerEvent) -> Bool {
        let kind: visionx_pointer_event_kind_t
        let detail: UInt8

        switch event.kind {
        case .motion:
            kind = VISIONX_POINTER_EVENT_MOTION
            detail = 0
        case .buttonPress(let button):
            kind = VISIONX_POINTER_EVENT_BUTTON_PRESS
            detail = button.rawValue
        case .buttonRelease(let button):
            kind = VISIONX_POINTER_EVENT_BUTTON_RELEASE
            detail = button.rawValue
        case .enter:
            kind = VISIONX_POINTER_EVENT_ENTER
            detail = 0
        case .leave:
            kind = VISIONX_POINTER_EVENT_LEAVE
            detail = 0
        }

        return visionx_server_send_pointer(event.window, kind, detail, Int32(event.x), Int32(event.y)) != 0
    }

    @discardableResult
    public func send(key event: XKeyboardEvent) -> Bool {
        let kind: visionx_key_event_kind_t = event.kind == .keyPress
            ? VISIONX_KEY_EVENT_PRESS
            : VISIONX_KEY_EVENT_RELEASE
        return visionx_server_send_key(event.window, kind, event.keycode, event.modifiers) != 0
    }

    @discardableResult
    public func focus(window id: XID) -> Bool {
        visionx_server_focus_window(id) != 0
    }

    @discardableResult
    public func activate(window id: XID, raise: Bool = true) -> Bool {
        visionx_server_activate_window(id, raise ? 1 : 0) != 0
    }

    @discardableResult
    public func configure(window id: XID, frame: XRectangle) -> Bool {
        visionx_server_configure_window(id, frame.cRect) != 0
    }

    @discardableResult
    public func close(window id: XID) -> Bool {
        visionx_server_close_window(id) != 0
    }

    public func copyPixels(window id: XID) -> XWindowPixelBuffer? {
        var info = visionx_pixel_buffer_info_t()
        guard visionx_server_copy_window_pixels(id, nil, 0, &info) != 0 else {
            return nil
        }

        let width = Int(info.width)
        let height = Int(info.height)
        let bytesPerRow = Int(info.bytes_per_row)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            return nil
        }

        var data = Data(count: bytesPerRow * height)
        let copied = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            var copiedInfo = info
            return visionx_server_copy_window_pixels(id, baseAddress, buffer.count, &copiedInfo) != 0 &&
                copiedInfo.width == info.width &&
                copiedInfo.height == info.height &&
                copiedInfo.bytes_per_row == info.bytes_per_row
        }

        guard copied else {
            return nil
        }

        return XWindowPixelBuffer(width: width, height: height, bytesPerRow: bytesPerRow, bgraData: data)
    }

    public func copyPixelRegion(window id: XID, rect: XRectangle) -> XWindowPixelRegion? {
        var info = visionx_pixel_region_info_t()
        guard visionx_server_copy_window_pixel_region(id, rect.cRect, nil, 0, &info) != 0 else {
            return nil
        }

        let windowWidth = Int(info.window_width)
        let windowHeight = Int(info.window_height)
        let x = Int(info.x)
        let y = Int(info.y)
        let width = Int(info.width)
        let height = Int(info.height)
        let bytesPerRow = Int(info.bytes_per_row)
        guard windowWidth > 0, windowHeight > 0, width > 0, height > 0, bytesPerRow >= width * 4 else {
            return nil
        }

        var data = Data(count: bytesPerRow * height)
        let copied = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            var copiedInfo = info
            return visionx_server_copy_window_pixel_region(id, rect.cRect, baseAddress, buffer.count, &copiedInfo) != 0 &&
                copiedInfo.window_width == info.window_width &&
                copiedInfo.window_height == info.window_height &&
                copiedInfo.x == info.x &&
                copiedInfo.y == info.y &&
                copiedInfo.width == info.width &&
                copiedInfo.height == info.height &&
                copiedInfo.bytes_per_row == info.bytes_per_row
        }

        guard copied else {
            return nil
        }

        return XWindowPixelRegion(
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            x: x,
            y: y,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bgraData: data
        )
    }

    public func copyPixelRegion(window id: XID, rect: XRectangle, into data: inout Data) -> XWindowPixelRegionDescriptor? {
        var info = visionx_pixel_region_info_t()
        guard visionx_server_copy_window_pixel_region(id, rect.cRect, nil, 0, &info) != 0,
              let descriptor = XWindowPixelRegionDescriptor(info) else {
            return nil
        }

        let requiredLength = descriptor.requiredByteCount
        guard requiredLength > 0 else {
            return nil
        }
        if data.count < requiredLength {
            data.count = requiredLength
        }

        let copied = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            var copiedInfo = info
            return visionx_server_copy_window_pixel_region(id, rect.cRect, baseAddress, buffer.count, &copiedInfo) != 0 &&
                copiedInfo.window_width == info.window_width &&
                copiedInfo.window_height == info.window_height &&
                copiedInfo.x == info.x &&
                copiedInfo.y == info.y &&
                copiedInfo.width == info.width &&
                copiedInfo.height == info.height &&
                copiedInfo.bytes_per_row == info.bytes_per_row
        }

        return copied ? descriptor : nil
    }

#if canImport(Metal)
    public func glxFrame(window id: XID) -> VisionGLMetalFrame? {
        callbackBox.glxFrame(window: id)
    }
#endif

    private static func makeCallbacks(context: UnsafeMutableRawPointer) -> visionx_surface_callbacks_t {
        visionx_surface_callbacks_t(
            user_context: context,
            map_window: { context, window, rect, metadata in
                xorgCallbackBox(from: context)?.emit(.mapped(window: window, frame: XRectangle(rect), metadata: XOrgWindowMetadata(metadata)))
            },
            unmap_window: { context, window in
                xorgCallbackBox(from: context)?.emit(.unmapped(window: window))
            },
            configure_window: { context, window, rect in
                xorgCallbackBox(from: context)?.emit(.configured(window: window, frame: XRectangle(rect)))
            },
            window_metadata_changed: { context, window, metadata in
                xorgCallbackBox(from: context)?.emit(.metadataChanged(window: window, metadata: XOrgWindowMetadata(metadata)))
            },
            damage_window: { context, window, rect in
                xorgCallbackBox(from: context)?.emit(.damaged(window: window, rect: XRectangle(rect)))
            },
            damage_window_regions: { context, window, rects, rectCount, fullRefresh in
                guard let callbackBox = xorgCallbackBox(from: context) else {
                    return
                }
                guard fullRefresh == 0 else {
                    callbackBox.emit(.damagedRegions(window: window, rects: []))
                    return
                }
                guard let rects, rectCount > 0 else {
                    callbackBox.emit(.damagedRegions(window: window, rects: []))
                    return
                }
                var converted: [XRectangle] = []
                converted.reserveCapacity(rectCount)
                for index in 0..<rectCount {
                    converted.append(XRectangle(rects[index]))
                }
                callbackBox.emit(.damagedRegions(window: window, rects: converted))
            },
            destroy_window: { context, window in
                xorgCallbackBox(from: context)?.emit(.destroyed(window: window))
            },
            server_exited: { context, result in
                xorgCallbackBox(from: context)?.emitServerExit(result)
            },
            glx_create_context: { context, config in
                xorgCallbackBox(from: context)?.createGLXContext(config) ?? 0
            },
            glx_destroy_context: { context, glxContext in
                xorgCallbackBox(from: context)?.destroyGLXContext(glxContext)
            },
            glx_create_drawable: { context, config in
                xorgCallbackBox(from: context)?.createGLXDrawable(config) ?? 0
            },
            glx_destroy_drawable: { context, drawable in
                xorgCallbackBox(from: context)?.destroyGLXDrawable(drawable)
            },
            glx_resize_drawable: { context, drawable, width, height in
                xorgCallbackBox(from: context)?.resizeGLXDrawable(drawable: drawable, width: width, height: height) ?? 0
            },
            glx_make_current: { context, glxContext, drawable in
                xorgCallbackBox(from: context)?.makeGLXCurrent(context: glxContext, drawable: drawable) ?? 0
            },
            glx_swap_buffers: { context, glxContext, drawable, swapSerial, shouldPresent in
                xorgCallbackBox(from: context)?.swapGLXBuffers(
                    context: glxContext,
                    drawable: drawable,
                    swapSerial: swapSerial,
                    shouldPresent: shouldPresent != 0
                ) ?? 0
            },
            glx_execute_render: { context, glxContext, commands, commandLength, byteSwapped, captureDrawCalls in
                xorgCallbackBox(from: context)?.executeGLXRender(
                    context: glxContext,
                    commands: commands,
                    commandLength: commandLength,
                    byteSwapped: byteSwapped,
                    captureDrawCalls: captureDrawCalls != 0
                ) ?? 0
            },
            glx_new_list: { context, glxContext, list, mode in
                xorgCallbackBox(from: context)?.beginGLXDisplayList(context: glxContext, list: list, mode: mode) ?? 0
            },
            glx_end_list: { context, glxContext in
                xorgCallbackBox(from: context)?.endGLXDisplayList(context: glxContext) ?? 0
            },
            glx_delete_lists: { context, glxContext, list, range in
                xorgCallbackBox(from: context)?.deleteGLXDisplayLists(context: glxContext, list: list, range: range) ?? 0
            },
            glx_gen_lists: { context, glxContext, range in
                xorgCallbackBox(from: context)?.generateGLXDisplayLists(context: glxContext, range: range) ?? 0
            }
        )
    }
}

private final class XOrgCallbackBox: @unchecked Sendable {
    var onWindowEvent: @Sendable (XOrgWindowEvent) -> Void = { _ in }
    var onGLXEvent: @Sendable (XOrgGLXEvent) -> Void = { _ in }
    var onServerExit: @Sendable (Int32) -> Void = { _ in }

    private let glxRegistry = VisionGLXRegistry()
#if canImport(Metal)
    private struct PendingGLXMetalFrame {
        var frameCommands: VisionGLFrameCommands
        var drawable: GLXDrawableRecord
        var context: GLXContextID
        var swapSerial: UInt64
    }

    private lazy var glxMetalRenderer: VisionGLMetalRenderer? = VisionGLMetalRenderer()
    private var glxFramesByWindow: [XID: VisionGLMetalFrame] = [:]
    private var pendingGLXFramesByWindow: [XID: PendingGLXMetalFrame] = [:]
    private var renderingGLXWindows: Set<XID> = []
    private var scheduledGLXRenderWindows: Set<XID> = []
    private var lastGLXDamageEmitUptimeByWindow: [XID: TimeInterval] = [:]
    private var lastGLXPublishUptimeByWindow: [XID: TimeInterval] = [:]
    private var glxDrawableByContext: [XID: XID] = [:]
    private let glxRenderQueue = DispatchQueue(label: "org.uhf.x11.glx-metal-render", qos: .userInteractive)
    private let glxFrameLock = NSLock()
    private let glxDamageEmitInterval: TimeInterval = 1.0 / 120.0
    private let glxOffscreenFallbackDelay: DispatchTimeInterval = .milliseconds(20)
    private var glxFrameLogCount: UInt64 = 0
    private var glxSwapEventLogCount: UInt64 = 0
#endif
    private var glxRenderExecutionLogCount: UInt64 = 0
    private var glxCoalescedFrameLogCount: UInt64 = 0

    func emit(_ event: XOrgWindowEvent) {
        if !event.isDamage {
            VisionXRuntimeLog.write("X.Org window event \(event.logSummary)")
        }
        onWindowEvent(event)
    }

    func createGLXContext(_ config: visionx_glx_context_config_t) -> Int32 {
        guard config.direct == 0 else {
            VisionXRuntimeLog.write("X.Org GLX context rejected direct context=\(config.context)")
            return 0
        }

        let shareContext = config.has_share_context == 0 ? nil : GLXContextID(config.share_context)
        do {
            try glxRegistry.createContext(id: GLXContextID(config.context), visualID: GLXVisualID(config.visual_id), shareGroup: shareContext)
            emitGLX(.contextCreated(context: config.context, visualID: config.visual_id, shareContext: shareContext))
            return 1
        } catch {
            VisionXRuntimeLog.write("X.Org GLX context create failed context=\(config.context) error=\(error)")
            return 0
        }
    }

    func destroyGLXContext(_ context: XID) {
#if canImport(Metal)
        glxFrameLock.lock()
        glxDrawableByContext.removeValue(forKey: context)
        glxFrameLock.unlock()
#endif
        glxRegistry.destroyContext(id: GLXContextID(context))
        emitGLX(.contextDestroyed(context: context))
    }

    func createGLXDrawable(_ config: visionx_glx_drawable_config_t) -> Int32 {
        let kind: XOrgGLXDrawableKind
        do {
            switch config.kind {
            case VISIONX_GLX_DRAWABLE_WINDOW:
                kind = .window
                if glxRegistry.drawables[GLXDrawableID(config.drawable)] == nil {
                    try glxRegistry.createWindowDrawable(
                        id: GLXDrawableID(config.drawable),
                        windowID: X11ResourceID(config.backing_xid),
                        visualID: GLXVisualID(config.visual_id),
                        width: Int(config.width),
                        height: Int(config.height)
                    )
                }
            case VISIONX_GLX_DRAWABLE_PIXMAP:
                kind = .pixmap
                if glxRegistry.drawables[GLXDrawableID(config.drawable)] == nil {
                    try glxRegistry.createPixmapDrawable(
                        id: GLXDrawableID(config.drawable),
                        pixmapID: X11ResourceID(config.backing_xid),
                        visualID: GLXVisualID(config.visual_id),
                        width: Int(config.width),
                        height: Int(config.height)
                    )
                }
            default:
                VisionXRuntimeLog.write("X.Org GLX drawable create rejected unknown kind=\(config.kind.rawValue)")
                return 0
            }
            let placement = kind == .window ? XOrgGLXDrawablePlacement(
                presentationXID: config.presentation_xid == 0 ? config.backing_xid : config.presentation_xid,
                x: Int(config.presentation_x),
                y: Int(config.presentation_y)
            ) : nil
            emitGLX(.drawableCreated(
                drawable: config.drawable,
                backingXID: config.backing_xid,
                kind: kind,
                visualID: config.visual_id,
                width: Int(config.width),
                height: Int(config.height),
                placement: placement
            ))
            return 1
        } catch {
            VisionXRuntimeLog.write("X.Org GLX drawable create failed drawable=\(config.drawable) error=\(error)")
            return 0
        }
    }

    func destroyGLXDrawable(_ drawable: XID) {
        if let record = glxRegistry.drawables[GLXDrawableID(drawable)] {
#if canImport(Metal)
            glxMetalRenderer?.discardDrawable(GLXDrawableID(drawable))
            if case .window(let windowID) = record.kind {
                glxFrameLock.lock()
                glxFramesByWindow.removeValue(forKey: XID(windowID))
                pendingGLXFramesByWindow.removeValue(forKey: XID(windowID))
                renderingGLXWindows.remove(XID(windowID))
                scheduledGLXRenderWindows.remove(XID(windowID))
                lastGLXDamageEmitUptimeByWindow.removeValue(forKey: XID(windowID))
                lastGLXPublishUptimeByWindow.removeValue(forKey: XID(windowID))
                glxFrameLock.unlock()
            }
            glxFrameLock.lock()
            glxDrawableByContext = glxDrawableByContext.filter { $0.value != drawable }
            glxFrameLock.unlock()
#endif
        }
        glxRegistry.destroyDrawable(id: GLXDrawableID(drawable))
        emitGLX(.drawableDestroyed(drawable: drawable))
    }

    func resizeGLXDrawable(drawable: XID, width: UInt32, height: UInt32) -> Int32 {
        do {
            try glxRegistry.resizeDrawable(id: GLXDrawableID(drawable), width: Int(width), height: Int(height))
#if canImport(Metal)
            glxMetalRenderer?.discardDrawable(GLXDrawableID(drawable))
#endif
            emitGLX(.drawableResized(drawable: drawable, width: Int(width), height: Int(height)))
            return 1
        } catch {
            VisionXRuntimeLog.write("X.Org GLX drawable resize failed drawable=\(drawable) error=\(error)")
            return 0
        }
    }

    func makeGLXCurrent(context: XID, drawable: XID) -> Int32 {
        do {
            try glxRegistry.makeCurrent(context: GLXContextID(context), drawable: GLXDrawableID(drawable))
#if canImport(Metal)
            glxFrameLock.lock()
            glxDrawableByContext[context] = drawable
            glxFrameLock.unlock()
#endif
            emitGLX(.madeCurrent(context: context, drawable: drawable))
            return 1
        } catch {
            VisionXRuntimeLog.write("X.Org GLX make current failed context=\(context) drawable=\(drawable) error=\(error)")
            return 0
        }
    }

    func swapGLXBuffers(context: XID, drawable: XID, swapSerial: UInt64, shouldPresent: Bool) -> Int32 {
        do {
            try glxRegistry.swapBuffers(context: GLXContextID(context), drawable: GLXDrawableID(drawable))
            guard shouldPresent else {
                noteCoalescedGLXFrame(drawable: drawable, swapSerial: swapSerial)
                return 1
            }
#if canImport(Metal)
            try enqueueGLXDrawableForMetalPresentation(drawable: drawable, context: context, swapSerial: swapSerial)
#else
            emitGLX(.swapBuffers(drawable: drawable))
            XOrgBridge.reportGLXSwapPresented(drawable: drawable, swapSerial: swapSerial)
#endif
            return 1
        } catch {
            VisionXRuntimeLog.write("X.Org GLX swap buffers failed drawable=\(drawable) error=\(error)")
            return 0
        }
    }

    private func noteCoalescedGLXFrame(drawable: XID, swapSerial: UInt64) {
        glxCoalescedFrameLogCount &+= 1
        let coalescedFrameLogCount = glxCoalescedFrameLogCount
        if coalescedFrameLogCount <= 4 || coalescedFrameLogCount.isMultiple(of: 2400) {
            VisionXRuntimeLog.write(
                "X.Org GLX coalesced frame drawable=\(drawable) swapSerial=\(swapSerial) count=\(coalescedFrameLogCount)"
            )
        }
    }

#if canImport(Metal)
    func glxFrame(window id: XID) -> VisionGLMetalFrame? {
        schedulePendingGLXRender(windowID: id)
        glxFrameLock.lock()
        defer { glxFrameLock.unlock() }
        return glxFramesByWindow[id]
    }

    private func enqueueGLXDrawableForMetalPresentation(drawable: XID, context: XID, swapSerial: UInt64) throws {
        guard let drawableRecord = glxRegistry.drawables[GLXDrawableID(drawable)] else {
            throw GLXRegistryError.unknownDrawable(GLXDrawableID(drawable))
        }
        guard let contextRecord = glxRegistry.contexts[GLXContextID(context)] else {
            throw GLXRegistryError.unknownContext(GLXContextID(context))
        }

        let frameCommands = contextRecord.context.drainFrameCommands()
        guard let renderer = glxMetalRenderer else {
            VisionXRuntimeLog.write("X.Org GLX metal frame skipped drawable=\(drawable) error=metalUnavailable")
            XOrgBridge.reportGLXSwapPresented(drawable: drawable, swapSerial: swapSerial)
            return
        }
        _ = renderer

        guard case .window(let backingWindowID) = drawableRecord.kind else {
            XOrgBridge.reportGLXSwapPresented(drawable: drawable, swapSerial: swapSerial)
            return
        }

        let windowID = XID(backingWindowID)
        let pendingFrame = PendingGLXMetalFrame(
            frameCommands: frameCommands,
            drawable: drawableRecord,
            context: GLXContextID(context),
            swapSerial: swapSerial
        )
        glxFrameLock.lock()
        let replacedFrame = pendingGLXFramesByWindow[windowID]
        let hadPendingFrame = replacedFrame != nil
        let isRendering = renderingGLXWindows.contains(windowID)
        pendingGLXFramesByWindow[windowID] = pendingFrame
        glxFrameLock.unlock()
        if let replacedFrame {
            XOrgBridge.reportGLXSwapPresented(drawable: replacedFrame.drawable.id, swapSerial: replacedFrame.swapSerial)
        }
        GLXTimelineLog.shared.log(
            "snapshot window=\(windowID) drawable=\(drawable) swapSerial=\(swapSerial) draws=\(frameCommands.drawCalls.count) clears=\(frameCommands.clearRequests.count) replaced=\(hadPendingFrame) rendering=\(isRendering)"
        )
        if !hadPendingFrame, !GLXWindowPresentationTracker.shared.isActive(window: windowID) {
            scheduleGLXPendingFrameFallbackCompletion(windowID: windowID, drawable: drawable, swapSerial: swapSerial)
        }
        schedulePendingGLXRender(windowID: windowID)
    }

    private func schedulePendingGLXRender(windowID: XID) {
        glxFrameLock.lock()
        guard !renderingGLXWindows.contains(windowID),
              !scheduledGLXRenderWindows.contains(windowID),
              pendingGLXFramesByWindow[windowID] != nil else {
            glxFrameLock.unlock()
            return
        }
        scheduledGLXRenderWindows.insert(windowID)
        glxFrameLock.unlock()

        glxRenderQueue.async { [weak self] in
            self?.renderPendingGLXFrame(windowID: windowID)
        }
    }

    private func renderPendingGLXFrame(windowID: XID) {
        glxFrameLock.lock()
        scheduledGLXRenderWindows.remove(windowID)
        guard !renderingGLXWindows.contains(windowID),
              let pendingFrame = pendingGLXFramesByWindow.removeValue(forKey: windowID) else {
            glxFrameLock.unlock()
            return
        }
        renderingGLXWindows.insert(windowID)
        let stillPendingAfterPop = pendingGLXFramesByWindow[windowID] != nil
        glxFrameLock.unlock()

        GLXTimelineLog.shared.log(
            "render-schedule window=\(windowID) drawable=\(pendingFrame.drawable.id) swapSerial=\(pendingFrame.swapSerial) draws=\(pendingFrame.frameCommands.drawCalls.count) pendingAfterPop=\(stillPendingAfterPop)"
        )

        guard let renderer = glxMetalRenderer else {
            VisionXRuntimeLog.write("X.Org GLX metal pending frame skipped window=\(windowID) error=metalUnavailable")
            finishPendingGLXRender(windowID: windowID)
            XOrgBridge.reportGLXSwapPresented(drawable: pendingFrame.drawable.id, swapSerial: pendingFrame.swapSerial)
            return
        }

        do {
            GLXTimelineLog.shared.log(
                "render-start window=\(windowID) drawable=\(pendingFrame.drawable.id) swapSerial=\(pendingFrame.swapSerial)"
            )
            _ = try renderer.render(
                frame: pendingFrame.frameCommands,
                drawable: pendingFrame.drawable,
                context: pendingFrame.context,
                swapSerial: pendingFrame.swapSerial,
                waitUntilCompleted: false,
                completion: { [weak self] frame in
                    guard let self else {
                        XOrgBridge.reportGLXSwapPresented(drawable: frame.drawable, swapSerial: frame.swapSerial)
                        return
                    }
                    GLXTimelineLog.shared.log(
                        "render-complete window=\(windowID) drawable=\(frame.drawable) frameSerial=\(frame.serial) swapSerial=\(frame.swapSerial)"
                    )
                    self.publishGLXMetalFrame(frame, windowID: windowID, drawable: XID(pendingFrame.drawable.id))
                    self.finishPendingGLXRender(windowID: windowID)
                }
            )
        } catch {
            VisionXRuntimeLog.write("X.Org GLX metal pending frame failed window=\(windowID) drawable=\(pendingFrame.drawable.id) error=\(error)")
            finishPendingGLXRender(windowID: windowID)
            XOrgBridge.reportGLXSwapPresented(drawable: pendingFrame.drawable.id, swapSerial: pendingFrame.swapSerial)
        }
    }

    private func finishPendingGLXRender(windowID: XID) {
        glxFrameLock.lock()
        renderingGLXWindows.remove(windowID)
        let hasPendingFrame = pendingGLXFramesByWindow[windowID] != nil
        glxFrameLock.unlock()

        if hasPendingFrame {
            schedulePendingGLXRender(windowID: windowID)
        }
    }

    private func publishGLXMetalFrame(_ frame: VisionGLMetalFrame, windowID: XID, drawable: XID) {
        glxFrameLock.lock()
        let previousFrame = glxFramesByWindow[windowID]
        if let currentFrame = previousFrame,
           frame.serial <= currentFrame.serial {
            glxFrameLock.unlock()
            GLXTimelineLog.shared.log(
                "publish-drop window=\(windowID) drawable=\(drawable) frameSerial=\(frame.serial) currentSerial=\(currentFrame.serial) swapSerial=\(frame.swapSerial)",
                force: true
            )
            XOrgBridge.reportGLXSwapPresented(drawable: drawable, swapSerial: frame.swapSerial)
            return
        }
        glxFramesByWindow[windowID] = frame
        let now = ProcessInfo.processInfo.systemUptime
        let publishDelta = lastGLXPublishUptimeByWindow[windowID].map { now - $0 } ?? 0
        lastGLXPublishUptimeByWindow[windowID] = now
        let isPresenterActive = GLXWindowPresentationTracker.shared.isActive(window: windowID)
        let lastEmit = lastGLXDamageEmitUptimeByWindow[windowID] ?? 0
        let shouldEmitDamage = previousFrame == nil || now - lastEmit >= glxDamageEmitInterval
        if shouldEmitDamage {
            lastGLXDamageEmitUptimeByWindow[windowID] = now
        }
        glxFrameLock.unlock()
        GLXTimelineLog.shared.log(
            "publish window=\(windowID) drawable=\(drawable) frameSerial=\(frame.serial) swapSerial=\(frame.swapSerial) transform=\(frame.transformSignature)"
        )
        if visionXGLXFrameTraceEnabled {
            VisionXRuntimeLog.write(
                String(format: "GLX frame trace publish window=%u frameSerial=%llu swapSerial=%llu dtMS=%.3f emitDamage=%u transform=%.6f",
                       windowID,
                       frame.serial,
                       frame.swapSerial,
                       publishDelta * 1000,
                       shouldEmitDamage ? 1 : 0,
                       Double(frame.transformSignature))
            )
        }

        glxFrameLogCount &+= 1
        if glxFrameLogCount <= 12 || glxFrameLogCount.isMultiple(of: 600) {
            VisionXRuntimeLog.write(
                "X.Org GLX metal frame window=\(windowID) serial=\(frame.serial) draws=\(frame.drawCallCount) clears=\(frame.clearCount) transform=\(frame.transformSignature)"
            )
        }
        if shouldEmitDamage {
            emitGLX(.swapBuffers(drawable: drawable))
        }
        if !isPresenterActive {
            scheduleGLXOffscreenFallbackCompletion(frame, windowID: windowID)
        }
    }

    private func scheduleGLXPendingFrameFallbackCompletion(windowID: XID, drawable: XID, swapSerial: UInt64) {
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + glxOffscreenFallbackDelay) { [weak self] in
            guard let self else {
                return
            }

            guard !GLXWindowPresentationTracker.shared.isActive(window: windowID) else {
                return
            }

            self.glxFrameLock.lock()
            let pendingFrame = self.pendingGLXFramesByWindow[windowID]
            self.glxFrameLock.unlock()

            guard pendingFrame?.swapSerial == swapSerial else {
                return
            }

            guard GLXWindowPresentationTracker.shared.consumeFallbackCompletion(window: windowID) else {
                return
            }

            VisionXRuntimeLog.write(
                "X.Org GLX pending fallback completion window=\(windowID) drawable=\(drawable) swapSerial=\(swapSerial)"
            )
            XOrgBridge.reportGLXSwapPresented(drawable: drawable, swapSerial: swapSerial)
        }
    }

    private func scheduleGLXOffscreenFallbackCompletion(_ frame: VisionGLMetalFrame, windowID: XID) {
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + glxOffscreenFallbackDelay) { [weak self] in
            guard let self else {
                return
            }

            self.glxFrameLock.lock()
            let latestFrame = self.glxFramesByWindow[windowID]
            self.glxFrameLock.unlock()

            guard latestFrame?.serial == frame.serial else {
                return
            }

            guard !GLXWindowPresentationTracker.shared.isActive(window: windowID) else {
                if frame.serial <= 12 || frame.serial.isMultiple(of: 120) {
                    VisionXRuntimeLog.write(
                        "X.Org GLX visible fallback skipped window=\(windowID) drawable=\(frame.drawable) swapSerial=\(frame.swapSerial)"
                    )
                }
                return
            }

            guard GLXWindowPresentationTracker.shared.consumeFallbackCompletion(window: windowID) else {
                if frame.serial <= 12 || frame.serial.isMultiple(of: 120) {
                    VisionXRuntimeLog.write(
                        "X.Org GLX offscreen fallback deferred window=\(windowID) drawable=\(frame.drawable) swapSerial=\(frame.swapSerial)"
                    )
                }
                return
            }

            VisionXRuntimeLog.write(
                "X.Org GLX offscreen fallback completion window=\(windowID) drawable=\(frame.drawable) swapSerial=\(frame.swapSerial)"
            )
            XOrgBridge.reportGLXSwapPresented(drawable: frame.drawable, swapSerial: frame.swapSerial)
        }
    }
#endif

    func executeGLXRender(
        context: XID,
        commands: UnsafePointer<UInt8>?,
        commandLength: Int,
        byteSwapped: UInt8,
        captureDrawCalls: Bool
    ) -> Int32 {
        guard let commands, commandLength >= 0 else {
            VisionXRuntimeLog.write("X.Org GLX render rejected context=\(context) length=\(commandLength)")
            return 0
        }

        let byteOrder: GLXRenderByteOrder = byteSwapped == 0 ? .littleEndian : .bigEndian
        let buffer = UnsafeBufferPointer(start: commands, count: commandLength)
        do {
            let summary = try glxRegistry.executeRenderCommands(
                context: GLXContextID(context),
                bytes: buffer,
                byteOrder: byteOrder,
                captureDrawCalls: captureDrawCalls
            )
            glxRenderExecutionLogCount &+= 1
            if shouldLogGLXRenderExecution(summary) {
                VisionXRuntimeLog.write(
                    "X.Org GLX render executed context=\(context) commands=\(summary.commandCount) draws=\(summary.drawCallCount) clears=\(summary.clearCount) rotations=\(summary.rotationCount) rotationSignature=\(summary.rotationSignature) rotationTrace=\(summary.rotationTrace) skippedLists=\(summary.skippedDisplayListCount) templatedDraws=\(summary.templatedDrawCallCount) templateFallbacks=\(summary.templateFallbackCount) fallbackCurrentColor=\(summary.templateFallbackCurrentColorCount) fallbackCurrentNormal=\(summary.templateFallbackCurrentNormalCount) capture=\(captureDrawCalls)"
                )
            }
            return 1
        } catch {
            VisionXRuntimeLog.write("X.Org GLX render failed context=\(context) length=\(commandLength) error=\(error)")
            return 0
        }
    }

    private func shouldLogGLXRenderExecution(_ summary: GLXRenderExecutionSummary) -> Bool {
        if glxRenderExecutionLogCount <= 12 {
            return true
        }
        guard summary.drawCallCount > 0 ||
            summary.clearCount > 0 ||
            summary.rotationCount > 0 ||
            summary.skippedDisplayListCount > 0 ||
            summary.templatedDrawCallCount > 0 ||
            summary.templateFallbackCount > 0 else {
            return false
        }
        return glxRenderExecutionLogCount.isMultiple(of: 2400)
    }

    func beginGLXDisplayList(context: XID, list: UInt32, mode: UInt32) -> Int32 {
        do {
            try glxRegistry.beginDisplayList(context: GLXContextID(context), list: list, mode: mode)
            VisionXRuntimeLog.write("X.Org GLX new list context=\(context) list=\(list) mode=\(mode)")
            return 1
        } catch {
            VisionXRuntimeLog.write("X.Org GLX new list failed context=\(context) list=\(list) mode=\(mode) error=\(error)")
            return 0
        }
    }

    func endGLXDisplayList(context: XID) -> Int32 {
        do {
            try glxRegistry.endDisplayList(context: GLXContextID(context))
#if canImport(Metal)
            glxMetalRenderer?.discardGeometryCache()
#endif
            VisionXRuntimeLog.write("X.Org GLX end list context=\(context)")
            return 1
        } catch {
            VisionXRuntimeLog.write("X.Org GLX end list failed context=\(context) error=\(error)")
            return 0
        }
    }

    func deleteGLXDisplayLists(context: XID, list: UInt32, range: UInt32) -> Int32 {
        do {
            try glxRegistry.deleteDisplayLists(context: GLXContextID(context), list: list, range: range)
#if canImport(Metal)
            glxMetalRenderer?.discardGeometryCache()
#endif
            VisionXRuntimeLog.write("X.Org GLX delete lists context=\(context) list=\(list) range=\(range)")
            return 1
        } catch {
            VisionXRuntimeLog.write("X.Org GLX delete lists failed context=\(context) list=\(list) range=\(range) error=\(error)")
            return 0
        }
    }

    func generateGLXDisplayLists(context: XID, range: UInt32) -> UInt32 {
        do {
            let first = try glxRegistry.generateDisplayLists(context: GLXContextID(context), range: range)
            VisionXRuntimeLog.write("X.Org GLX gen lists context=\(context) range=\(range) first=\(first)")
            return first
        } catch {
            VisionXRuntimeLog.write("X.Org GLX gen lists failed context=\(context) range=\(range) error=\(error)")
            return 0
        }
    }

    func emitServerExit(_ result: Int32) {
        VisionXRuntimeLog.write("X.Org server exit result=\(result)")
        onServerExit(result)
    }

    private func emitGLX(_ event: XOrgGLXEvent) {
#if canImport(Metal)
        if case .swapBuffers = event {
            glxSwapEventLogCount &+= 1
            if glxSwapEventLogCount <= 12 || glxSwapEventLogCount.isMultiple(of: 240) {
                VisionXRuntimeLog.write("X.Org GLX event \(event.logSummary) count=\(glxSwapEventLogCount)")
            }
            onGLXEvent(event)
            return
        }
#endif
        VisionXRuntimeLog.write("X.Org GLX event \(event.logSummary)")
        onGLXEvent(event)
    }
}

private extension XOrgWindowEvent {
    var isDamage: Bool {
        switch self {
        case .damaged, .damagedRegions:
            return true
        default:
            return false
        }
    }

    var logSummary: String {
        switch self {
        case .mapped(let window, let frame, let metadata):
            return "mapped id=\(window) frame=\(frame.width)x\(frame.height)+\(frame.x)+\(frame.y) title=\(metadata.title)"
        case .unmapped(let window):
            return "unmapped id=\(window)"
        case .configured(let window, let frame):
            return "configured id=\(window) frame=\(frame.width)x\(frame.height)+\(frame.x)+\(frame.y)"
        case .metadataChanged(let window, let metadata):
            return "metadataChanged id=\(window) title=\(metadata.title) class=\(metadata.wmClass.className)"
        case .damaged(let window, let rect):
            return "damaged id=\(window) rect=\(rect.width)x\(rect.height)+\(rect.x)+\(rect.y)"
        case .damagedRegions(let window, let rects):
            if let first = rects.first {
                return "damagedRegions id=\(window) count=\(rects.count) first=\(first.width)x\(first.height)+\(first.x)+\(first.y)"
            }
            return "damagedRegions id=\(window) fullRefresh"
        case .destroyed(let window):
            return "destroyed id=\(window)"
        }
    }
}

private extension XOrgGLXEvent {
    var logSummary: String {
        switch self {
        case .contextCreated(let context, let visualID, let shareContext):
            return "contextCreated id=\(context) visual=\(visualID) share=\(shareContext.map(String.init) ?? "none")"
        case .contextDestroyed(let context):
            return "contextDestroyed id=\(context)"
        case .drawableCreated(let drawable, let backingXID, let kind, let visualID, let width, let height, let placement):
            let placementSummary = placement.map { " presentation=\($0.presentationXID)+\($0.x)+\($0.y)" } ?? ""
            return "drawableCreated id=\(drawable) backing=\(backingXID)\(placementSummary) kind=\(kind) visual=\(visualID) size=\(width)x\(height)"
        case .drawableDestroyed(let drawable):
            return "drawableDestroyed id=\(drawable)"
        case .drawableResized(let drawable, let width, let height):
            return "drawableResized id=\(drawable) size=\(width)x\(height)"
        case .madeCurrent(let context, let drawable):
            return "madeCurrent context=\(context) drawable=\(drawable)"
        case .swapBuffers(let drawable):
            return "swapBuffers drawable=\(drawable)"
        }
    }
}

private func xorgCallbackBox(from context: UnsafeMutableRawPointer?) -> XOrgCallbackBox? {
    guard let context else {
        return nil
    }
    return Unmanaged<XOrgCallbackBox>.fromOpaque(context).takeUnretainedValue()
}

private extension XRectangle {
    init(_ rect: visionx_rect_t) {
        self.init(
            x: Int(rect.x),
            y: Int(rect.y),
            width: Int(rect.width),
            height: Int(rect.height)
        )
    }

    var cRect: visionx_rect_t {
        visionx_rect_t(
            x: Int32(x),
            y: Int32(y),
            width: Int32(width),
            height: Int32(height)
        )
    }
}

private extension XOrgWindowMetadata {
    init(_ metadata: visionx_window_metadata_t) {
        let title = metadata.title.map { String(cString: $0) } ?? ""
        let instance = metadata.wm_instance.map { String(cString: $0) } ?? ""
        let className = metadata.wm_class.map { String(cString: $0) } ?? ""
        let transientFor = metadata.has_transient_for == 0 ? nil : XID(metadata.transient_for)
        self.init(
            title: title,
            wmClass: WMClass(instance: instance, className: className),
            normalHints: WMNormalHints(metadata),
            transientFor: transientFor,
            overrideRedirect: metadata.override_redirect != 0,
            acceptsDeleteWindow: metadata.accepts_delete_window != 0
        )
    }
}

private extension WMNormalHints {
    init(_ metadata: visionx_window_metadata_t) {
        self.init(
            minimumSize: metadata.has_min_size == 0 ? nil : CGSize(
                width: max(1, Int(metadata.min_width)),
                height: max(1, Int(metadata.min_height))
            ),
            maximumSize: metadata.has_max_size == 0 ? nil : CGSize(
                width: max(1, Int(metadata.max_width)),
                height: max(1, Int(metadata.max_height))
            ),
            resizeIncrement: metadata.has_resize_increment == 0 ? nil : CGSize(
                width: max(1, Int(metadata.width_increment)),
                height: max(1, Int(metadata.height_increment))
            ),
            baseSize: metadata.has_base_size == 0 ? nil : CGSize(
                width: max(1, Int(metadata.base_width)),
                height: max(1, Int(metadata.base_height))
            )
        )
    }
}
