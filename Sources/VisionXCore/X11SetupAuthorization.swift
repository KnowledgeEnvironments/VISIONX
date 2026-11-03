// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

public enum X11ByteOrder: UInt8, Sendable {
    case bigEndian = 0x42
    case littleEndian = 0x6c
}

public struct X11SetupRequest: Equatable, Sendable {
    public var byteOrder: X11ByteOrder
    public var protocolMajor: UInt16
    public var protocolMinor: UInt16
    public var authorizationName: String
    public var authorizationData: [UInt8]

    public init(
        byteOrder: X11ByteOrder,
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        authorizationName: String,
        authorizationData: [UInt8]
    ) {
        self.byteOrder = byteOrder
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.authorizationName = authorizationName
        self.authorizationData = authorizationData
    }
}

public enum X11SetupAuthorizationResult: Equatable, Sendable {
    case needMoreBytes(minimumByteCount: Int)
    case accepted(X11SetupRequest)
    case rejected(String)
}

public struct X11SetupAuthorizer: Sendable {
    public static let authorizationName = "MIT-MAGIC-COOKIE-1"

    public var requiredCookie: MITMagicCookie?

    public init(requiredCookie: MITMagicCookie?) {
        self.requiredCookie = requiredCookie
    }

    public func authorize(_ bytes: Data) -> X11SetupAuthorizationResult {
        guard bytes.count >= 12 else {
            return .needMoreBytes(minimumByteCount: 12)
        }

        guard let byteOrder = X11ByteOrder(rawValue: bytes[0]) else {
            return .rejected("unsupported X11 byte order 0x\(String(bytes[0], radix: 16))")
        }

        let major = readUInt16(bytes, offset: 2, order: byteOrder)
        let minor = readUInt16(bytes, offset: 4, order: byteOrder)
        guard major == 11 else {
            return .rejected("unsupported X11 protocol \(major).\(minor)")
        }

        let nameLength = Int(readUInt16(bytes, offset: 6, order: byteOrder))
        let dataLength = Int(readUInt16(bytes, offset: 8, order: byteOrder))
        let nameOffset = 12
        let dataOffset = nameOffset + paddedLength(nameLength)
        let totalLength = dataOffset + paddedLength(dataLength)

        guard bytes.count >= totalLength else {
            return .needMoreBytes(minimumByteCount: totalLength)
        }

        guard let name = String(
            data: bytes.subdata(in: nameOffset..<(nameOffset + nameLength)),
            encoding: .ascii
        ) else {
            return .rejected("authorization name is not ASCII")
        }

        let authData = Array(bytes[(dataOffset)..<(dataOffset + dataLength)])
        let request = X11SetupRequest(
            byteOrder: byteOrder,
            protocolMajor: major,
            protocolMinor: minor,
            authorizationName: name,
            authorizationData: authData
        )

        guard let requiredCookie else {
            return .accepted(request)
        }

        guard name == Self.authorizationName else {
            return .rejected("authorization protocol \(name.isEmpty ? "<none>" : name) is not supported")
        }

        guard authData == requiredCookie.bytes else {
            return .rejected("authorization cookie mismatch")
        }

        return .accepted(request)
    }

    private func readUInt16(_ data: Data, offset: Int, order: X11ByteOrder) -> UInt16 {
        let first = UInt16(data[offset])
        let second = UInt16(data[offset + 1])
        switch order {
        case .bigEndian:
            return (first << 8) | second
        case .littleEndian:
            return first | (second << 8)
        }
    }

    private func paddedLength(_ length: Int) -> Int {
        (length + 3) & ~3
    }
}
