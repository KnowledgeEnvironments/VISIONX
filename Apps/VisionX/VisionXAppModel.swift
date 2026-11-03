// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation
import Combine
import SwiftUI
import VisionGL
import VisionXCore
#if canImport(Darwin)
import Darwin
#endif

enum X11ProVisionBrand {
    static let appName = "UHF X11"
    static let fullName = "Ultra High Frequency X11"
    static let copyright = "© 2026 I. Finder"
    static let website = "https://www.lispm.net/apps/uhf-x11/"
    static let xorgLicenseSummary = "Includes X.Org Server 21.1.25 components and X.Org-distributed bitmap font resources. Full upstream license texts are bundled in ThirdPartyLicenses."
    static var versionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(shortVersion) (\(buildVersion))"
    }
    static let thirdPartyNoticeText = """
    Vendored third-party source components: X.Org Server 21.1.25, xtrans 1.6.0, pixman 0.46.0, libXau 1.0.12, libfontenc 1.1.8, libxkbfile 1.1.3, and libXfont2 2.0.9.

    Bundled X.Org bitmap fonts come from the font-adobe, font-adobe-utopia, font-bh, font-bh-lucidatypewriter, font-bitstream, font-arabic-misc, font-cursor-misc, font-daewoo-misc, font-dec-misc, font-isas-misc, font-jis-misc, font-micro-misc, font-misc-misc, font-mutt-misc, font-schumacher-misc, font-sony-misc, and font-sun-misc modules.

    Full upstream license texts are included in the app bundle under ThirdPartyLicenses/Components and ThirdPartyLicenses/Fonts. The generated immersive backdrop and app-authored integration code are project assets/code for UHF X11.
    """

    static let mitLicenseText = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    static let xorgOriginalAuthorNotice = """
    X.Org Server canonical copyright notice includes Dave Airlie, Juliusz Chroboczek, Egbert Eich, Intel Corporation, Nokia Corporation, Peter Hutterer, Adam Jackson, NVIDIA Corporation, Oracle and/or its affiliates, Keith Packard, Red Hat, Daniel Stone, Simon Thum, Geert Uytterhoeven, and Luc Verhaegen. Legacy notices also include The XFree86 Project, The Open Group, Red Hat, and other X.Org source contributors.
    """
}

enum X11FontPackImportError: LocalizedError {
    case userFontPackRootUnavailable

    var errorDescription: String? {
        switch self {
        case .userFontPackRootUnavailable:
            return "User font-pack storage is unavailable."
        }
    }
}

struct XWindowVisualOptions: Equatable {
    var crtEnabled = false
    var scanlineIntensity = 0.36
    var phosphorMaskIntensity = 0.04
    var glowIntensity = 0.2
    var vignetteIntensity = 0.34
    var curvatureIntensity = 0.34
    var warbleIntensity = 0.18
    var xCursorEnabled = true
    var xCursorScale = 0.25
}

enum OverrideRedirectPresentationPolicy: String, CaseIterable, Identifiable {
    case managedRootless
    case allVisibleSurfaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .managedRootless:
            return "Visible X Surfaces"
        case .allVisibleSurfaces:
            return "All Mapped X Surfaces"
        }
    }

    var description: String {
        switch self {
        case .managedRootless:
            return "Show visible override-redirect top-levels as separate windows and filter hidden/offscreen helpers."
        case .allVisibleSurfaces:
            return "Debug mode: show every mapped override-redirect surface, including hidden helpers and diagnostics."
        }
    }
}

struct XWindowDamageEvent: Sendable {
    var window: XID
    var rects: [XRectangle]
    var serial: UInt64

    init(window: XID, rect: XRectangle, serial: UInt64) {
        self.window = window
        self.rects = [rect]
        self.serial = serial
    }

    init(window: XID, rects: [XRectangle], serial: UInt64) {
        self.window = window
        self.rects = rects
        self.serial = serial
    }
}

struct XWindowGLXSurface: Equatable {
    var drawable: XID
    var backingWindow: XID
    var presentationWindow: XID
    var frame: XRectangle
}

