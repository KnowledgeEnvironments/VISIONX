// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import CXOrgBridge
import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#endif

private let visionXXOrgConnectionTraceEnabled = ProcessInfo.processInfo.environment["VISIONX_XORG_CONNECTION_TRACE"] == "1"

#if canImport(Network)
@preconcurrency import Network

final class XOrgTCPBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clients: [UUID: BridgeClient] = [:]
    private var fdClients: [UUID: FileDescriptorBridgeClient] = [:]
    private var stopped = true

    func start(port: UInt16, bindAddress: String?) throws {
        lock.lock()
        defer { lock.unlock() }

        guard listenFD < 0 else {
            return
        }

        guard port > 0 else {
            throw XOrgTCPBridgeError.invalidPort(port)
        }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw XOrgTCPBridgeError.tcpSocketOperationFailed(operation: "socket", errno: errno)
        }

        do {
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

            try Self.bindTCPSocket(fd: fd, port: port, bindAddress: bindAddress)
            guard listen(fd, SOMAXCONN) == 0 else {
                throw XOrgTCPBridgeError.tcpSocketOperationFailed(operation: "listen", errno: errno)
            }
        } catch {
            Darwin.close(fd)
            throw error
        }

        listenFD = fd
        stopped = false
        Thread.detachNewThread { [self] in
            acceptLoop(fd: fd)
        }
        VisionXRuntimeLog.write("X.Org TCP bridge POSIX listening port=\(port) bind=\(bindAddress ?? "all")")
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        let bridgeClients = Array(clients.values)
        let descriptorClients = Array(fdClients.values)
        clients.removeAll()
        fdClients.removeAll()
        lock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for client in bridgeClients {
            client.close()
        }
        for client in descriptorClients {
            client.close()
        }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let acceptedFD = Darwin.accept(fd, nil, nil)
            if acceptedFD >= 0 {
                VisionXRuntimeLog.write("X.Org TCP bridge POSIX accepted fd=\(acceptedFD)")
                accept(acceptedFD)
                continue
            }

            let error = errno
            if isStopped || error == EBADF || error == EINVAL {
                break
            }
            if error != EINTR {
                VisionXRuntimeLog.write("X.Org TCP bridge POSIX accept failed errno=\(error)")
                usleep(100_000)
            }
        }
        VisionXRuntimeLog.write("X.Org TCP bridge POSIX accept loop stopped")
    }

    private var isStopped: Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }

    private func accept(_ appFD: Int32) {
        let stopped = isStopped
        VisionXRuntimeLog.write("X.Org TCP bridge POSIX adopting fd=\(appFD) stopped=\(stopped)")
        guard !stopped else {
            Darwin.close(appFD)
            return
        }

        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            VisionXRuntimeLog.write("X.Org TCP bridge socketpair failed errno=\(errno)")
            Darwin.close(appFD)
            return
        }

        let bridgeFD = fds[0]
        let xorgFD = fds[1]
        VisionXRuntimeLog.write("X.Org TCP bridge socketpair bridgeFD=\(bridgeFD) xorgFD=\(xorgFD)")
        guard visionx_ddx_add_client_fd(xorgFD) != 0 else {
            VisionXRuntimeLog.write("X.Org TCP bridge rejected X.Org client fd")
            Darwin.close(appFD)
            Darwin.close(bridgeFD)
            Darwin.close(xorgFD)
            return
        }
        VisionXRuntimeLog.write("X.Org TCP bridge queued X.Org client fd=\(xorgFD)")

        let client = FileDescriptorBridgeClient(networkFD: appFD, xorgFD: bridgeFD) { [weak self] id in
            self?.lock.lock()
            self?.fdClients.removeValue(forKey: id)
            self?.lock.unlock()
        }
        lock.lock()
        if stopped {
            lock.unlock()
            client.close()
            return
        }
        fdClients[client.id] = client
        lock.unlock()
        client.start()
    }

    private func accept(_ connection: NWConnection) {
        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            VisionXRuntimeLog.write("X.Org TCP bridge socketpair failed errno=\(errno)")
            connection.cancel()
            return
        }

        let bridgeFD = fds[0]
        let xorgFD = fds[1]
        VisionXRuntimeLog.write("X.Org TCP bridge socketpair bridgeFD=\(bridgeFD) xorgFD=\(xorgFD)")
        guard visionx_ddx_add_client_fd(xorgFD) != 0 else {
            VisionXRuntimeLog.write("X.Org TCP bridge rejected X.Org client fd")
            Darwin.close(bridgeFD)
            Darwin.close(xorgFD)
            connection.cancel()
            return
        }
        VisionXRuntimeLog.write("X.Org TCP bridge queued X.Org client fd=\(xorgFD)")

        let queue = DispatchQueue(label: "dev.visionx.xorg-tcp-bridge-client")
        let client = BridgeClient(connection: connection, fd: bridgeFD, queue: queue) { [weak self] id in
            self?.lock.lock()
            self?.clients.removeValue(forKey: id)
            self?.lock.unlock()
        }
        lock.lock()
        clients[client.id] = client
        lock.unlock()
        client.start()
    }

    private static func bindTCPSocket(fd: Int32, port: UInt16, bindAddress: String?) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        if let bindAddress,
           !bindAddress.isEmpty,
           bindAddress != "0.0.0.0" {
            var parsed = in_addr()
            guard inet_pton(AF_INET, bindAddress, &parsed) == 1 else {
                throw XOrgTCPBridgeError.tcpSocketOperationFailed(operation: "inet_pton", errno: EINVAL)
            }
            address.sin_addr = parsed
        } else {
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            throw XOrgTCPBridgeError.tcpSocketOperationFailed(operation: "bind", errno: errno)
        }
    }
}

