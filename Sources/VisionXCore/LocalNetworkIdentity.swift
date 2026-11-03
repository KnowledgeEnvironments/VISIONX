// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum LocalNetworkIdentity {
    public static func localIPv4Addresses() -> [String] {
        #if canImport(Darwin)
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback else {
                continue
            }

            let address = interface.pointee.ifa_addr
            guard address?.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var socketAddress = address!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            let string = buffer.withUnsafeBufferPointer { pointer in
                String(cString: pointer.baseAddress!)
            }
            if !string.isEmpty {
                addresses.append(string)
            }
        }

        var seen = Set<String>()
        return addresses.filter { seen.insert($0).inserted }
        #else
        return []
        #endif
    }

    public static func preferredTestingIPv4Address() -> String? {
        preferredTestingIPv4Address(from: localIPv4Addresses())
    }

    public static func sortedTestingIPv4Addresses(_ addresses: [String]) -> [String] {
        addresses.sorted { left, right in
            testingAddressRank(left) < testingAddressRank(right)
        }
    }

    public static func preferredTestingIPv4Address(from addresses: [String]) -> String? {
        sortedTestingIPv4Addresses(addresses).first
    }

    private static func testingAddressRank(_ address: String) -> (Int, String) {
        if address.hasPrefix("169.254.") {
            return (0, address)
        }
        return (1, address)
    }
}
