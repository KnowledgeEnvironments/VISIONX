// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VisionXCore

@Test
func magicCookieRoundTripsThroughHexAndXauthCommand() throws {
    let cookie = try MITMagicCookie(hexString: "00112233445566778899aabbccddeeff")
    #expect(cookie.hexString == "00112233445566778899aabbccddeeff")

    let command = XAuthorityCommand(
        endpoint: XDisplayEndpoint(host: "192.0.2.20", displayNumber: 0),
        cookie: cookie
    )
    #expect(command.commandLine == "xauth add 192.0.2.20:0 MIT-MAGIC-COOKIE-1 00112233445566778899aabbccddeeff")
}

@Test
func setupAuthorizerAcceptsLittleEndianMITMagicCookie() throws {
    let cookie = try MITMagicCookie(hexString: "00112233445566778899aabbccddeeff")
    let request = makeSetupRequest(
        order: .littleEndian,
        name: X11SetupAuthorizer.authorizationName,
        data: cookie.bytes
    )

    let result = X11SetupAuthorizer(requiredCookie: cookie).authorize(request)

    guard case .accepted(let setup) = result else {
        Issue.record("expected accepted setup, got \(result)")
        return
    }
    #expect(setup.byteOrder == .littleEndian)
    #expect(setup.protocolMajor == 11)
    #expect(setup.authorizationData == cookie.bytes)
}

@Test
func setupAuthorizerRejectsWrongCookie() throws {
    let required = try MITMagicCookie(hexString: "00112233445566778899aabbccddeeff")
    let supplied = try MITMagicCookie(hexString: "ffeeddccbbaa99887766554433221100")
    let request = makeSetupRequest(
        order: .bigEndian,
        name: X11SetupAuthorizer.authorizationName,
        data: supplied.bytes
    )

    let result = X11SetupAuthorizer(requiredCookie: required).authorize(request)
    #expect(result == .rejected("authorization cookie mismatch"))
}

@Test
func setupAuthorizerAcceptsUnauthenticatedSetupWhenCookieIsNotRequired() {
    let request = makeSetupRequest(order: .littleEndian, name: "", data: [])

    let result = X11SetupAuthorizer(requiredCookie: nil).authorize(request)

    guard case .accepted(let setup) = result else {
        Issue.record("expected accepted setup, got \(result)")
        return
    }
    #expect(setup.authorizationName.isEmpty)
    #expect(setup.authorizationData.isEmpty)
}

@Test
func serverControllerDefaultsToMITMagicCookieAuthentication() {
    let server = VisionXServerController()

    #expect(server.configuration.requireMITMagicCookie == true)
}

@Test
func serverControllerCanSwitchToXhostPlusModeWhileStopped() {
    let server = VisionXServerController()

    server.setRequireMITMagicCookie(false)

    #expect(server.configuration.requireMITMagicCookie == false)
}

@Test
func xorgBridgeReportsPinnedServerVersion() {
    #expect(XOrgBridge.expectedServerVersion == "21.1.25")
    #expect(XOrgBridge.ddxVersion.contains("xorg-server/21.1.25"))
}

private func makeSetupRequest(order: X11ByteOrder, name: String, data: [UInt8]) -> Data {
    var bytes = Data()
    bytes.append(order.rawValue)
    bytes.append(0)
    appendUInt16(11, to: &bytes, order: order)
    appendUInt16(0, to: &bytes, order: order)
    appendUInt16(UInt16(name.utf8.count), to: &bytes, order: order)
    appendUInt16(UInt16(data.count), to: &bytes, order: order)
    appendUInt16(0, to: &bytes, order: order)
    bytes.append(contentsOf: name.utf8)
    appendPadding(to: &bytes)
    bytes.append(contentsOf: data)
    appendPadding(to: &bytes)
    return bytes
}

private func appendUInt16(_ value: UInt16, to data: inout Data, order: X11ByteOrder) {
    switch order {
    case .bigEndian:
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    case .littleEndian:
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }
}

private func appendPadding(to data: inout Data) {
    while data.count % 4 != 0 {
        data.append(0)
    }
}