final class XOrgReverseTCPBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.visionx.xorg-reverse-tcp-bridge")
    private var host = "127.0.0.1"
    private var port: UInt16 = 0
    private var targetChannelCount = 0
    private var clients: [UUID: FileDescriptorBridgeClient] = [:]
    private var stopped = true

    func start(host: String, port: UInt16, channelCount: Int) throws {
        guard port > 0 else {
            throw XOrgTCPBridgeError.invalidPort(port)
        }

        queue.sync {
            self.host = host
            self.port = port
            self.targetChannelCount = max(1, channelCount)
            self.stopped = false
            for _ in 0..<self.targetChannelCount {
                self.openChannel()
            }
        }
        VisionXRuntimeLog.write("X.Org reverse TCP bridge connecting host=\(host) port=\(port) channels=\(max(1, channelCount))")
    }

    func stop() {
        queue.sync {
            stopped = true
            for client in clients.values {
                client.close()
            }
            clients.removeAll()
        }
    }

    private func openChannel(after delay: TimeInterval = 0) {
        guard !stopped else {
            return
        }

        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.openChannel()
            }
            return
        }

        VisionXRuntimeLog.write("X.Org reverse TCP bridge opening fd channel host=\(host) port=\(port)")
        guard let networkFD = Self.connectSocket(host: host, port: port) else {
            openChannel(after: 0.5)
            return
        }
        VisionXRuntimeLog.write("X.Org reverse TCP bridge connected fd=\(networkFD) host=\(host) port=\(port)")

        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            VisionXRuntimeLog.write("X.Org reverse TCP bridge socketpair failed errno=\(errno)")
            Darwin.close(networkFD)
            openChannel(after: 0.5)
            return
        }

        let bridgeFD = fds[0]
        let xorgFD = fds[1]
        VisionXRuntimeLog.write("X.Org reverse TCP bridge socketpair bridgeFD=\(bridgeFD) xorgFD=\(xorgFD)")
        guard visionx_ddx_add_client_fd(xorgFD) != 0 else {
            VisionXRuntimeLog.write("X.Org reverse TCP bridge rejected X.Org client fd")
            Darwin.close(networkFD)
            Darwin.close(bridgeFD)
            Darwin.close(xorgFD)
            openChannel(after: 0.5)
            return
        }
        VisionXRuntimeLog.write("X.Org reverse TCP bridge queued X.Org client fd=\(xorgFD)")

        let client = FileDescriptorBridgeClient(
            networkFD: networkFD,
            xorgFD: bridgeFD,
            initialNetworkIdleTimeoutMS: Self.initialNetworkIdleTimeoutMS
        ) { [weak self] id in
            guard let self else {
                return
            }
            self.queue.async {
                self.clients.removeValue(forKey: id)
                self.openChannel(after: 0.1)
            }
        }
        clients[client.id] = client
        client.start()
    }

    private static func connectSocket(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var results: UnsafeMutablePointer<addrinfo>?
        let service = String(port)
        let lookupStatus = getaddrinfo(host, service, &hints, &results)
        guard lookupStatus == 0, let results else {
            VisionXRuntimeLog.write("X.Org reverse TCP bridge getaddrinfo failed host=\(host) port=\(port) status=\(lookupStatus)")
            return nil
        }
        defer {
            freeaddrinfo(results)
        }

        var result: UnsafeMutablePointer<addrinfo>? = results
        while let current = result {
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd >= 0 {
                var enabled: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
#if canImport(Darwin)
                _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
#endif
                if connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                    return fd
                }
                let connectErrno = errno
                Darwin.close(fd)
                VisionXRuntimeLog.write("X.Org reverse TCP bridge connect failed host=\(host) port=\(port) errno=\(connectErrno)")
            }
            result = current.pointee.ai_next
        }
        return nil
    }

    private static var initialNetworkIdleTimeoutMS: Int32? {
#if targetEnvironment(simulator)
        return 1000
#else
        return nil
#endif
    }
}

