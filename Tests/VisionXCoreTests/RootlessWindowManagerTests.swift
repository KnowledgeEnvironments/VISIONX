// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import CoreGraphics
import Testing
@testable import VisionXCore

@Test
func rootlessWindowManagerEmitsDeleteWindowClientMessageWhenSupported() {
    let manager = RootlessWindowManager()
    let recorder = WindowEventRecorder()
    manager.onEvent = { recorder.events.append($0) }

    _ = manager.upsertTopLevel(
        XTopLevelWindow(
            id: 42,
            title: "xterm",
            protocols: [.deleteWindow],
            frame: XRectangle(x: 10, y: 20, width: 640, height: 480)
        )
    )

    manager.map(window: 42)
    manager.requestCloseFromVisionOS(window: 42)

    #expect(recorder.events.contains(.mapped(manager.windows[42]!)))
    #expect(recorder.events.contains(.clientMessage(window: 42, protocolName: .deleteWindow)))
}

@Test
func rootlessWindowManagerFallsBackToKillWithoutDeleteWindowProtocol() {
    let manager = RootlessWindowManager()
    let recorder = WindowEventRecorder()
    manager.onEvent = { recorder.events.append($0) }

    _ = manager.upsertTopLevel(XTopLevelWindow(id: 7, title: "xeyes"))
    manager.requestCloseFromVisionOS(window: 7)

    #expect(recorder.events.contains(.killClientRequested(window: 7)))
}

@Test
func rootlessWindowManagerDestroysAllWindowsInStableOrder() {
    let manager = RootlessWindowManager()
    let recorder = WindowEventRecorder()
    manager.onEvent = { recorder.events.append($0) }

    _ = manager.upsertTopLevel(XTopLevelWindow(id: 9, title: "xclock"))
    _ = manager.upsertTopLevel(XTopLevelWindow(id: 3, title: "xlogo"))
    manager.focus(window: 9)

    manager.destroyAllWindows()

    #expect(manager.windows.isEmpty)
    #expect(manager.focusedWindow == nil)
    #expect(recorder.events.suffix(2) == [.destroyed(3), .destroyed(9)])
}

@Test
func rootlessWindowManagerDoesNotRepeatFocusEventsForSameWindow() {
    let manager = RootlessWindowManager()
    let recorder = WindowEventRecorder()
    manager.onEvent = { recorder.events.append($0) }

    _ = manager.upsertTopLevel(XTopLevelWindow(id: 11, title: "xterm"))
    manager.focus(window: 11)
    manager.focus(window: 11)

    #expect(recorder.events.filter { $0 == .focused(11) }.count == 1)
}

@Test
func inputTranslatorMapsPanelCoordinatesIntoXWindowCoordinates() {
    let translator = XInputTranslator()
    let event = translator.pointerEvent(
        window: 1,
        kind: .motion,
        panelPoint: CGPoint(x: 50, y: 25),
        panelSize: CGSize(width: 100, height: 50),
        xWindowSize: CGSize(width: 800, height: 600)
    )

    #expect(event.x == 399)
    #expect(event.y == 299)
}

@Test
func inputTranslatorAppliesVisualCurvatureTransform() {
    let translator = XInputTranslator()
    let event = translator.pointerEvent(
        window: 1,
        kind: .motion,
        panelPoint: CGPoint(x: 75, y: 75),
        panelSize: CGSize(width: 100, height: 100),
        xWindowSize: CGSize(width: 100, height: 100),
        visualTransform: XPointerVisualTransform(curvatureIntensity: 1, warbleIntensity: 0)
    )

    #expect(event.x == 76)
    #expect(event.y == 76)
}

@Test
func inputTranslatorMapsScrollIntoButtonEvents() {
    let translator = XInputTranslator()
    let events = translator.scrollEvents(
        window: 3,
        deltaY: 12,
        panelPoint: CGPoint(x: 50, y: 25),
        panelSize: CGSize(width: 100, height: 50),
        xWindowSize: CGSize(width: 800, height: 600)
    )

    #expect(events == [
        XPointerEvent(window: 3, kind: .buttonPress(.scrollUp), x: 399, y: 299),
        XPointerEvent(window: 3, kind: .buttonRelease(.scrollUp), x: 399, y: 299),
    ])
}

@Test
func visualTransformKeepsWarbleInBounds() {
    let transform = XPointerVisualTransform(curvatureIntensity: 0.5, warbleIntensity: 1, time: 12.5)
    let point = transform.sourcePoint(
        for: CGPoint(x: 0, y: 50),
        in: CGSize(width: 100, height: 100)
    )

    #expect(point.x >= 0)
    #expect(point.x <= 100)
    #expect(point.y >= 0)
    #expect(point.y <= 100)
}

private final class WindowEventRecorder: @unchecked Sendable {
    var events: [XWindowManagerEvent] = []
}
