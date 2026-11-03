// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Testing
@testable import VisionXCore

@Suite
struct LocalNetworkIdentityTests {
    @Test
    func preferredTestingIPv4AddressUsesStableOrderingForNonLinkLocalAddresses() {
        let preferred = LocalNetworkIdentity.preferredTestingIPv4Address(
            from: ["198.51.100.20", "192.0.2.20"]
        )

        #expect(preferred == "192.0.2.20")
    }

    @Test
    func preferredTestingIPv4AddressUsesLinkLocalBeforeWifi() {
        let preferred = LocalNetworkIdentity.preferredTestingIPv4Address(
            from: ["192.0.2.20", "169.254.1.20"]
        )

        #expect(preferred == "169.254.1.20")
    }
}
