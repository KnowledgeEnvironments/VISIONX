// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

public enum XPointerButton: UInt8, Equatable, Sendable {
    case primary = 1
    case middle = 2
    case secondary = 3
    case scrollUp = 4
    case scrollDown = 5
}

public struct XPointerEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case motion
        case buttonPress(XPointerButton)
        case buttonRelease(XPointerButton)
        case enter
        case leave
    }

    public var window: XID
    public var kind: Kind
    public var x: Int
    public var y: Int

    public init(window: XID, kind: Kind, x: Int, y: Int) {
        self.window = window
        self.kind = kind
        self.x = x
        self.y = y
    }
}

public struct XKeyboardEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyPress
        case keyRelease
    }

    public var window: XID
    public var kind: Kind
    public var keycode: UInt8
    public var modifiers: UInt32

    public init(window: XID, kind: Kind, keycode: UInt8, modifiers: UInt32 = 0) {
        self.window = window
        self.kind = kind
        self.keycode = keycode
        self.modifiers = modifiers
    }
}

public struct XPointerVisualTransform: Equatable, Sendable {
    public static let identity = XPointerVisualTransform()

    public var curvatureIntensity: CGFloat
    public var warbleIntensity: CGFloat
    public var time: TimeInterval

    public init(
        curvatureIntensity: CGFloat = 0,
        warbleIntensity: CGFloat = 0,
        time: TimeInterval = 0
    ) {
        self.curvatureIntensity = min(max(curvatureIntensity, 0), 1)
        self.warbleIntensity = min(max(warbleIntensity, 0), 1)
        self.time = time
    }

    public func sourcePoint(for panelPoint: CGPoint, in panelSize: CGSize) -> CGPoint {
        guard panelSize.width > 0, panelSize.height > 0 else {
            return .zero
        }
        guard curvatureIntensity > 0 || warbleIntensity > 0 else {
            return panelPoint
        }

        let uvX = min(max(panelPoint.x / panelSize.width, 0), 1)
        let uvY = min(max(panelPoint.y / panelSize.height, 0), 1)
        let centeredX = uvX * 2 - 1
        let centeredY = uvY * 2 - 1
        let radiusSquared = centeredX * centeredX + centeredY * centeredY
        let curvature = curvatureIntensity * 0.16
        let distortion = 1 + radiusSquared * curvature

        var sourceX = (centeredX * distortion) * 0.5 + 0.5
        var sourceY = (centeredY * distortion) * 0.5 + 0.5

        let t = CGFloat(time)
        let wave = sin(t * 0.7 + uvY * 8.0) * 0.0007
            + sin(t * 1.3 + uvY * 2.0) * 0.0009
            + sin(t * 0.2) * sin(uvY * 25.0 + t * 3.0) * 0.0004
        sourceX += wave * warbleIntensity * 3.0

        sourceX = min(max(sourceX, 0), 1)
        sourceY = min(max(sourceY, 0), 1)
        return CGPoint(x: sourceX * panelSize.width, y: sourceY * panelSize.height)
    }
}

public struct XInputTranslator: Sendable {
    public init() {}

    public func pointerEvent(
        window: XID,
        kind: XPointerEvent.Kind,
        panelPoint: CGPoint,
        panelSize: CGSize,
        xWindowSize: CGSize,
        visualTransform: XPointerVisualTransform = .identity
    ) -> XPointerEvent {
        let sourcePoint = visualTransform.sourcePoint(for: panelPoint, in: panelSize)
        let x = scale(sourcePoint.x, fromExtent: panelSize.width, toExtent: xWindowSize.width)
        let y = scale(sourcePoint.y, fromExtent: panelSize.height, toExtent: xWindowSize.height)
        return XPointerEvent(window: window, kind: kind, x: x, y: y)
    }

    public func scrollEvents(
        window: XID,
        deltaY: CGFloat,
        panelPoint: CGPoint,
        panelSize: CGSize,
        xWindowSize: CGSize,
        visualTransform: XPointerVisualTransform = .identity
    ) -> [XPointerEvent] {
        guard deltaY != 0 else {
            return []
        }

        let button: XPointerButton = deltaY > 0 ? .scrollUp : .scrollDown
        let press = pointerEvent(
            window: window,
            kind: .buttonPress(button),
            panelPoint: panelPoint,
            panelSize: panelSize,
            xWindowSize: xWindowSize,
            visualTransform: visualTransform
        )
        let release = XPointerEvent(window: window, kind: .buttonRelease(button), x: press.x, y: press.y)
        return [press, release]
    }

    private func scale(_ value: CGFloat, fromExtent: CGFloat, toExtent: CGFloat) -> Int {
        guard fromExtent > 0, toExtent > 0 else {
            return 0
        }
        let normalized = min(max(value / fromExtent, 0), 1)
        return Int((normalized * (toExtent - 1)).rounded(.towardZero))
    }
}