final class XOrgUnixSocketBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var socketPath: String?
    private var clients: [UUID: FileDescriptorBridgeClient] = [:]
    private var stopped = true

    func start(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD < 0 else {
            return
        }

        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw XOrgTCPBridgeError.unixSocketOperationFailed(operation: "socket", errno: errno)
        }

        do {
            try Self.bindUnixSocket(fd: fd, path: path)
            guard listen(fd, SOMAXCONN) == 0 else {
                throw XOrgTCPBridgeError.unixSocketOperationFailed(operation: "listen", errno: errno)
            }
        } catch {
            Darwin.close(fd)
            throw error
        }

        listenFD = fd
        socketPath = path
        stopped = false
        Thread.detachNewThread { [self] in
            acceptLoop(fd: fd)
        }
        VisionXRuntimeLog.write("X.Org Unix socket bridge listening path=\(path)")
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        let path = socketPath
        socketPath = nil
        let clientsToClose = Array(clients.values)
        clients.removeAll()
        lock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for client in clientsToClose {
            client.close()
        }
        if let path {
            unlink(path)
        }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let acceptedFD = Darwin.accept(fd, nil, nil)
            if acceptedFD >= 0 {
                accept(acceptedFD)
                continue
            }

            let error = errno
            if isStopped || error == EBADF || error == EINVAL {
                break
            }
            if error != EINTR {
                VisionXRuntimeLog.write("X.Org Unix socket bridge accept failed errno=\(error)")
                usleep(100_000)
            }
        }
        VisionXRuntimeLog.write("X.Org Unix socket bridge accept loop stopped")
    }

    private var isStopped: Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }

    private func accept(_ appFD: Int32) {
        guard !isStopped else {
            Darwin.close(appFD)
            return
        }

        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            VisionXRuntimeLog.write("X.Org Unix socket bridge socketpair failed errno=\(errno)")
            Darwin.close(appFD)
            return
        }

        let bridgeFD = fds[0]
        let xorgFD = fds[1]
        VisionXRuntimeLog.write("X.Org Unix socket bridge socketpair bridgeFD=\(bridgeFD) xorgFD=\(xorgFD)")
        guard visionx_ddx_add_client_fd(xorgFD) != 0 else {
            VisionXRuntimeLog.write("X.Org Unix socket bridge rejected X.Org client fd")
            Darwin.close(appFD)
            Darwin.close(bridgeFD)
            Darwin.close(xorgFD)
            return
        }
        VisionXRuntimeLog.write("X.Org Unix socket bridge queued X.Org client fd=\(xorgFD)")

        let client = FileDescriptorBridgeClient(networkFD: appFD, xorgFD: bridgeFD) { [weak self] id in
            self?.lock.lock()
            self?.clients.removeValue(forKey: id)
            self?.lock.unlock()
        }
        lock.lock()
        if stopped {
            lock.unlock()
            client.close()
            return
        }
        clients[client.id] = client
        lock.unlock()
        client.start()
    }

    private static func bindUnixSocket(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            throw XOrgTCPBridgeError.invalidUnixSocketPath(path)
        }

        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { pathPointer in
            withUnsafeMutablePointer(to: &address.sun_path) { sunPathPointer in
                sunPathPointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    strncpy(destination, pathPointer, maxPathLength)
                }
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addressLength = socklen_t(pathOffset + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, addressLength)
            }
        }
        guard result == 0 else {
            throw XOrgTCPBridgeError.unixSocketOperationFailed(operation: "bind", errno: errno)
        }
    }
}

enum XOrgTCPBridgeError: Error, Equatable, LocalizedError {
    case invalidPort(UInt16)
    case invalidUnixSocketPath(String)
    case tcpSocketOperationFailed(operation: String, errno: Int32)
    case unixSocketOperationFailed(operation: String, errno: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid TCP port \(port)"
        case .invalidUnixSocketPath(let path):
            return "Unix socket path is too long: \(path)"
        case .tcpSocketOperationFailed(let operation, let errno):
            return "TCP socket \(operation) failed errno=\(errno)"
        case .unixSocketOperationFailed(let operation, let errno):
            return "Unix socket \(operation) failed errno=\(errno)"
        }
    }
}