enum ControlWindowSceneAction {
    case none
    case openFull
    case openMini
    case closeFull
    case closeMini
}

private enum ControlWindowHandoff {
    case fullToMini
    case miniToFull
}

enum MiniControlMetrics {
    static let windowSize: CGFloat = 56
    static let logoSize: CGFloat = 46
    static let statusDotSize: CGFloat = 8
}

@MainActor
final class VisionXAppModel: ObservableObject {
    private static let eulaAcknowledgementKey = "UHF_X11_EULA_ACKNOWLEDGED_2026_06_17" // gitleaks:allow -- preference key, not a credential
    private static let experimentalGLXEnabledKey = "UHF_X11_EXPERIMENTAL_GLX_ENABLED"

    @Published private(set) var state: VisionXServerState = .stopped
    @Published private(set) var clients: [XClientInfo] = []
    @Published private(set) var windows: [XTopLevelWindow] = []
    @Published private(set) var lastTransportMessage = ""
    @Published private(set) var fontPathConfiguration = X11FontPathConfiguration(fontPath: X11FontPathBuilder.builtInsPathElement)
    @Published var visualOptions = XWindowVisualOptions()
    @Published var overrideRedirectPolicy: OverrideRedirectPresentationPolicy = .managedRootless
    @Published private(set) var isControlWindowMiniaturized = false
    @Published var isLicenseNoticePresented = false
    let damageEvents = PassthroughSubject<XWindowDamageEvent, Never>()
    @Published var selectedHost: String = LocalNetworkIdentity.preferredTestingIPv4Address() ?? "127.0.0.1" {
        didSet {
            server.setBindAddress(selectedHost)
        }
    }

    private let server = VisionXServerController()
    private let windowManager = RootlessWindowManager()
    private var openedNativeWindowSceneIDs: Set<XID> = []
    private var programmaticallyDismissedNativeWindowSceneIDs: Set<XID> = []
    private var hasObservedControlWindowScene = false
    private var controlWindowRecoveryPending = false
    private var primaryControlWindowSceneID: UUID?
    private var activeControlWindowSceneIDs: Set<UUID> = []
    private var primaryMiniControlWindowSceneID: UUID?
    private var activeMiniControlWindowSceneIDs: Set<UUID> = []
    private var pendingControlWindowHandoff: ControlWindowHandoff?
    private var nextDamageEventSerial: UInt64 = 0
    private var glxWindowSurfacesByDrawable: [XID: XWindowGLXSurface] = [:]

    var displayNumber: Int {
        server.configuration.displayNumber
    }

    var listenPort: UInt16 {
        server.configuration.listenPort
    }

    var cookieHex: String {
        server.configuration.cookie.hexString
    }

    var requireMITMagicCookie: Bool {
        get {
            server.configuration.requireMITMagicCookie
        }
        set {
            server.setRequireMITMagicCookie(newValue)
            objectWillChange.send()
        }
    }

    var xhostPlusEnabled: Bool {
        get {
            !requireMITMagicCookie
        }
        set {
            requireMITMagicCookie = !newValue
        }
    }

    var accessControlMode: String {
        requireMITMagicCookie ? "MIT-MAGIC-COOKIE-1" : "xhost +"
    }

    var experimentalGLXEnabled: Bool {
        get {
            server.configuration.experimentalGLXEnabled
        }
        set {
            guard case .stopped = state else {
                return
            }
            server.setExperimentalGLXEnabled(newValue)
            UserDefaults.standard.set(newValue, forKey: Self.experimentalGLXEnabledKey)
            objectWillChange.send()
        }
    }

    var canForceStopServer: Bool {
        server.canForceStop
    }

    var xauthCommand: String {
        server.xauthCommand(host: selectedHost)
    }

