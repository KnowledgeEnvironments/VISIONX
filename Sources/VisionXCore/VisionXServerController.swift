// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import VisionGL

public enum VisionXServerState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    case stopping
    case failed(String)
}

public enum VisionXServerBackendKind: Equatable, Sendable {
    case embeddedXOrg
    case diagnosticDirectTCP
}

public struct VisionXServerConfiguration: Equatable, Sendable {
    public var displayNumber: Int
    public var listenPort: UInt16
    public var bindAddress: String?
    public var cookie: MITMagicCookie
    public var requireMITMagicCookie: Bool
    public var screenSize: CGSize
    public var backendKind: VisionXServerBackendKind
    public var experimentalGLXEnabled: Bool

    public init(
        displayNumber: Int = 0,
        listenPort: UInt16 = 6000,
        bindAddress: String? = LocalNetworkIdentity.preferredTestingIPv4Address(),
        cookie: MITMagicCookie = .generate(),
        requireMITMagicCookie: Bool = true,
        screenSize: CGSize = CGSize(width: 1280, height: 720),
        backendKind: VisionXServerBackendKind = .embeddedXOrg,
        experimentalGLXEnabled: Bool = false
    ) {
        self.displayNumber = displayNumber
        self.listenPort = listenPort
        self.bindAddress = bindAddress
        self.cookie = cookie
        self.requireMITMagicCookie = requireMITMagicCookie
        self.screenSize = screenSize
        self.backendKind = backendKind
        self.experimentalGLXEnabled = experimentalGLXEnabled
    }
}

public enum VisionXServerEvent: Equatable, Sendable {
    case stateChanged(VisionXServerState)
    case transport(XTransportEvent)
    case window(XOrgWindowEvent)
    case glx(XOrgGLXEvent)
}

public final class VisionXServerController: @unchecked Sendable {
    public private(set) var configuration: VisionXServerConfiguration
    public private(set) var state: VisionXServerState = .stopped
    public private(set) var activeClients: [XClientID: XClientInfo] = [:]

    public var onEvent: @Sendable (VisionXServerEvent) -> Void = { _ in }

    private var transport: DirectTCPXTransport?
    private var xorgBackend: XOrgServerBackend?
    private var stoppingTransport: DirectTCPXTransport?
    private var stoppingXorgBackend: XOrgServerBackend?

    public var canForceStop: Bool {
        transport != nil || xorgBackend != nil || stoppingTransport != nil || stoppingXorgBackend != nil
    }

    public init(configuration: VisionXServerConfiguration = VisionXServerConfiguration()) {
        self.configuration = configuration
    }

#if canImport(Metal)
    public func glxFrame(window id: XID) -> VisionGLMetalFrame? {
        xorgBackend?.glxFrame(window: id)
    }
#endif

    public func start() {
        switch state {
        case .stopped, .failed:
            break
        case .starting, .running, .stopping:
            VisionXRuntimeLog.write("server start ignored state=\(state)")
            return
        }

        VisionXRuntimeLog.write(
            "server start requested backend=\(configuration.backendKind) display=:\(configuration.displayNumber) port=\(configuration.listenPort) bind=\(configuration.bindAddress ?? "all") auth=\(configuration.requireMITMagicCookie ? "MIT-MAGIC-COOKIE-1" : "disabled") screen=\(Int(configuration.screenSize.width))x\(Int(configuration.screenSize.height))"
        )
        transition(to: .starting)

        switch configuration.backendKind {
        case .embeddedXOrg:
            startEmbeddedXOrgBackend()
        case .diagnosticDirectTCP:
            startDiagnosticTransport()
        }
    }

