// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Network)
@preconcurrency import Network
#endif

public struct XClientID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct XClientInfo: Equatable, Sendable {
    public var id: XClientID
    public var endpointDescription: String
    public var setup: X11SetupRequest?

    public init(id: XClientID, endpointDescription: String, setup: X11SetupRequest? = nil) {
        self.id = id
        self.endpointDescription = endpointDescription
        self.setup = setup
    }
}

public enum XTransportEvent: Equatable, Sendable {
    case listening(port: UInt16)
    case failed(String)
    case clientAccepted(XClientInfo)
    case clientRejected(endpointDescription: String, reason: String)
    case clientDisconnected(XClientID)
}

#if canImport(Network)
public final class DirectTCPXTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.visionx.tcp-transport")
    private var listener: NWListener?
    private var connections: [XClientID: NWConnection] = [:]
    private var authorizer: X11SetupAuthorizer

    public var onEvent: @Sendable (XTransportEvent) -> Void = { _ in }

    public init(cookie: MITMagicCookie?) {
        self.authorizer = X11SetupAuthorizer(requiredCookie: cookie)
    }

    deinit {
        stop()
    }

    public func start(port: UInt16 = 6000) throws {
        guard listener == nil else {
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw DirectTCPXTransportError.invalidPort(port)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state, port: port)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
        }
    }

    private func handleListenerState(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            onEvent(.listening(port: port))
        case .failed(let error):
            onEvent(.failed(error.localizedDescription))
        case .cancelled:
            break
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = XClientID()
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.connections.removeValue(forKey: id)
                self?.onEvent(.clientDisconnected(id))
            }
        }

        connection.start(queue: queue)
        receiveSetup(from: connection, id: id, buffer: Data())
    }

    private func receiveSetup(from connection: NWConnection, id: XClientID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.reject(connection, id: id, reason: error.localizedDescription)
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            switch self.authorizer.authorize(nextBuffer) {
            case .accepted(let setup):
                let info = XClientInfo(
                    id: id,
                    endpointDescription: String(describing: connection.endpoint),
                    setup: setup
                )
                self.onEvent(.clientAccepted(info))
            case .rejected(let reason):
                self.reject(connection, id: id, reason: reason)
            case .needMoreBytes(let minimumByteCount):
                if isComplete || nextBuffer.count > max(4096, minimumByteCount) {
                    self.reject(connection, id: id, reason: "incomplete X11 setup request")
                } else {
                    self.receiveSetup(from: connection, id: id, buffer: nextBuffer)
                }
            }
        }
    }

    private func reject(_ connection: NWConnection, id: XClientID, reason: String) {
        onEvent(.clientRejected(endpointDescription: String(describing: connection.endpoint), reason: reason))
        connections.removeValue(forKey: id)
        connection.cancel()
    }
}

public enum DirectTCPXTransportError: Error, Equatable {
    case invalidPort(UInt16)
}
#else
public final class DirectTCPXTransport {
    public var onEvent: @Sendable (XTransportEvent) -> Void = { _ in }

    public init(cookie: MITMagicCookie?) {}

    public func start(port: UInt16 = 6000) throws {
        throw DirectTCPXTransportError.networkFrameworkUnavailable
    }

    public func stop() {}
}

public enum DirectTCPXTransportError: Error, Equatable {
    case networkFrameworkUnavailable
}
#endif