    var localAddresses: [String] {
        let addresses = LocalNetworkIdentity.localIPv4Addresses()
        if addresses.isEmpty {
            return ["127.0.0.1"]
        }
        return LocalNetworkIdentity.sortedTestingIPv4Addresses(addresses)
    }

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--visionx-accept-notice") {
            UserDefaults.standard.set(true, forKey: Self.eulaAcknowledgementKey)
            VisionXRuntimeLog.write("launch diagnostics accepted license and risk notice")
        }
        isLicenseNoticePresented = !UserDefaults.standard.bool(forKey: Self.eulaAcknowledgementKey)
        server.setExperimentalGLXEnabled(UserDefaults.standard.bool(forKey: Self.experimentalGLXEnabledKey))
        VisionXRuntimeLog.write("VisionXAppModel initialized args=\(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " ")) addresses=\(localAddresses.joined(separator: ",")) selectedHost=\(selectedHost)")
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(serverEvent: event)
            }
        }
        windowManager.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(windowManagerEvent: event)
            }
        }
        configureX11Fonts()
        runLaunchDiagnosticsIfRequested()
    }

    func startServer() {
        VisionXRuntimeLog.write("UI startServer")
        configureX11Fonts()
        server.start()
    }

    func stopServer() {
        VisionXRuntimeLog.write("UI stopServer")
        server.stop()
    }

    func forceStopServer() {
        VisionXRuntimeLog.write("UI forceStopServer")
        server.forceStop()
    }

    func rotateCookie() {
        server.rotateCookie()
        objectWillChange.send()
    }

    func resetVisualOptions() {
        visualOptions = XWindowVisualOptions()
    }

    func refreshX11FontPath() {
        configureX11Fonts()
    }

    func listX11Fonts() -> X11FontListing {
        configureX11Fonts()
        return X11FontPathBuilder.listIndexedFonts(in: fontPathConfiguration)
    }

    @discardableResult
    func hideControlWindowToMini() -> Bool {
        VisionXRuntimeLog.write("UI hide control window to mini control")
        isControlWindowMiniaturized = true
        pendingControlWindowHandoff = nil
        return true
    }

    @discardableResult
    func restoreFullControlWindow() -> Bool {
        VisionXRuntimeLog.write("UI restore full control window from mini control")
        isControlWindowMiniaturized = false
        pendingControlWindowHandoff = nil
        return true
    }

    func acknowledgeEULA() {
        VisionXRuntimeLog.write("UI acknowledge license and risk notice")
        UserDefaults.standard.set(true, forKey: Self.eulaAcknowledgementKey)
        isLicenseNoticePresented = false
    }

    func controlWindowDidAppear(instance id: UUID) -> ControlWindowSceneAction? {
        if let primaryControlWindowSceneID, primaryControlWindowSceneID != id {
            VisionXRuntimeLog.write(
                "UI reject duplicate control scene instance=\(id.uuidString) primary=\(primaryControlWindowSceneID.uuidString)"
            )
            return nil
        }
        primaryControlWindowSceneID = id
        activeControlWindowSceneIDs.insert(id)
        hasObservedControlWindowScene = true
        controlWindowRecoveryPending = false
        VisionXRuntimeLog.write("UI control scene visible instance=\(id.uuidString)")
        return ControlWindowSceneAction.none
    }

    func controlWindowDidDisappear(instance id: UUID) -> ControlWindowSceneAction {
        guard activeControlWindowSceneIDs.remove(id) != nil else {
            return .none
        }
        guard primaryControlWindowSceneID == id else {
            return .none
        }
        primaryControlWindowSceneID = activeControlWindowSceneIDs.first
        hasObservedControlWindowScene = primaryControlWindowSceneID != nil
        if let primaryControlWindowSceneID {
            VisionXRuntimeLog.write("UI control scene primary moved instance=\(primaryControlWindowSceneID.uuidString)")
        } else {
            VisionXRuntimeLog.write("UI control scene no visible instances")
            if pendingControlWindowHandoff == .fullToMini {
                VisionXRuntimeLog.write("UI opening mini control after full control scene disappeared")
                pendingControlWindowHandoff = nil
                return .openMini
            }
            VisionXRuntimeLog.write("UI full control scene closed without handoff")
        }
        return ControlWindowSceneAction.none
    }

    func miniControlWindowDidAppear(instance id: UUID) -> ControlWindowSceneAction? {
        guard isControlWindowMiniaturized else {
            VisionXRuntimeLog.write("UI reject inactive mini control scene instance=\(id.uuidString)")
            return nil
        }
        if let primaryMiniControlWindowSceneID, primaryMiniControlWindowSceneID != id {
            VisionXRuntimeLog.write(
                "UI reject duplicate mini control scene instance=\(id.uuidString) primary=\(primaryMiniControlWindowSceneID.uuidString)"
            )
            return nil
        }
        primaryMiniControlWindowSceneID = id
        activeMiniControlWindowSceneIDs.insert(id)
        VisionXRuntimeLog.write("UI mini control scene visible instance=\(id.uuidString)")
        return ControlWindowSceneAction.none
    }

    func miniControlWindowDidDisappear(instance id: UUID) -> ControlWindowSceneAction {
        guard activeMiniControlWindowSceneIDs.remove(id) != nil else {
            return .none
        }
        guard primaryMiniControlWindowSceneID == id else {
            return .none
        }
        primaryMiniControlWindowSceneID = activeMiniControlWindowSceneIDs.first
        if let primaryMiniControlWindowSceneID {
            VisionXRuntimeLog.write("UI mini control scene primary moved instance=\(primaryMiniControlWindowSceneID.uuidString)")
        } else {
            VisionXRuntimeLog.write("UI mini control scene no visible instances")
            if pendingControlWindowHandoff == .miniToFull {
                VisionXRuntimeLog.write("UI opening full control after mini control scene disappeared")
                pendingControlWindowHandoff = nil
                return .openFull
            }
            VisionXRuntimeLog.write("UI mini control scene closed without handoff")
            isControlWindowMiniaturized = false
        }
        return .none
    }

    func requestControlWindowRecoveryFromStaleScene(window id: XID) -> Bool {
        guard !isControlWindowMiniaturized else {
            VisionXRuntimeLog.write("UI skip control scene recovery because mini control mode is active staleWindow=\(id)")
            return false
        }
        guard !hasObservedControlWindowScene else {
            VisionXRuntimeLog.write("UI skip control scene recovery because control scene is already visible staleWindow=\(id)")
            return false
        }
        guard !controlWindowRecoveryPending else {
            VisionXRuntimeLog.write("UI skip duplicate control scene recovery staleWindow=\(id)")
            return false
        }
        VisionXRuntimeLog.write("UI schedule control scene recovery from stale X window id=\(id)")
        controlWindowRecoveryPending = true
        return true
    }

    func consumeControlWindowRecoveryRequest() -> Bool {
        guard controlWindowRecoveryPending else {
            return false
        }
        controlWindowRecoveryPending = false
        guard !isControlWindowMiniaturized else {
            VisionXRuntimeLog.write("UI skip delayed control scene recovery because mini control mode is active")
            return false
        }
        guard !hasObservedControlWindowScene else {
            VisionXRuntimeLog.write("UI skip delayed control scene recovery because control scene appeared")
            return false
        }
        hasObservedControlWindowScene = true
        return true
    }

    @discardableResult
    func importFontPack(from sourceURL: URL) throws -> X11FontPackInstallResult {
        guard let userFontPackRoot = X11FontPathBuilder.defaultUserFontPackRoot() else {
            throw X11FontPackImportError.userFontPackRootUnavailable
        }

        let securityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if securityScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let result = try X11FontPackInstaller.install(source: sourceURL, into: userFontPackRoot)
        VisionXRuntimeLog.write("imported X11 font pack source=\(result.source) destination=\(result.destination)")
        configureX11Fonts()
        return result
    }

    func route(window id: XID, to route: XWindowRoute) {
        VisionXRuntimeLog.write("UI route window id=\(id) route=\(route)")
        windowManager.route(window: id, to: route)
    }

    func close(window id: XID) {
        VisionXRuntimeLog.write("UI close window requested id=\(id)")
        windowManager.requestCloseFromVisionOS(window: id)
    }

    @discardableResult
    func focus(window id: XID) -> Bool {
        windowManager.focus(window: id)
        return server.focus(window: id)
    }

    @discardableResult
    func activate(window id: XID, raise: Bool = true) -> Bool {
        windowManager.focus(window: id)
        return server.activate(window: id, raise: raise)
    }

    @discardableResult
    func send(pointer event: XPointerEvent) -> Bool {
        server.send(pointer: event)
    }

    @discardableResult
    func send(key event: XKeyboardEvent) -> Bool {
        server.send(key: event)
    }

    func pixelBuffer(for windowID: XID) -> XWindowPixelBuffer? {
        server.copyPixels(window: windowID)
    }

    func pixelRegion(for windowID: XID, rect: XRectangle) -> XWindowPixelRegion? {
        server.copyPixelRegion(window: windowID, rect: rect)
    }

    func copyPixelRegion(for windowID: XID, rect: XRectangle, into data: inout Data) -> XWindowPixelRegionDescriptor? {
        server.copyPixelRegion(window: windowID, rect: rect, into: &data)
    }