    private func startEmbeddedXOrgBackend() {
        let backend = XOrgServerBackend()
        backend.onWindowEvent = { [weak self] event in
            self?.onEvent(.window(event))
        }
        backend.onGLXEvent = { [weak self] event in
            self?.onEvent(.glx(event))
        }
        backend.onServerExit = { [weak self, weak backend] result in
            guard let self else {
                return
            }
            VisionXRuntimeLog.write("embedded X.Org backend exited result=\(result) state=\(self.state)")
            guard let backend, self.xorgBackend === backend else {
                return
            }
            self.xorgBackend = nil
            self.activeClients.removeAll()
            switch self.state {
            case .stopping, .stopped:
                break
            default:
                self.transition(to: .failed("Embedded X.Org exited unexpectedly with code \(result)"))
            }
        }

        self.xorgBackend = backend
        do {
            try backend.start(configuration: configuration, screenSize: configuration.screenSize)
            VisionXRuntimeLog.write("embedded X.Org backend start returned success")
            if self.xorgBackend === backend {
                transition(to: .running(port: configuration.listenPort))
            }
        } catch {
            if self.xorgBackend === backend {
                self.xorgBackend = nil
            }
            VisionXRuntimeLog.write("embedded X.Org backend start failed: \(error.localizedDescription)")
            transition(to: .failed(error.localizedDescription))
        }
    }

    private func startDiagnosticTransport() {
        let cookie = configuration.requireMITMagicCookie ? configuration.cookie : nil
        let transport = DirectTCPXTransport(cookie: cookie)
        transport.onEvent = { [weak self] event in
            self?.handleTransportEvent(event)
        }

        do {
            try transport.start(port: configuration.listenPort)
            self.transport = transport
        } catch {
            VisionXRuntimeLog.write("diagnostic TCP transport start failed: \(error.localizedDescription)")
            transition(to: .failed(error.localizedDescription))
        }
    }

