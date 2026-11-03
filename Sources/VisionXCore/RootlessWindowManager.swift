// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics

public typealias XID = UInt32

public struct XRectangle: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int = 0, y: Int = 0, width: Int = 1, height: Int = 1) {
        self.x = x
        self.y = y
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct WMClass: Equatable, Sendable {
    public var instance: String
    public var className: String

    public init(instance: String = "", className: String = "") {
        self.instance = instance
        self.className = className
    }
}

public struct WMNormalHints: Equatable, Sendable {
    public var minimumSize: CGSize?
    public var maximumSize: CGSize?
    public var resizeIncrement: CGSize?
    public var baseSize: CGSize?

    public init(
        minimumSize: CGSize? = nil,
        maximumSize: CGSize? = nil,
        resizeIncrement: CGSize? = nil,
        baseSize: CGSize? = nil
    ) {
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.resizeIncrement = resizeIncrement
        self.baseSize = baseSize
    }
}

public enum WMProtocol: String, Equatable, Sendable {
    case deleteWindow = "WM_DELETE_WINDOW"
    case takeFocus = "WM_TAKE_FOCUS"
}

public enum XWindowRoute: Hashable, CaseIterable, Sendable {
    case nativeWindow
    case immersivePanel
    case overrideRedirect
}

public enum XWindowMapState: Equatable, Sendable {
    case unmapped
    case mapped
}

public struct XTopLevelWindow: Identifiable, Equatable, Sendable {
    public var id: XID
    public var title: String
    public var wmClass: WMClass
    public var normalHints: WMNormalHints
    public var protocols: Set<WMProtocol>
    public var transientFor: XID?
    public var overrideRedirect: Bool
    public var frame: XRectangle
    public var route: XWindowRoute
    public var mapState: XWindowMapState
    public var damageSerial: UInt64
    public var lastDamageRect: XRectangle?

    public init(
        id: XID,
        title: String = "",
        wmClass: WMClass = WMClass(),
        normalHints: WMNormalHints = WMNormalHints(),
        protocols: Set<WMProtocol> = [],
        transientFor: XID? = nil,
        overrideRedirect: Bool = false,
        frame: XRectangle = XRectangle(),
        mapState: XWindowMapState = .unmapped,
        damageSerial: UInt64 = 0,
        lastDamageRect: XRectangle? = nil
    ) {
        self.id = id
        self.title = title
        self.wmClass = wmClass
        self.normalHints = normalHints
        self.protocols = protocols
        self.transientFor = transientFor
        self.overrideRedirect = overrideRedirect
        self.frame = frame
        self.route = overrideRedirect ? .overrideRedirect : .nativeWindow
        self.mapState = mapState
        self.damageSerial = damageSerial
        self.lastDamageRect = lastDamageRect
    }
}

public enum XWindowManagerEvent: Equatable, Sendable {
    case created(XTopLevelWindow)
    case mapped(XTopLevelWindow)
    case unmapped(XID)
    case configured(XTopLevelWindow)
    case destroyed(XID)
    case focused(XID)
    case closeRequestedByVisionOS(XID)
    case clientMessage(window: XID, protocolName: WMProtocol)
    case killClientRequested(window: XID)
    case damage(window: XID, serial: UInt64, rect: XRectangle?)
}

public final class RootlessWindowManager: @unchecked Sendable {
    public private(set) var windows: [XID: XTopLevelWindow] = [:]
    public private(set) var focusedWindow: XID?

    public var onEvent: @Sendable (XWindowManagerEvent) -> Void = { _ in }

    public init() {}

    @discardableResult
    public func upsertTopLevel(_ window: XTopLevelWindow) -> XTopLevelWindow {
        var normalized = window
        normalized.route = route(for: normalized)
        windows[window.id] = normalized
        onEvent(.created(normalized))
        return normalized
    }

    public func destroy(window id: XID) {
        windows.removeValue(forKey: id)
        if focusedWindow == id {
            focusedWindow = nil
        }
        onEvent(.destroyed(id))
    }

    public func destroyAllWindows() {
        let ids = windows.keys.sorted()
        guard !ids.isEmpty else {
            return
        }

        windows.removeAll()
        focusedWindow = nil
        for id in ids {
            onEvent(.destroyed(id))
        }
    }

    public func map(window id: XID) {
        guard var window = windows[id] else {
            return
        }
        window.mapState = .mapped
        windows[id] = window
        onEvent(.mapped(window))
    }

    public func unmap(window id: XID) {
        guard var window = windows[id] else {
            return
        }
        window.mapState = .unmapped
        windows[id] = window
        if focusedWindow == id {
            focusedWindow = nil
        }
        onEvent(.unmapped(id))
    }

    public func configure(window id: XID, frame: XRectangle) {
        guard var window = windows[id] else {
            return
        }
        window.frame = frame
        windows[id] = window
        onEvent(.configured(window))
    }

    public func updateProperties(
        window id: XID,
        title: String? = nil,
        wmClass: WMClass? = nil,
        normalHints: WMNormalHints? = nil,
        protocols: Set<WMProtocol>? = nil,
        transientFor: XID?? = nil
    ) {
        guard var window = windows[id] else {
            return
        }
        if let title {
            window.title = title
        }
        if let wmClass {
            window.wmClass = wmClass
        }
        if let normalHints {
            window.normalHints = normalHints
        }
        if let protocols {
            window.protocols = protocols
        }
        if let transientFor {
            window.transientFor = transientFor
        }
        window.route = route(for: window)
        windows[id] = window
        onEvent(.configured(window))
    }

    public func route(window id: XID, to route: XWindowRoute) {
        guard var window = windows[id] else {
            return
        }
        window.route = window.overrideRedirect ? .overrideRedirect : route
        windows[id] = window
        onEvent(.configured(window))
    }

    public func focus(window id: XID) {
        guard windows[id] != nil else {
            return
        }
        guard focusedWindow != id else {
            return
        }
        focusedWindow = id
        onEvent(.focused(id))
    }

    public func requestCloseFromVisionOS(window id: XID) {
        guard let window = windows[id] else {
            return
        }
        onEvent(.closeRequestedByVisionOS(id))
        if window.protocols.contains(.deleteWindow) {
            onEvent(.clientMessage(window: id, protocolName: .deleteWindow))
        } else {
            onEvent(.killClientRequested(window: id))
        }
    }

    public func markDamage(window id: XID, rect: XRectangle? = nil) {
        guard var window = windows[id] else {
            return
        }
        window.damageSerial += 1
        window.lastDamageRect = rect
        windows[id] = window
        onEvent(.damage(window: id, serial: window.damageSerial, rect: rect))
    }

    private func route(for window: XTopLevelWindow) -> XWindowRoute {
        if window.overrideRedirect {
            return .overrideRedirect
        }
        if window.transientFor != nil {
            return .nativeWindow
        }
        return window.route
    }
}