private final class FileDescriptorBridgeClient: @unchecked Sendable {
    let id: UUID

    private let networkFD: Int32
    private let xorgFD: Int32
    private let initialNetworkIdleTimeoutMS: Int32?
    private let onClose: @Sendable (UUID) -> Void
    private let closeLock = NSLock()
    private var closed = false

    init(
        networkFD: Int32,
        xorgFD: Int32,
        initialNetworkIdleTimeoutMS: Int32? = nil,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        let clientID = UUID()
        self.id = clientID
        self.networkFD = networkFD
        self.xorgFD = xorgFD
        self.initialNetworkIdleTimeoutMS = initialNetworkIdleTimeoutMS
        self.onClose = onClose
    }

    func start() {
        setNoSigPipe(networkFD)
        setNoSigPipe(xorgFD)
        setNonblocking(networkFD)
        setNonblocking(xorgFD)
        VisionXRuntimeLog.write("X.Org reverse TCP bridge fd client started id=\(id.uuidString)")

        Thread.detachNewThread { [self] in
            pump(from: networkFD, to: xorgFD, label: "network->X.Org")
        }
        Thread.detachNewThread { [self] in
            pump(from: xorgFD, to: networkFD, label: "X.Org->network")
        }
    }

    func close() {
        closeLock.lock()
        let shouldClose = !closed
        closed = true
        closeLock.unlock()

        guard shouldClose else {
            return
        }
        shutdown(networkFD, SHUT_RDWR)
        shutdown(xorgFD, SHUT_RDWR)
        Darwin.close(networkFD)
        Darwin.close(xorgFD)
        onClose(id)
    }

    private func pump(from sourceFD: Int32, to destinationFD: Int32, label: String) {
        VisionXRuntimeLog.write("X.Org reverse TCP bridge fd client pump started label=\(label) id=\(id.uuidString)")
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let initialIdleDeadline = label == "network->X.Org"
            ? initialNetworkIdleTimeoutMS.map { DispatchTime.now() + .milliseconds(Int($0)) }
            : nil
        var sawBytes = false
        while !isClosed {
            _ = waitForFD(sourceFD, events: Int16(POLLIN | POLLERR | POLLHUP), timeoutMS: 4)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return 0
                }
                return read(sourceFD, baseAddress, rawBuffer.count)
            }

            if count > 0 {
                sawBytes = true
                if visionXXOrgConnectionTraceEnabled {
                    VisionXRuntimeLog.write("X.Org reverse TCP bridge fd client \(label) bytes=\(count) id=\(id.uuidString)")
                }
                if !writeAll(buffer: buffer, count: count, to: destinationFD) {
                    VisionXRuntimeLog.write("X.Org reverse TCP bridge fd client write failed label=\(label) errno=\(errno) id=\(id.uuidString)")
                    break
                }
            } else if count == 0 {
                VisionXRuntimeLog.write("X.Org reverse TCP bridge fd client closed label=\(label) id=\(id.uuidString)")
                break
            } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                if !sawBytes,
                   let initialIdleDeadline,
                   DispatchTime.now() >= initialIdleDeadline {
                    VisionXRuntimeLog.write("X.Org reverse TCP bridge fd client initial idle timeout label=\(label) id=\(id.uuidString)")
                    break
                }
                continue
            } else {
                VisionXRuntimeLog.write("X.Org reverse TCP bridge fd client read failed label=\(label) errno=\(errno) id=\(id.uuidString)")
                break
            }
        }
        close()
    }

    private var isClosed: Bool {
        closeLock.lock()
        let value = closed
        closeLock.unlock()
        return value
    }

    private func writeAll(buffer: [UInt8], count: Int, to fd: Int32) -> Bool {
        buffer.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return true
            }

            var offset = 0
            while offset < count {
                let written = write(fd, baseAddress.advanced(by: offset), count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    if !waitUntilWritable(fd) {
                        return false
                    }
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func waitUntilWritable(_ fd: Int32) -> Bool {
        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0)
        while !isClosed {
            pollDescriptor.revents = 0
            let result = Darwin.poll(&pollDescriptor, 1, 1000)
            if result > 0 {
                if (pollDescriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                    return false
                }
                if (pollDescriptor.revents & Int16(POLLOUT)) != 0 {
                    return true
                }
                continue
            }
            if result == 0 {
                continue
            }
            if errno == EINTR {
                continue
            }
            return false
        }
        return false
    }

    private func waitForFD(_ fd: Int32, events: Int16, timeoutMS: Int32) -> Bool {
        var pollDescriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let result = Darwin.poll(&pollDescriptor, 1, timeoutMS)
            if result > 0 {
                return (pollDescriptor.revents & events) != 0
            }
            if result == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }
            return false
        }
    }

    private func setNoSigPipe(_ fd: Int32) {
        var value: Int32 = 1
        _ = withUnsafePointer(to: &value) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    private func setNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }
}