#if canImport(Metal)
    func glxFrame(for windowID: XID) -> VisionGLMetalFrame? {
        server.glxFrame(window: windowID)
    }

    func glxSurface(for windowID: XID) -> XWindowGLXSurface? {
        glxWindowSurfacesByDrawable.values
            .filter { $0.presentationWindow == windowID || $0.backingWindow == windowID }
            .sorted { $0.drawable < $1.drawable }
            .first
    }
#endif

    func nativeWindowSceneSyncActions() -> (open: [XTopLevelWindow], dismiss: [XID]) {
        let openableWindows = windows.filter { window in
            isNativeSceneOpenable(window)
        }
        let openableIDs = Set(openableWindows.map(\.id))
        let staleIDs = openedNativeWindowSceneIDs.subtracting(openableIDs).sorted()
        openedNativeWindowSceneIDs.subtract(staleIDs)
        programmaticallyDismissedNativeWindowSceneIDs.formUnion(staleIDs)

        let windowsToOpen = openableWindows.filter { window in
            !openedNativeWindowSceneIDs.contains(window.id)
        }
        for window in windowsToOpen {
            openedNativeWindowSceneIDs.insert(window.id)
        }

        return (windowsToOpen, staleIDs)
    }

    func forceNativeWindowSceneOpenActions() -> [XTopLevelWindow] {
        let openableWindows = windows.filter { window in
            isNativeSceneOpenable(window)
        }
        for window in openableWindows {
            openedNativeWindowSceneIDs.insert(window.id)
        }
        return openableWindows
    }

    func nativeWindowSceneDidClose(_ id: XID) {
        openedNativeWindowSceneIDs.remove(id)
    }

    func markProgrammaticNativeWindowSceneDismissal(_ id: XID) {
        programmaticallyDismissedNativeWindowSceneIDs.insert(id)
    }

    func consumeProgrammaticNativeWindowSceneDismissal(_ id: XID) -> Bool {
        programmaticallyDismissedNativeWindowSceneIDs.remove(id) != nil
    }

    func isVisibleInWindowList(_ window: XTopLevelWindow) -> Bool {
        guard window.mapState == .mapped else {
            return false
        }

        if window.overrideRedirect {
            switch overrideRedirectPolicy {
            case .managedRootless:
                return window.isVisibleOverrideRedirectWindow
            case .allVisibleSurfaces:
                return window.hasDrawableArea
            }
        }

        return true
    }

    func isNativeSceneOpenable(_ window: XTopLevelWindow) -> Bool {
        guard window.mapState == .mapped else {
            return false
        }

        switch window.route {
        case .nativeWindow:
            return true
        case .overrideRedirect:
            switch overrideRedirectPolicy {
            case .managedRootless:
                return window.isVisibleOverrideRedirectWindow
            case .allVisibleSurfaces:
                return window.hasDrawableArea
            }
        case .immersivePanel:
            return false
        }
    }

    private func handle(serverEvent event: VisionXServerEvent) {
        if !event.isDamageOnly {
            VisionXRuntimeLog.write("app model server event \(event.logSummary)")
        }
        switch event {
        case .stateChanged(let nextState):
            state = nextState
            if nextState.shouldClearXWindows {
                windowManager.destroyAllWindows()
                openedNativeWindowSceneIDs.removeAll()
            }
            if case .failed(let message) = nextState {
                lastTransportMessage = message
            }
        case .transport(let transportEvent):
            clients = server.activeClients.values.sorted { $0.endpointDescription < $1.endpointDescription }
            lastTransportMessage = transportEvent.summary
        case .window(let windowEvent):
            handle(xorgWindowEvent: windowEvent)
        case .glx(let glxEvent):
            handle(glxEvent: glxEvent)
        }
    }

    private func handle(glxEvent event: XOrgGLXEvent) {
        switch event {
        case .drawableCreated(let drawable, let backingXID, let kind, _, let width, let height, let placement):
            if kind == .window {
                let presentationXID = placement?.presentationXID ?? backingXID
                let frame = XRectangle(
                    x: placement?.x ?? 0,
                    y: placement?.y ?? 0,
                    width: width,
                    height: height
                )
                glxWindowSurfacesByDrawable[drawable] = XWindowGLXSurface(
                    drawable: drawable,
                    backingWindow: backingXID,
                    presentationWindow: presentationXID,
                    frame: frame
                )
                VisionXRuntimeLog.write(
                    "app model GLX drawable window drawable=\(drawable) backing=\(backingXID) presentation=\(presentationXID)+\(frame.x)+\(frame.y) size=\(width)x\(height)"
                )
            }
        case .drawableDestroyed(let drawable):
            glxWindowSurfacesByDrawable.removeValue(forKey: drawable)
        case .drawableResized(let drawable, let width, let height):
            guard var surface = glxWindowSurfacesByDrawable[drawable] else {
                return
            }
            surface.frame.width = width
            surface.frame.height = height
            glxWindowSurfacesByDrawable[drawable] = surface
            nextDamageEventSerial &+= 1
            damageEvents.send(XWindowDamageEvent(
                window: surface.presentationWindow,
                rect: surface.frame,
                serial: nextDamageEventSerial
            ))
        case .swapBuffers(let drawable):
            guard let surface = glxWindowSurfacesByDrawable[drawable] else {
                return
            }
            nextDamageEventSerial &+= 1
            damageEvents.send(XWindowDamageEvent(
                window: surface.presentationWindow,
                rect: surface.frame,
                serial: nextDamageEventSerial
            ))
        default:
            break
        }
    }

    private func handle(xorgWindowEvent event: XOrgWindowEvent) {
        if !event.isDamage {
            VisionXRuntimeLog.write("app model X.Org window event \(event.logSummary)")
        }
        switch event {
        case .mapped(let id, let frame, let metadata):
            _ = windowManager.upsertTopLevel(
                XTopLevelWindow(
                    id: id,
                    title: metadata.title,
                    wmClass: metadata.wmClass,
                    normalHints: metadata.normalHints,
                    protocols: metadata.protocols,
                    transientFor: metadata.transientFor,
                    overrideRedirect: metadata.overrideRedirect,
                    frame: frame
                )
            )
            windowManager.map(window: id)
        case .unmapped(let id):
            windowManager.unmap(window: id)
        case .configured(let id, let frame):
            windowManager.configure(window: id, frame: frame)
        case .metadataChanged(let id, let metadata):
            windowManager.updateProperties(
                window: id,
                title: metadata.title,
                wmClass: metadata.wmClass,
                normalHints: metadata.normalHints,
                protocols: metadata.protocols,
                transientFor: .some(metadata.transientFor)
            )
        case .damaged(let id, let rect):
            nextDamageEventSerial &+= 1
            damageEvents.send(XWindowDamageEvent(window: id, rect: rect, serial: nextDamageEventSerial))
        case .damagedRegions(let id, let rects):
            nextDamageEventSerial &+= 1
            damageEvents.send(XWindowDamageEvent(window: id, rects: rects, serial: nextDamageEventSerial))
        case .destroyed(let id):
            windowManager.destroy(window: id)
        }
    }

    private func handle(windowManagerEvent event: XWindowManagerEvent) {
        windows = windowManager.windows.values.sorted { $0.id < $1.id }
        if !event.isDamage {
            VisionXRuntimeLog.write("window manager event \(event.logSummary) activeWindows=\(windows.count)")
        }

        switch event {
        case .clientMessage(let window, .deleteWindow), .killClientRequested(let window):
            _ = server.close(window: window)
        default:
            break
        }
    }

    private func runLaunchDiagnosticsIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        let autostart = arguments.contains("--visionx-autostart") || environment["VISIONX_AUTOSTART"] == "1"
        guard autostart else {
            return
        }

        let useXhostPlus = arguments.contains("--visionx-xhost-plus") || environment["VISIONX_XHOST_PLUS"] == "1"
        let experimentalGLXRequested = arguments.contains("--visionx-experimental-glx") ||
            environment["VISIONX_EXPERIMENTAL_GLX"] == "1"
        let stopAfter = Self.doubleArgument(named: "--visionx-autostop-after", in: arguments)
            ?? environment["VISIONX_AUTOSTOP_AFTER"].flatMap(Double.init)
        let bindAddressOverride = Self.stringArgument(named: "--visionx-bind-address", in: arguments)
            ?? environment["VISIONX_BIND_ADDRESS"]
        let exitAfterDiagnostics = arguments.contains("--visionx-exit-after-diagnostics") ||
            environment["VISIONX_EXIT_AFTER_DIAGNOSTICS"] == "1"
        let restartSmoke = arguments.contains("--visionx-restart-smoke") ||
            environment["VISIONX_RESTART_SMOKE"] == "1"
        let stopAfterDescription: String
        if let stopAfter {
            stopAfterDescription = String(stopAfter)
        } else {
            stopAfterDescription = "nil"
        }

        VisionXRuntimeLog.write(
            "launch diagnostics requested autostart=true xhostPlus=\(useXhostPlus) experimentalGLXRequested=\(experimentalGLXRequested) experimentalGLXConfigured=\(server.configuration.experimentalGLXEnabled) bindOverride=\(bindAddressOverride ?? "nil") stopAfter=\(stopAfterDescription) restartSmoke=\(restartSmoke) exitAfterDiagnostics=\(exitAfterDiagnostics)"
        )

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if useXhostPlus {
                self.requireMITMagicCookie = false
            }
            if experimentalGLXRequested {
                self.server.setExperimentalGLXEnabled(true)
                self.objectWillChange.send()
            }
            if let bindAddressOverride {
                self.applyBindAddressOverride(bindAddressOverride)
            }

            self.startServer()
            try? await Task.sleep(nanoseconds: 750_000_000)

            if restartSmoke {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.stopServer()
                for _ in 0..<80 {
                    if self.state.isTerminalForDiagnostics {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
                self.startServer()
            }

            if let stopAfter {
                let nanoseconds = UInt64(max(0, stopAfter) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                self.stopServer()
            }

            if exitAfterDiagnostics {
                for _ in 0..<60 {
                    if self.state.isTerminalForDiagnostics {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                VisionXRuntimeLog.write("launch diagnostics exiting app state=\(self.state)")
                #if canImport(Darwin)
                Darwin.exit(0)
                #endif
            }
        }
    }

    private func configureX11Fonts() {
        let bundledFontsURL = Bundle.main.resourceURL?.appending(path: "X11Fonts", directoryHint: .isDirectory)
        if bundledFontsURL == nil {
            VisionXRuntimeLog.write("bundled X11 font path unavailable")
        }

        let userFontPackRoot = X11FontPathBuilder.defaultUserFontPackRoot()
        if let userFontPackRoot {
            do {
                try X11FontPathBuilder.ensureUserFontPackRoot(userFontPackRoot)
            } catch {
                VisionXRuntimeLog.write("user X11 font pack directory unavailable path=\(userFontPackRoot.path) error=\(error.localizedDescription)")
            }
        }

        let configuration = X11FontPathBuilder.build(
            bundledFontRoot: bundledFontsURL,
            userFontPackRoot: userFontPackRoot
        )
        fontPathConfiguration = configuration
        setenv("VISIONX_XORG_FONT_PATH", configuration.fontPath, 1)
        VisionXRuntimeLog.write(
            "X11 font path=\(configuration.fontPath) userRoot=\(configuration.userFontPackRoot ?? "nil") userIndexed=\(configuration.userFontDirectories.count) userSkipped=\(configuration.skippedUserFontDirectories.count) bundled=\(configuration.bundledFontDirectories.count)"
        )
    }

    private func applyBindAddressOverride(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }

        switch value.lowercased() {
        case "all", "any", "*", "0.0.0.0":
            server.setBindAddress(nil)
            VisionXRuntimeLog.write("launch diagnostics bind override=all")
        default:
            selectedHost = value
            server.setBindAddress(value)
            VisionXRuntimeLog.write("launch diagnostics bind override=\(value)")
        }
    }

    private static func doubleArgument(named name: String, in arguments: [String]) -> Double? {
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == name, arguments.indices.contains(index + 1) {
                return Double(arguments[index + 1])
            }
            let prefix = "\(name)="
            if argument.hasPrefix(prefix) {
                return Double(argument.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func stringArgument(named name: String, in arguments: [String]) -> String? {
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == name, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
            let prefix = "\(name)="
            if argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count))
            }
        }
        return nil
    }
}