    public func stop() {
        if case .stopping = state {
            forceStop()
            return
        }

        guard transport != nil || xorgBackend != nil || stoppingTransport != nil || stoppingXorgBackend != nil else {
            VisionXRuntimeLog.write("server stop requested with no active backend")
            transition(to: .stopped)
            return
        }

        VisionXRuntimeLog.write("server stop requested")
        transition(to: .stopping)
        let transport = transport
        let xorgBackend = xorgBackend
        self.transport = nil
        self.xorgBackend = nil
        self.stoppingTransport = transport
        self.stoppingXorgBackend = xorgBackend
        activeClients.removeAll()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            VisionXRuntimeLog.write("server stop worker entered")
            transport?.stop()
            let xorgStopped = xorgBackend?.stop() ?? true
            VisionXRuntimeLog.write("server stop worker completed xorgStopped=\(xorgStopped)")
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.stoppingTransport = nil
                self.stoppingXorgBackend = xorgStopped ? nil : xorgBackend
                if xorgStopped {
                    self.transition(to: .stopped)
                } else {
                    self.transition(to: .failed("Timed out while stopping embedded X.Org. Use Force Stop or quit and reopen before starting again."))
                }
            }
        }
    }

    public func forceStop(timeoutMilliseconds: UInt32 = 1_000) {
        guard transport != nil || xorgBackend != nil || stoppingTransport != nil || stoppingXorgBackend != nil else {
            VisionXRuntimeLog.write("server force stop requested with no active backend")
            transition(to: .stopped)
            return
        }

        VisionXRuntimeLog.write("server force stop requested")
        transition(to: .stopping)
        let transport = transport ?? stoppingTransport
        let xorgBackend = xorgBackend ?? stoppingXorgBackend
        self.transport = nil
        self.xorgBackend = nil
        self.stoppingTransport = transport
        self.stoppingXorgBackend = xorgBackend
        activeClients.removeAll()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            VisionXRuntimeLog.write("server force stop worker entered")
            transport?.stop()
            let xorgStopped = xorgBackend?.forceStop(timeoutMilliseconds: timeoutMilliseconds) ?? true
            VisionXRuntimeLog.write("server force stop worker completed xorgStopped=\(xorgStopped)")
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.stoppingTransport = nil
                self.stoppingXorgBackend = xorgStopped ? nil : xorgBackend
                if xorgStopped {
                    self.transition(to: .stopped)
                } else {
                    self.transition(to: .failed("Embedded X.Org did not exit. Quit and reopen UHF X11 before starting the server again."))
                }
            }
        }
    }

    public func rotateCookie() {
        guard case .stopped = state else {
            return
        }
        configuration.cookie = .generate()
    }

    public func setRequireMITMagicCookie(_ isRequired: Bool) {
        guard case .stopped = state else {
            return
        }
        configuration.requireMITMagicCookie = isRequired
    }

    public func setBindAddress(_ bindAddress: String?) {
        guard case .stopped = state else {
            return
        }
        configuration.bindAddress = bindAddress?.isEmpty == true ? nil : bindAddress
    }

    public func setBackendKind(_ backendKind: VisionXServerBackendKind) {
        guard case .stopped = state else {
            return
        }
        configuration.backendKind = backendKind
    }

    public func setExperimentalGLXEnabled(_ isEnabled: Bool) {
        guard case .stopped = state else {
            return
        }
        configuration.experimentalGLXEnabled = isEnabled
    }

    @discardableResult
    public func send(pointer event: XPointerEvent) -> Bool {
        xorgBackend?.send(pointer: event) ?? false
    }

    @discardableResult
    public func send(key event: XKeyboardEvent) -> Bool {
        xorgBackend?.send(key: event) ?? false
    }

    @discardableResult
    public func focus(window id: XID) -> Bool {
        xorgBackend?.focus(window: id) ?? false
    }

    @discardableResult
    public func activate(window id: XID, raise: Bool = true) -> Bool {
        xorgBackend?.activate(window: id, raise: raise) ?? false
    }

    @discardableResult
    public func configure(window id: XID, frame: XRectangle) -> Bool {
        xorgBackend?.configure(window: id, frame: frame) ?? false
    }

    @discardableResult
    public func close(window id: XID) -> Bool {
        xorgBackend?.close(window: id) ?? false
    }

    public func copyPixels(window id: XID) -> XWindowPixelBuffer? {
        xorgBackend?.copyPixels(window: id)
    }

    public func copyPixelRegion(window id: XID, rect: XRectangle) -> XWindowPixelRegion? {
        xorgBackend?.copyPixelRegion(window: id, rect: rect)
    }

    public func copyPixelRegion(window id: XID, rect: XRectangle, into data: inout Data) -> XWindowPixelRegionDescriptor? {
        xorgBackend?.copyPixelRegion(window: id, rect: rect, into: &data)
    }

    public func xauthCommand(host: String) -> String {
        XAuthorityCommand(
            endpoint: XDisplayEndpoint(host: host, displayNumber: configuration.displayNumber),
            cookie: configuration.cookie
        ).commandLine
    }

    private func handleTransportEvent(_ event: XTransportEvent) {
        VisionXRuntimeLog.write("transport event \(event.summary)")
        switch event {
        case .listening(let port):
            transition(to: .running(port: port))
        case .failed(let reason):
            transition(to: .failed(reason))
        case .clientAccepted(let info):
            activeClients[info.id] = info
        case .clientDisconnected(let id):
            activeClients.removeValue(forKey: id)
        case .clientRejected:
            break
        }
        onEvent(.transport(event))
    }

    private func transition(to newState: VisionXServerState) {
        VisionXRuntimeLog.write("server state \(state) -> \(newState)")
        state = newState
        onEvent(.stateChanged(newState))
    }
}

private extension XTransportEvent {
    var summary: String {
        switch self {
        case .listening(let port):
            return "listening port=\(port)"
        case .failed(let reason):
            return "failed reason=\(reason)"
        case .clientAccepted(let info):
            return "clientAccepted endpoint=\(info.endpointDescription)"
        case .clientRejected(let endpointDescription, let reason):
            return "clientRejected endpoint=\(endpointDescription) reason=\(reason)"
        case .clientDisconnected(let id):
            return "clientDisconnected id=\(id)"
        }
    }
}