private final class BridgeClient: @unchecked Sendable {
    let id = UUID()

    private let connection: NWConnection
    private let fd: Int32
    private let queue: DispatchQueue
    private let onClose: @Sendable (UUID) -> Void
    private let startConnection: Bool
    private var readSource: DispatchSourceRead?
    private var closed = false

    init(
        connection: NWConnection,
        fd: Int32,
        queue: DispatchQueue,
        startConnection: Bool = true,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.connection = connection
        self.fd = fd
        self.queue = queue
        self.onClose = onClose
        self.startConnection = startConnection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                VisionXRuntimeLog.write("X.Org TCP bridge client ready id=\(self?.id.uuidString ?? "nil")")
            case .waiting(let error):
                VisionXRuntimeLog.write("X.Org TCP bridge client waiting id=\(self?.id.uuidString ?? "nil") error=\(error.localizedDescription)")
            case .failed, .cancelled:
                VisionXRuntimeLog.write("X.Org TCP bridge client closed id=\(self?.id.uuidString ?? "nil") state=\(state)")
                self?.close()
            default:
                break
            }
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readFromXOrg()
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        readSource = source
        source.resume()

        if startConnection {
            connection.start(queue: queue)
        }
        receiveFromNetwork()
    }

    func close() {
        guard !closed else {
            return
        }
        closed = true
        readSource?.cancel()
        readSource = nil
        connection.cancel()
        onClose(id)
    }

    private func receiveFromNetwork() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else {
                return
            }
            if let data, !data.isEmpty, !self.writeAll(data) {
                VisionXRuntimeLog.write("X.Org TCP bridge client write to X.Org failed id=\(self.id.uuidString) bytes=\(data.count) errno=\(errno)")
                self.close()
                return
            }
            if let data, !data.isEmpty {
                if visionXXOrgConnectionTraceEnabled {
                    VisionXRuntimeLog.write("X.Org TCP bridge client received network bytes id=\(self.id.uuidString) bytes=\(data.count)")
                }
            }
            if error != nil || isComplete {
                VisionXRuntimeLog.write("X.Org TCP bridge client receive ended id=\(self.id.uuidString) complete=\(isComplete) error=\(String(describing: error))")
                self.close()
                return
            }
            self.receiveFromNetwork()
        }
    }

    private func readFromXOrg() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            let data = Data(buffer.prefix(count))
            if visionXXOrgConnectionTraceEnabled {
                VisionXRuntimeLog.write("X.Org TCP bridge client read X.Org bytes id=\(id.uuidString) bytes=\(count)")
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    VisionXRuntimeLog.write("X.Org TCP bridge client send failed id=\(self?.id.uuidString ?? "nil") error=\(String(describing: error))")
                    self?.close()
                }
            })
        } else if count == 0 {
            VisionXRuntimeLog.write("X.Org TCP bridge client X.Org fd closed id=\(id.uuidString)")
            close()
        } else if errno != EINTR {
            VisionXRuntimeLog.write("X.Org TCP bridge client X.Org read failed id=\(id.uuidString) errno=\(errno)")
            close()
        }
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return true
            }

            var offset = 0
            while offset < rawBuffer.count {
                let written = write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
#else
final class XOrgTCPBridge: @unchecked Sendable {
    func start(port: UInt16, bindAddress: String?) throws {
        throw XOrgTCPBridgeError.unavailable
    }

    func stop() {}
}

final class XOrgReverseTCPBridge: @unchecked Sendable {
    func start(host: String, port: UInt16, channelCount: Int) throws {
        throw XOrgTCPBridgeError.unavailable
    }

    func stop() {}
}

final class XOrgUnixSocketBridge: @unchecked Sendable {
    func start(path: String) throws {
        throw XOrgTCPBridgeError.unavailable
    }

    func stop() {}
}

enum XOrgTCPBridgeError: Error, Equatable, LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Network.framework is unavailable"
    }
}
#endif