private extension XTransportEvent {
    var summary: String {
        switch self {
        case .listening(let port):
            return "Listening on TCP \(port)"
        case .failed(let reason):
            return "Transport failed: \(reason)"
        case .clientAccepted(let info):
            return "Accepted \(info.endpointDescription)"
        case .clientRejected(let endpointDescription, let reason):
            return "Rejected \(endpointDescription): \(reason)"
        case .clientDisconnected:
            return "Client disconnected"
        }
    }
}

private extension VisionXServerEvent {
    var isDamageOnly: Bool {
        if case .window(let event) = self {
            return event.isDamage
        }
        if case .glx(let event) = self, case .swapBuffers = event {
            return true
        }
        return false
    }

    var logSummary: String {
        switch self {
        case .stateChanged(let state):
            return "stateChanged \(state)"
        case .transport(let event):
            return "transport \(event.summary)"
        case .window(let event):
            return "window \(event.logSummary)"
        case .glx(let event):
            return "glx \(event)"
        }
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

private extension XWindowManagerEvent {
    var isDamage: Bool {
        if case .damage = self {
            return true
        }
        return false
    }

    var logSummary: String {
        switch self {
        case .created(let window):
            return "created id=\(window.id)"
        case .mapped(let window):
            return "mapped id=\(window.id)"
        case .unmapped(let window):
            return "unmapped id=\(window)"
        case .configured(let window):
            return "configured id=\(window.id) frame=\(window.frame.width)x\(window.frame.height)+\(window.frame.x)+\(window.frame.y) route=\(window.route)"
        case .destroyed(let window):
            return "destroyed id=\(window)"
        case .focused(let window):
            return "focused id=\(window)"
        case .closeRequestedByVisionOS(let window):
            return "closeRequestedByVisionOS id=\(window)"
        case .clientMessage(let window, let message):
            return "clientMessage id=\(window) message=\(message)"
        case .killClientRequested(let window):
            return "killClientRequested id=\(window)"
        case .damage(let window, let serial, let rect):
            if let rect {
                return "damage id=\(window) serial=\(serial) rect=\(rect.width)x\(rect.height)+\(rect.x)+\(rect.y)"
            }
            return "damage id=\(window) serial=\(serial)"
        }
    }
}

private extension CGRect {
    init(_ rect: XRectangle) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

private extension VisionXServerState {
    var isTerminalForDiagnostics: Bool {
        switch self {
        case .stopped, .failed:
            return true
        case .starting, .running, .stopping:
            return false
        }
    }

    var shouldClearXWindows: Bool {
        switch self {
        case .stopping, .stopped, .failed:
            return true
        case .starting, .running:
            return false
        }
    }
}

extension XTopLevelWindow {
    var hasDrawableArea: Bool {
        frame.width > 1 && frame.height > 1
    }

    var isVisibleOverrideRedirectWindow: Bool {
        guard hasDrawableArea else {
            return false
        }

        return frame.x + frame.width > 0 && frame.y + frame.height > 0
    }
}
