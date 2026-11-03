// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Security)
import Security
#endif

public enum XAuthorityError: Error, Equatable {
    case invalidHexLength
    case invalidHexDigit(String)
    case invalidCookieLength(Int)
}

public struct MITMagicCookie: Equatable, Hashable, Sendable {
    public static let byteCount = 16

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw XAuthorityError.invalidCookieLength(bytes.count)
        }
        self.bytes = bytes
    }

    public init(hexString: String) throws {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count % 2 == 0 else {
            throw XAuthorityError.invalidHexLength
        }

        var parsed: [UInt8] = []
        parsed.reserveCapacity(trimmed.count / 2)

        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            let pair = String(trimmed[index..<next])
            guard let byte = UInt8(pair, radix: 16) else {
                throw XAuthorityError.invalidHexDigit(pair)
            }
            parsed.append(byte)
            index = next
        }

        try self.init(bytes: parsed)
    }

    public static func generate() -> MITMagicCookie {
        var bytes = [UInt8](repeating: 0, count: Self.byteCount)

        #if canImport(Security)
        let status = bytes.withUnsafeMutableBytes { rawBuffer in
            SecRandomCopyBytes(kSecRandomDefault, Self.byteCount, rawBuffer.baseAddress!)
        }
        if status == errSecSuccess, let cookie = try? MITMagicCookie(bytes: bytes) {
            return cookie
        }
        #endif

        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return try! MITMagicCookie(bytes: bytes)
    }

    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct XDisplayEndpoint: Equatable, Sendable {
    public var host: String
    public var displayNumber: Int

    public init(host: String, displayNumber: Int = 0) {
        self.host = host
        self.displayNumber = displayNumber
    }

    public var port: Int {
        6000 + displayNumber
    }

    public var displayString: String {
        "\(host):\(displayNumber)"
    }
}

public struct XAuthorityCommand: Equatable, Sendable {
    public var endpoint: XDisplayEndpoint
    public var cookie: MITMagicCookie

    public init(endpoint: XDisplayEndpoint, cookie: MITMagicCookie) {
        self.endpoint = endpoint
        self.cookie = cookie
    }

    public var commandLine: String {
        "xauth add \(endpoint.displayString) MIT-MAGIC-COOKIE-1 \(cookie.hexString)"
    }
}
