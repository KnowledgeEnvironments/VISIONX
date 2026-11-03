// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import SwiftUI
import VisionGL
import VisionXCore
#if canImport(UIKit) && canImport(MetalKit)
import MetalKit
import QuartzCore
#endif
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG
private let visionXRenderTraceEnabled = true
#else
private let visionXRenderTraceEnabled = false
#endif
private let visionXGLXFrameTraceEnabled = ProcessInfo.processInfo.environment["VISIONX_GLX_FRAME_TRACE"] == "1"
private let visionXGLXDirectDrawEnabled = ProcessInfo.processInfo.environment["VISIONX_GLX_DIRECT_DRAW"] == "1"
private let visionXGLXForceTextureViewEnabled = ProcessInfo.processInfo.environment["VISIONX_GLX_FORCE_TEXTURE_VIEW"] == "1"

struct XWindowSurfaceView: View {
    @EnvironmentObject private var model: VisionXAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    var windowID: XID?
    @State private var isProgrammaticDismissal = false

    private var window: XTopLevelWindow? {
        guard let windowID else {
            return nil
        }
        return model.windows.first { $0.id == windowID }
    }

    var body: some View {
        Group {
            if let window {
                ZStack {
                    Rectangle()
                        .fill(usesTransparentCRTBackground ? Color.clear : Color.black)

                    if isDisplayable(window) {
                        XWindowPixelsView(window: window)
                    } else {
                        XWindowPlaceholder(window: window)
                    }
                }
            } else {
                Color.clear
            }
        }
        .overlay {
            NativeXWindowSceneCoordinator()
                .environmentObject(model)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .fixedSize()
        .onAppear {
            dismissIfSceneShouldClose()
        }
        .onChange(of: sceneShouldClose) { _, shouldClose in
            if shouldClose {
                dismissIfSceneShouldClose()
            }
        }
        .onDisappear {
            nativeSceneDidDisappear()
        }
    }

    private var sceneShouldClose: Bool {
        guard windowID != nil else {
            return false
        }
        guard let window else {
            return true
        }
        return !model.isNativeSceneOpenable(window)
    }

    private func isDisplayable(_ window: XTopLevelWindow) -> Bool {
        model.isNativeSceneOpenable(window)
    }

    private func dismissIfSceneShouldClose() {
        guard sceneShouldClose, let windowID else {
            return
        }
        VisionXRuntimeLog.write("UI dismiss native X window because backing XID is no longer displayable id=\(windowID)")
        if window == nil, model.requestControlWindowRecoveryFromStaleScene(window: windowID) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if model.consumeControlWindowRecoveryRequest() {
                    VisionXRuntimeLog.write("UI reopen control scene after stale X window recovery id=\(windowID)")
                    openWindow(id: "server-control")
                }
            }
        }
        isProgrammaticDismissal = true
        model.markProgrammaticNativeWindowSceneDismissal(windowID)
        model.nativeWindowSceneDidClose(windowID)
        dismissWindow(value: XWindowHandle(id: windowID))
        dismiss()
    }

    private func nativeSceneDidDisappear() {
        guard let windowID else {
            return
        }
        model.nativeWindowSceneDidClose(windowID)
        if isProgrammaticDismissal || model.consumeProgrammaticNativeWindowSceneDismissal(windowID) {
            VisionXRuntimeLog.write("UI native X window programmatically dismissed id=\(windowID)")
            isProgrammaticDismissal = false
            return
        }
        guard let window, model.isNativeSceneOpenable(window) else {
            return
        }
        VisionXRuntimeLog.write("UI native X window closed while backing XID remains mapped id=\(windowID)")
        model.close(window: windowID)
    }

    private var contentSize: CGSize {
        guard let window else {
            return CGSize(width: 1, height: 1)
        }
        return window.contentSize
    }

    private var usesTransparentCRTBackground: Bool {
        model.visualOptions.crtEnabled &&
            (model.visualOptions.curvatureIntensity > 0.001 || model.visualOptions.warbleIntensity > 0.001)
    }
}

private struct XWindowPixelsView: View {
    @EnvironmentObject private var model: VisionXAppModel
    @Environment(\.scenePhase) private var scenePhase
    var window: XTopLevelWindow

    @State private var pixelSnapshot: XWindowPixelSnapshot?
    @State private var lastPixelAvailability: Bool?
    @State private var nextPixelUpdateSerial: UInt64 = 0
    @State private var isPrimaryButtonDown = false
    @State private var activeKeyDispatches: [UInt8: ActiveKeyDispatch] = [:]
    @State private var activeModifierCounts: [UInt8: Int] = [:]
    @State private var keyboardFocusRequestID = 0
    @State private var keyboardCaptureActive = false
    @State private var isPointerInside = false
    @State private var lastPointerPoint: CGPoint = .zero
    @State private var isDamageRefreshScheduled = false
    @State private var pendingDamageBatch = XWindowDamageBatch()
    @State private var lastDamageRefreshUptime: TimeInterval = 0
    @State private var lastFullRefreshUptime: TimeInterval = 0
    @State private var dirtyRefreshLogCount = 0
    @State private var fullRefreshLogCount = 0
#if canImport(UIKit) && canImport(MetalKit)
    @State private var glxFrame: VisionGLMetalFrame?
    @State private var glxSurface: XWindowGLXSurface?
    @State private var lastPresentedGLXFrameSerial: UInt64 = 0
#endif
    private let fallbackRefreshTimer = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()
    private let inputTranslator = XInputTranslator()

    var body: some View {
        ZStack(alignment: .topLeading) {
            pixelContent

            if model.visualOptions.xCursorEnabled && isPointerInside {
                XWindowCursorView()
                    .frame(width: cursorSize.width, height: cursorSize.height)
                    .offset(x: lastPointerPoint.x, y: lastPointerPoint.y)
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .frame(width: window.contentSize.width, height: window.contentSize.height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .focusable(true)
        .overlay(alignment: .topLeading) {
            keyboardCaptureView
        }
        .onTapGesture {
            focusSurface(forceKeyboardRequest: true, raise: true)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                if !isPointerInside {
                    sendPointer(.enter, at: point)
                    isPointerInside = true
                    focusSurface(forceKeyboardRequest: false, raise: false)
                }
                lastPointerPoint = point
                sendPointer(.motion, at: point)
            case .ended:
                if isPointerInside {
                    sendPointer(.leave, at: lastPointerPoint)
                    isPointerInside = false
                }
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if !isPrimaryButtonDown {
                        focusSurface(forceKeyboardRequest: true, raise: true)
                        if !isPointerInside {
                            sendPointer(.enter, at: value.location)
                            isPointerInside = true
                        }
                        lastPointerPoint = value.location
                        sendPointer(.motion, at: value.location)
                        sendPointer(.buttonPress(.primary), at: value.location)
                        isPrimaryButtonDown = true
                    } else {
                        lastPointerPoint = value.location
                        sendPointer(.motion, at: value.location)
                    }
                }
                .onEnded { value in
                    if isPrimaryButtonDown {
                        lastPointerPoint = value.location
                        sendPointer(.motion, at: value.location)
                        sendPointer(.buttonRelease(.primary), at: value.location)
                        isPrimaryButtonDown = false
                    }
                }
        )
        .onKeyPress(phases: .all) { press in
            handleKeyPress(press)
        }
        .onAppear {
            if !window.overrideRedirect {
                focusSurface(raise: false)
            }
            refreshPixels()
        }
        .onDisappear {
            keyboardCaptureActive = false
            isDamageRefreshScheduled = false
            if isPointerInside {
                sendPointer(.leave, at: lastPointerPoint)
                isPointerInside = false
            }
            if isPrimaryButtonDown {
                sendPointer(.buttonRelease(.primary), at: lastPointerPoint)
                isPrimaryButtonDown = false
            }
            releaseAllKeys(reason: "disappear")
        }
        .onReceive(fallbackRefreshTimer) { _ in
            refreshPixelsForRecoveryIfNeeded()
        }
        .onReceive(model.damageEvents) { event in
            guard event.window == window.id else {
                return
            }
            scheduleDamageRefresh(rects: event.rects)
        }
        .onChange(of: window.id) { _, _ in
            refreshPixels()
        }
        .onChange(of: window.frame) { _, _ in
            refreshPixels()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                focusSurface(forceKeyboardRequest: true, raise: true)
            }
        }
    }

    @ViewBuilder
    private var pixelContent: some View {
#if canImport(UIKit) && canImport(MetalKit)
        if XWindowCompositedMetalView.isAvailable {
            XWindowCompositedMetalView(
                snapshot: pixelSnapshot,
                glxSurface: glxSurface,
                glxFrame: glxFrame,
                frameProvider: {
                    guard let backingWindow = glxSurface?.backingWindow else {
                        return nil
                    }
                    return model.glxFrame(for: backingWindow)
                },
                options: model.visualOptions,
                windowSize: window.contentSize
            )
            .frame(width: window.contentSize.width, height: window.contentSize.height)
        } else {
            ZStack(alignment: .topLeading) {
                if glxFrame != nil {
                    pixelBaseContent
                } else {
                    pixelSnapshotContent
                }

                if let glxFrame, let glxSurface {
                    XWindowGLXTextureView(
                        windowID: glxSurface.backingWindow,
                        frame: glxFrame,
                        frameProvider: { model.glxFrame(for: glxSurface.backingWindow) }
                    )
                        .frame(
                            width: CGFloat(glxFrame.width),
                            height: CGFloat(glxFrame.height)
                        )
                        .offset(x: CGFloat(glxSurface.frame.x), y: CGFloat(glxSurface.frame.y))
                        .clipped()
                        .zIndex(1)
                }
            }
        }
#else
        pixelSnapshotContent
#endif
    }

    @ViewBuilder
    private var pixelBaseContent: some View {
        if let pixelSnapshot {
            XWindowPixelContent(snapshot: pixelSnapshot)
                .frame(
                    width: CGFloat(pixelSnapshot.fullBuffer.width),
                    height: CGFloat(pixelSnapshot.fullBuffer.height)
                )
                .modifier(
                    CRTWindowShaderEffect(
                        options: model.visualOptions,
                        size: CGSize(width: CGFloat(pixelSnapshot.fullBuffer.width), height: CGFloat(pixelSnapshot.fullBuffer.height))
                    )
                )
                .clipped()
        } else {
            Color.black
                .frame(width: window.contentSize.width, height: window.contentSize.height)
        }
    }

    @ViewBuilder
    private var pixelSnapshotContent: some View {
        if let pixelSnapshot {
            XWindowPixelContent(snapshot: pixelSnapshot)
                .frame(
                    width: CGFloat(pixelSnapshot.fullBuffer.width),
                    height: CGFloat(pixelSnapshot.fullBuffer.height)
                )
                .modifier(
                    CRTWindowShaderEffect(
                        options: model.visualOptions,
                        size: CGSize(width: CGFloat(pixelSnapshot.fullBuffer.width), height: CGFloat(pixelSnapshot.fullBuffer.height))
                    )
                )
                .clipped()
        } else {
            XWindowPlaceholder(window: window)
        }
    }

    @ViewBuilder
    private var keyboardCaptureView: some View {
#if canImport(UIKit)
        UIKitKeyboardCaptureView(
            isActive: keyboardCaptureActive,
            focusRequestID: keyboardFocusRequestID,
            windowID: window.id,
            onKey: { key, phase in
                handleUIKitKey(key, phase: phase)
            },
            onScroll: { deltaY, point in
                sendScroll(deltaY: deltaY, at: point)
            }
        )
        .frame(width: window.contentSize.width, height: window.contentSize.height)
#else
        EmptyView()
#endif
    }

    private func refreshPixels(damageRects: [XRectangle]? = nil) {
        isDamageRefreshScheduled = false
#if canImport(UIKit) && canImport(MetalKit)
        if let nextGLXSurface = model.glxSurface(for: window.id),
           let nextGLXFrame = model.glxFrame(for: nextGLXSurface.backingWindow) {
            if nextGLXFrame.serial != lastPresentedGLXFrameSerial {
                lastPresentedGLXFrameSerial = nextGLXFrame.serial
                if nextGLXFrame.serial <= 12 || nextGLXFrame.serial.isMultiple(of: 120) {
                    VisionXRuntimeLog.write(
                        "UI GLX frame window=\(window.id) backing=\(nextGLXSurface.backingWindow) offset=\(nextGLXSurface.frame.x),\(nextGLXSurface.frame.y) serial=\(nextGLXFrame.serial) draws=\(nextGLXFrame.drawCallCount) clears=\(nextGLXFrame.clearCount) transform=\(nextGLXFrame.transformSignature)"
                    )
                }
            }
            glxSurface = nextGLXSurface
            glxFrame = nextGLXFrame
            lastDamageRefreshUptime = ProcessInfo.processInfo.systemUptime
            if let damageRects,
               !damageRects.isEmpty,
               damageRects.allSatisfy({ nextGLXSurface.frame.contains($0) }),
               pixelSnapshot != nil {
                return
            }
        } else {
            lastPresentedGLXFrameSerial = 0
            glxSurface = nil
            glxFrame = nil
        }
#endif
        if let damageRects {
            if refreshDirtyRegions(damageRects) {
                return
            }
            logPixelRefresh("dirty fallback window=\(window.id) request=\(describe(damageRects))")
        }

        let fullCopyStart = ProcessInfo.processInfo.systemUptime
        let next = model.pixelBuffer(for: window.id)
        let fullCopyDurationMS = (ProcessInfo.processInfo.systemUptime - fullCopyStart) * 1000
        let hasPixels = next != nil
        if lastPixelAvailability != hasPixels {
            let pixelDescription = next.map { "\($0.width)x\($0.height)" } ?? "nil"
            VisionXRuntimeLog.write(
                "UI pixel buffer window=\(window.id) available=\(hasPixels) pixels=\(pixelDescription) scale=1 display=\(Int(window.contentSize.width))x\(Int(window.contentSize.height))"
            )
            lastPixelAvailability = hasPixels
        }
        if let next {
            lastFullRefreshUptime = ProcessInfo.processInfo.systemUptime
            nextPixelUpdateSerial &+= 1
            if shouldTracePixelRefresh, fullRefreshLogCount < 80 {
                fullRefreshLogCount += 1
                VisionXRuntimeLog.write(
                    String(
                        format: "UI full refresh window=%u damage=%@ pixels=%dx%d serial=%llu copyMS=%.3f",
                        window.id,
                        damageRects.map(describe) ?? "nil",
                        next.width,
                        next.height,
                        nextPixelUpdateSerial,
                        fullCopyDurationMS
                    )
                )
            }
            pixelSnapshot = XWindowPixelSnapshot(
                backingStore: XWindowPixelBackingStore(buffer: next),
                fullUpdateSerial: nextPixelUpdateSerial,
                dirtyRect: nil,
                dirtyUpdateSerial: 0
            )
        }
    }

    private func refreshDirtyRegions(_ rects: [XRectangle]) -> Bool {
        guard !rects.isEmpty else {
            return false
        }
#if canImport(UIKit) && canImport(MetalKit)
        guard XWindowMetalTextureView.isAvailable else {
            return false
        }
#else
        return false
#endif

        let dirtyCopyStart = ProcessInfo.processInfo.systemUptime
        guard var snapshot = pixelSnapshot else {
            logPixelRefresh("dirty skipped window=\(window.id) request=\(describe(rects)) reason=noSnapshot")
            return false
        }
        let copyRects = dirtyCopyRects(for: rects, snapshot: snapshot)
        var uploadRect: XRectangle?
        for rect in copyRects {
            guard let dirtyRect = snapshot.backingStore.copyAndMergeRegion(window: window.id, rect: rect, model: model) else {
                logPixelRefresh("dirty failed window=\(window.id) request=\(describe(rects)) copy=\(describe(copyRects)) failed=\(describe(rect)) reason=copyOrMerge")
                return false
            }
            uploadRect = uploadRect.map { $0.union(dirtyRect) } ?? dirtyRect
        }
        guard let uploadRect else {
            return false
        }
        let dirtyCopyDurationMS = (ProcessInfo.processInfo.systemUptime - dirtyCopyStart) * 1000

        lastDamageRefreshUptime = ProcessInfo.processInfo.systemUptime
        nextPixelUpdateSerial &+= 1
        logPixelRefresh(
            String(
                format: "dirty merged window=%u request=%@ upload=%@ serial=%llu copyMS=%.3f",
                window.id,
                describe(rects),
                "\(describe(uploadRect)) copy=\(describe(copyRects))",
                nextPixelUpdateSerial,
                dirtyCopyDurationMS
            )
        )
        snapshot.dirtyRect = uploadRect
        snapshot.dirtyUpdateSerial = nextPixelUpdateSerial
        pixelSnapshot = snapshot
        return true
    }

    private var shouldTracePixelRefresh: Bool {
        visionXRenderTraceEnabled &&
            window.frame.width >= 256 &&
            window.frame.height >= 200
    }

    private func dirtyCopyRects(for rects: [XRectangle], snapshot: XWindowPixelSnapshot) -> [XRectangle] {
        let normalizedRects = rects.map { expandedSmallDamageRect($0, snapshot: snapshot) }
        guard normalizedRects.count > 1 else {
            return normalizedRects
        }

        let unionRect = normalizedRects.dropFirst().reduce(normalizedRects[0]) { $0.union($1) }
        if normalizedRects.count > XWindowDamageBatch.maxDiscreteDirtyRects {
            return [unionRect]
        }

        let totalArea = normalizedRects.reduce(0) { $0 + max(0, $1.width) * max(0, $1.height) }
        let unionArea = max(0, unionRect.width) * max(0, unionRect.height)
        let windowArea = max(1, snapshot.fullBuffer.width * snapshot.fullBuffer.height)
        if unionArea <= totalArea * 3 ||
           (normalizedRects.count >= 4 && unionArea <= windowArea / 8) {
            return [unionRect]
        }

        return normalizedRects
    }

    private func expandedSmallDamageRect(_ rect: XRectangle, snapshot: XWindowPixelSnapshot) -> XRectangle {
        let width = max(1, rect.width)
        let height = max(1, rect.height)
        let area = width * height
        guard width <= XWindowDamageBatch.smallDamageMaxDimension,
              height <= XWindowDamageBatch.smallDamageMaxDimension,
              area <= XWindowDamageBatch.smallDamageMaxArea else {
            return rect
        }

        let x1 = max(0, rect.x - XWindowDamageBatch.smallDamageHorizontalPadding)
        let y1 = max(0, rect.y - XWindowDamageBatch.smallDamageVerticalPadding)
        let x2 = min(snapshot.fullBuffer.width, rect.x + width + XWindowDamageBatch.smallDamageHorizontalPadding)
        let y2 = min(snapshot.fullBuffer.height, rect.y + height + XWindowDamageBatch.smallDamageVerticalPadding)
        guard x2 > x1, y2 > y1 else {
            return rect
        }
        return XRectangle(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    private func describe(_ rect: XRectangle?) -> String {
        guard let rect else {
            return "nil"
        }
        return "\(rect.width)x\(rect.height)+\(rect.x)+\(rect.y)"
    }

    private func describe(_ rects: [XRectangle]) -> String {
        guard let first = rects.first else {
            return "full"
        }
        if rects.count == 1 {
            return describe(first)
        }
        let unionRect = rects.dropFirst().reduce(first) { $0.union($1) }
        return "count=\(rects.count) first=\(describe(first)) union=\(describe(unionRect))"
    }

    private func logPixelRefresh(_ message: String) {
        guard shouldTracePixelRefresh, dirtyRefreshLogCount < 240 else {
            return
        }
        dirtyRefreshLogCount += 1
        VisionXRuntimeLog.write("UI pixel refresh \(message)")
    }

    private func refreshPixelsForRecoveryIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        let lastRefresh = max(lastDamageRefreshUptime, lastFullRefreshUptime)
        guard pixelSnapshot == nil || lastPixelAvailability != true || now - lastRefresh >= 5.0 else {
            return
        }
        refreshPixels()
    }

    private func scheduleDamageRefresh(rects: [XRectangle]) {
        pendingDamageBatch.append(rects)
        guard !isDamageRefreshScheduled else {
            return
        }
        isDamageRefreshScheduled = true
        if let coalescingDelay = pendingDamageBatch.coalescingDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + coalescingDelay) {
                flushScheduledDamageRefresh()
            }
        } else {
            DispatchQueue.main.async {
                flushScheduledDamageRefresh()
            }
        }
    }

    private func flushScheduledDamageRefresh() {
        let damageRects = pendingDamageBatch.flush()
        refreshPixels(damageRects: damageRects)
    }

    private func focusSurface(forceKeyboardRequest: Bool = false, raise: Bool = false) {
        let shouldRequestKeyboard = forceKeyboardRequest || !keyboardCaptureActive
        keyboardCaptureActive = true
        if shouldRequestKeyboard {
            keyboardFocusRequestID &+= 1
        }
        let sent = raise ? model.activate(window: window.id, raise: true) : model.focus(window: window.id)
        if shouldRequestKeyboard {
            VisionXRuntimeLog.write("UI focus window=\(window.id) keyboardRequest=\(keyboardFocusRequestID) raise=\(raise) sent=\(sent)")
        }
    }

    private func sendPointer(_ kind: XPointerEvent.Kind, at point: CGPoint) {
        let event = inputTranslator.pointerEvent(
            window: window.id,
            kind: kind,
            panelPoint: point,
            panelSize: window.contentSize,
            xWindowSize: window.xWindowSize,
            visualTransform: pointerVisualTransform
        )
        let sent = model.send(pointer: event)
        if kind.shouldLog {
            VisionXRuntimeLog.write("UI pointer \(kind.logName) window=\(window.id) x=\(event.x) y=\(event.y) sent=\(sent)")
        }
    }

    private func sendScroll(deltaY: CGFloat, at point: CGPoint) {
        guard deltaY != 0 else {
            return
        }

        focusSurface()
        if !isPointerInside {
            sendPointer(.enter, at: point)
            isPointerInside = true
        }
        lastPointerPoint = point

        let stepCount = min(8, max(1, Int((abs(deltaY) / 24).rounded(.down))))
        VisionXRuntimeLog.write("UI pointer scroll window=\(window.id) deltaY=\(deltaY) steps=\(stepCount)")
        for _ in 0..<stepCount {
            let events = inputTranslator.scrollEvents(
                window: window.id,
                deltaY: deltaY,
                panelPoint: point,
                panelSize: window.contentSize,
                xWindowSize: window.xWindowSize,
                visualTransform: pointerVisualTransform
            )
            for event in events {
                let sent = model.send(pointer: event)
                if event.kind.shouldLog {
                    VisionXRuntimeLog.write("UI pointer \(event.kind.logName) window=\(window.id) x=\(event.x) y=\(event.y) sent=\(sent)")
                }
            }
        }
    }

    private var pointerVisualTransform: XPointerVisualTransform {
        guard model.visualOptions.crtEnabled else {
            return .identity
        }

        return XPointerVisualTransform(
            curvatureIntensity: CGFloat(model.visualOptions.curvatureIntensity),
            warbleIntensity: CGFloat(model.visualOptions.warbleIntensity),
            time: Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
        )
    }

    private var cursorSize: CGSize {
        let scale = min(1.0, max(0.15, model.visualOptions.xCursorScale))
        return CGSize(width: 22 * scale, height: 30 * scale)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard let mapping = X11KeyMapper.mapping(for: press) else {
            VisionXRuntimeLog.write("UI key SwiftUI ignored window=\(window.id) key=\(press.key) characters=\(press.characters)")
            return .ignored
        }

        let modifiers = X11KeyMapper.modifierKeycodes(for: press.modifiers, forceShift: mapping.needsShift)
        if press.phase == .down {
            dispatchMappedKey(mapping, modifiers: modifiers, phase: .down, source: "SwiftUI")
        } else if press.phase == .repeat {
            dispatchMappedKey(mapping, modifiers: modifiers, phase: .repeated, source: "SwiftUI")
        } else if press.phase == .up {
            dispatchMappedKey(mapping, modifiers: modifiers, phase: .up, source: "SwiftUI")
        }
        return .handled
    }

#if canImport(UIKit)
    private func handleUIKitKey(_ key: UIKey, phase: KeyDispatchPhase) {
        guard let mapping = X11KeyMapper.mapping(for: key) else {
            VisionXRuntimeLog.write("UI key UIKit ignored window=\(window.id) usage=\(key.keyCode.rawValue) characters=\(key.characters)")
            return
        }

        let modifiers = X11KeyMapper.modifierKeycodes(for: key.modifierFlags, forceShift: mapping.needsShift)
        dispatchMappedKey(mapping, modifiers: modifiers, phase: phase, source: "UIKit")
    }
#endif

    private func dispatchMappedKey(
        _ mapping: X11KeyMapping,
        modifiers: [UInt8],
        phase: KeyDispatchPhase,
        source: String
    ) {
        switch phase {
        case .down:
            guard activeKeyDispatches[mapping.keycode] == nil else {
                VisionXRuntimeLog.write("UI key \(source) duplicate down suppressed window=\(window.id) keycode=\(mapping.keycode)")
                return
            }
            activeKeyDispatches[mapping.keycode] = ActiveKeyDispatch(modifiers: modifiers)
            pressModifiers(modifiers)
            VisionXRuntimeLog.write("UI key \(source) down window=\(window.id) keycode=\(mapping.keycode) modifiers=\(modifiers)")
            sendKey(mapping.keycode, kind: .keyPress)

        case .repeated:
            guard activeKeyDispatches[mapping.keycode] != nil else {
                VisionXRuntimeLog.write("UI key \(source) repeat promoted to down window=\(window.id) keycode=\(mapping.keycode)")
                dispatchMappedKey(mapping, modifiers: modifiers, phase: .down, source: source)
                return
            }
            VisionXRuntimeLog.write("UI key \(source) repeat window=\(window.id) keycode=\(mapping.keycode)")
            sendKey(mapping.keycode, kind: .keyPress)

        case .up, .cancelled:
            guard let active = activeKeyDispatches.removeValue(forKey: mapping.keycode) else {
                VisionXRuntimeLog.write("UI key \(source) duplicate \(phase.logName) suppressed window=\(window.id) keycode=\(mapping.keycode)")
                return
            }
            VisionXRuntimeLog.write("UI key \(source) \(phase.logName) window=\(window.id) keycode=\(mapping.keycode)")
            sendKey(mapping.keycode, kind: .keyRelease)
            releaseModifiers(active.modifiers)
        }
    }

    private func pressModifiers(_ modifiers: [UInt8]) {
        for keycode in modifiers {
            let count = activeModifierCounts[keycode] ?? 0
            activeModifierCounts[keycode] = count + 1
            if count == 0 {
                sendKey(keycode, kind: .keyPress)
            }
        }
    }

    private func releaseModifiers(_ modifiers: [UInt8]) {
        for keycode in modifiers.reversed() {
            let nextCount = max(0, (activeModifierCounts[keycode] ?? 0) - 1)
            if nextCount == 0 {
                activeModifierCounts.removeValue(forKey: keycode)
                sendKey(keycode, kind: .keyRelease)
            } else {
                activeModifierCounts[keycode] = nextCount
            }
        }
    }

    private func releaseAllKeys(reason: String) {
        guard !activeKeyDispatches.isEmpty || !activeModifierCounts.isEmpty else {
            return
        }
        VisionXRuntimeLog.write(
            "UI key release all window=\(window.id) reason=\(reason) keys=\(activeKeyDispatches.count) modifiers=\(activeModifierCounts.count)"
        )

        for keycode in activeKeyDispatches.keys.sorted() {
            sendKey(keycode, kind: .keyRelease)
        }
        activeKeyDispatches.removeAll()

        for keycode in activeModifierCounts.keys.sorted().reversed() {
            sendKey(keycode, kind: .keyRelease)
        }
        activeModifierCounts.removeAll()
    }

    private func sendKey(_ keycode: UInt8, kind: XKeyboardEvent.Kind) {
        let sent = model.send(key: XKeyboardEvent(window: window.id, kind: kind, keycode: keycode))
        if !sent {
            VisionXRuntimeLog.write("UI key send failed window=\(window.id) kind=\(kind) keycode=\(keycode)")
        }
    }
}

private struct XWindowDamageBatch {
    static let maxDiscreteDirtyRects = 8
    static let stormCoalescingDelay: DispatchTimeInterval = .milliseconds(2)
    static let smallDamageCoalescingDelay: DispatchTimeInterval = .milliseconds(4)
    static let smallDamageMaxDimension = 96
    static let smallDamageMaxArea = 4096
    static let smallDamageHorizontalPadding = 8
    static let smallDamageVerticalPadding = 4

    private var rects: [XRectangle] = []
    private var needsFullRefresh = false

    var coalescingDelay: DispatchTimeInterval? {
        guard !needsFullRefresh else {
            return nil
        }
        if rects.count >= 4 {
            return Self.stormCoalescingDelay
        }
        if isSmallTextDamageBatch {
            return Self.smallDamageCoalescingDelay
        }
        return nil
    }

    mutating func append(_ incomingRects: [XRectangle]) {
        guard !needsFullRefresh else {
            return
        }
        guard !incomingRects.isEmpty else {
            needsFullRefresh = true
            rects.removeAll()
            return
        }

        rects.append(contentsOf: incomingRects)
        if rects.count > Self.maxDiscreteDirtyRects, let first = rects.first {
            rects = [rects.dropFirst().reduce(first) { $0.union($1) }]
        }
    }

    mutating func flush() -> [XRectangle]? {
        defer {
            rects.removeAll()
            needsFullRefresh = false
        }
        return needsFullRefresh ? nil : rects
    }

    private var isSmallTextDamageBatch: Bool {
        guard !rects.isEmpty else {
            return false
        }
        return rects.allSatisfy { rect in
            let width = max(0, rect.width)
            let height = max(0, rect.height)
            return width <= Self.smallDamageMaxDimension &&
                height <= Self.smallDamageMaxDimension &&
                width * height <= Self.smallDamageMaxArea
        }
    }
}

private final class XWindowPixelBackingStore {
    private(set) var buffer: XWindowPixelBuffer
    private var dirtyScratch = Data()

    init(buffer: XWindowPixelBuffer) {
        self.buffer = buffer
    }

    @MainActor
    func copyAndMergeRegion(window: XID, rect: XRectangle, model: VisionXAppModel) -> XRectangle? {
        guard let descriptor = model.copyPixelRegion(for: window, rect: rect, into: &dirtyScratch),
              descriptor.windowWidth == buffer.width,
              descriptor.windowHeight == buffer.height,
              buffer.merge(region: descriptor, data: dirtyScratch) else {
            return nil
        }
        return descriptor.rectangle
    }
}

private struct XWindowPixelSnapshot {
    var backingStore: XWindowPixelBackingStore
    var fullUpdateSerial: UInt64
    var dirtyRect: XRectangle?
    var dirtyUpdateSerial: UInt64

    var fullBuffer: XWindowPixelBuffer {
        backingStore.buffer
    }
}

private extension XWindowPixelBuffer {
    mutating func merge(region: XWindowPixelRegionDescriptor, data sourceData: Data) -> Bool {
        guard region.windowWidth == width,
              region.windowHeight == height,
              region.x >= 0,
              region.y >= 0,
              region.width > 0,
              region.height > 0,
              region.x + region.width <= width,
              region.y + region.height <= height,
              region.bytesPerRow >= region.width * 4,
              bytesPerRow >= width * 4 else {
            return false
        }

        let rowBytes = region.width * 4
        let requiredSourceLength = region.bytesPerRow * region.height
        let requiredDestinationLength = bytesPerRow * height
        guard sourceData.count >= requiredSourceLength,
              bgraData.count >= requiredDestinationLength else {
            return false
        }

        return bgraData.withUnsafeMutableBytes { destinationBuffer in
            guard let destinationBase = destinationBuffer.baseAddress else {
                return false
            }
            return sourceData.withUnsafeBytes { sourceBuffer in
                guard let sourceBase = sourceBuffer.baseAddress else {
                    return false
                }

                for row in 0..<region.height {
                    let sourceOffset = row * region.bytesPerRow
                    let destinationOffset = (region.y + row) * bytesPerRow + region.x * 4
                    destinationBase
                        .advanced(by: destinationOffset)
                        .copyMemory(from: sourceBase.advanced(by: sourceOffset), byteCount: rowBytes)
                }
                return true
            }
        }
    }
}

private struct XWindowPixelContent: View {
    var snapshot: XWindowPixelSnapshot

    var body: some View {
#if canImport(UIKit) && canImport(MetalKit)
        if XWindowMetalTextureView.isAvailable {
            XWindowMetalTextureView(snapshot: snapshot)
        } else {
            cgImageFallback
        }
#else
        cgImageFallback
#endif
    }

    @ViewBuilder
    private var cgImageFallback: some View {
        if let cgImage = snapshot.fullBuffer.cgImage {
            Image(decorative: cgImage, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.none)
                .antialiased(false)
        } else {
            Color.black
        }
    }
}

#if canImport(UIKit) && canImport(MetalKit)
private struct XWindowCompositedMetalView: UIViewRepresentable {
    var snapshot: XWindowPixelSnapshot?
    var glxSurface: XWindowGLXSurface?
    var glxFrame: VisionGLMetalFrame?
    var frameProvider: @MainActor () -> VisionGLMetalFrame?
    var options: XWindowVisualOptions
    var windowSize: CGSize

    static var isAvailable: Bool {
        if visionXGLXForceTextureViewEnabled {
            return false
        }
        return MTLCreateSystemDefaultDevice() != nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(device: MTLCreateSystemDefaultDevice())
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 120
        view.contentScaleFactor = 1
        view.autoResizeDrawable = false
        view.isOpaque = true
        view.backgroundColor = .black
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = true
        }
        view.layer.isOpaque = true
        view.layer.magnificationFilter = .nearest
        view.layer.minificationFilter = .nearest
        view.layer.contentsScale = 1
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.update(
            snapshot: snapshot,
            glxSurface: glxSurface,
            glxFrame: glxFrame,
            frameProvider: frameProvider,
            options: options,
            windowSize: windowSize
        )
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.device = context.coordinator.device
        context.coordinator.view = uiView
        context.coordinator.update(
            snapshot: snapshot,
            glxSurface: glxSurface,
            glxFrame: glxFrame,
            frameProvider: frameProvider,
            options: options,
            windowSize: windowSize
        )
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
        uiView.delegate = nil
    }

    private struct Uniforms {
        var viewSize: SIMD2<Float>
        var baseSize: SIMD2<Float>
        var glxOrigin: SIMD2<Float>
        var glxSize: SIMD2<Float>
        var hasBase: UInt32
        var hasGLX: UInt32
        var crtEnabled: UInt32
        var reserved0: UInt32 = 0
        var time: Float
        var scanlineIntensity: Float
        var phosphorMaskIntensity: Float
        var glowIntensity: Float
        var vignetteIntensity: Float
        var curvatureIntensity: Float
        var warbleIntensity: Float
        var reserved1: Float = 0
    }

    private struct PendingUpdate {
        var snapshot: XWindowPixelSnapshot?
        var glxSurface: XWindowGLXSurface?
        var glxFrame: VisionGLMetalFrame?
        var options: XWindowVisualOptions
        var windowSize: CGSize
    }

    private struct PresentationConfig: Equatable {
        var transparentOutput: Bool
        var crtEnabled: Bool
        var contentScale: CGFloat
    }

    final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {
        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var pipelinePixelFormat: MTLPixelFormat?
        private var samplerState: MTLSamplerState?
        private var blackTexture: MTLTexture?
        private var baseTexture: MTLTexture?
        private var compositeTexture: MTLTexture?
        private var baseTextureSize = CGSize.zero
        private var lastFullUpdateSerial: UInt64?
        private var lastDirtyUpdateSerial: UInt64?
        private var glxSurface: XWindowGLXSurface?
        private var glxFrame: VisionGLMetalFrame?
        private var frameProvider: (@MainActor () -> VisionGLMetalFrame?)?
        private var options = XWindowVisualOptions()
        private var windowSize = CGSize(width: 1, height: 1)
        private var lastPresentationConfig: PresentationConfig?
        private var drawInFlight = false
        private var drawScheduled = false
        private var drawRetryScheduled = false
        private var needsDisplayLinkDraw = false
        private var pendingUpdate: PendingUpdate?
        private var pendingRequiresFullUpload = false
        private var pendingDirtyRect: XRectangle?
        private var displayLink: CADisplayLink?
        private var displayLinkProxy: DisplayLinkProxy?
        private var glxWindowID: XID?
        private var lastDrawnGLXSerial: UInt64 = 0
        private var drawLogCount: UInt64 = 0
        private var drawFailureLogCount: UInt64 = 0
        private var drawScheduleSkipLogCount: UInt64 = 0
        private var displayLinkTraceCount: UInt64 = 0
        private var lastGLXTraceDrawUptime: TimeInterval = 0
        private var lastGLXTraceCompleteUptime: TimeInterval = 0
        private var lastGLXTracePresentedUptime: TimeInterval = 0
        private let traceTimingLock = NSLock()
        private let presentedSwapLock = NSLock()
        private var presentedSwapSerials: Set<UInt64> = []
        private var presentedSwapSerialOrder: [UInt64] = []
        weak var view: MTKView?

        init(device: MTLDevice?) {
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            super.init()
            if let device {
                let samplerDescriptor = MTLSamplerDescriptor()
                samplerDescriptor.minFilter = .linear
                samplerDescriptor.magFilter = .linear
                samplerDescriptor.sAddressMode = .clampToEdge
                samplerDescriptor.tAddressMode = .clampToEdge
                samplerState = device.makeSamplerState(descriptor: samplerDescriptor)
            }
        }

        @MainActor
        func update(
            snapshot: XWindowPixelSnapshot?,
            glxSurface: XWindowGLXSurface?,
            glxFrame: VisionGLMetalFrame?,
            frameProvider: @escaping @MainActor () -> VisionGLMetalFrame?,
            options: XWindowVisualOptions,
            windowSize: CGSize
        ) {
            self.frameProvider = frameProvider
            let update = PendingUpdate(
                snapshot: snapshot,
                glxSurface: glxSurface,
                glxFrame: glxFrame,
                options: options,
                windowSize: windowSize
            )
            apply(update: update, forceFullUpload: false, dirtyRectsOverride: nil)
        }

        @MainActor
        private func apply(update: PendingUpdate, forceFullUpload: Bool, dirtyRectsOverride: [XRectangle]?) {
            if drawInFlight {
                queuePending(update: update, forceFullUpload: forceFullUpload)
                return
            }

            guard let device else {
                return
            }

            var didUpdateTexture = false
            let previousOptions = options
            let previousWindowSize = self.windowSize
            let previousGLXSerial = self.glxFrame?.serial
            options = update.options
            self.windowSize = CGSize(
                width: max(1, update.windowSize.width),
                height: max(1, update.windowSize.height)
            )
            glxSurface = update.glxSurface
            glxFrame = update.glxFrame
            updateGLXWindowID(update.glxSurface?.backingWindow)

            if let snapshot = update.snapshot {
                didUpdateTexture = upload(snapshot: snapshot, forceFullUpload: forceFullUpload, dirtyRectsOverride: dirtyRectsOverride, device: device)
            } else {
                baseTexture = nil
                baseTextureSize = .zero
                lastFullUpdateSerial = nil
                lastDirtyUpdateSerial = nil
            }

            if let view {
                configurePresentationMode(on: view)
                view.isPaused = true
                view.enableSetNeedsDisplay = true
            }

            let drawableSize = desiredDrawableSize()
            if view?.drawableSize != drawableSize {
                view?.drawableSize = drawableSize
            }

            updateDisplayLink()

            let optionsChanged = previousOptions != options
            let windowSizeChanged = previousWindowSize != self.windowSize
            let glxChanged = previousGLXSerial != update.glxFrame?.serial
            if didUpdateTexture || optionsChanged || windowSizeChanged || glxChanged || update.snapshot == nil || update.glxFrame != nil {
                drawView()
            }
        }

        private func upload(snapshot: XWindowPixelSnapshot, forceFullUpload: Bool, dirtyRectsOverride: [XRectangle]?, device: MTLDevice) -> Bool {
            var didUpdateTexture = false
            let pixelBuffer = snapshot.fullBuffer
            let width = max(1, pixelBuffer.width)
            let height = max(1, pixelBuffer.height)
            if baseTexture?.width != width || baseTexture?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                descriptor.usage = [.shaderRead]
                descriptor.storageMode = .shared
                baseTexture = device.makeTexture(descriptor: descriptor)
                baseTextureSize = CGSize(width: width, height: height)
                lastFullUpdateSerial = nil
                lastDirtyUpdateSerial = nil
            }

            guard let baseTexture else {
                return false
            }

            var uploadedFullBuffer = forceFullUpload || lastFullUpdateSerial != snapshot.fullUpdateSerial
            if !uploadedFullBuffer,
               let dirtyRectsOverride,
               !dirtyRectsOverride.allSatisfy({ canUploadDirtyRect($0, from: pixelBuffer, to: baseTexture) }) {
                uploadedFullBuffer = true
            }
            if uploadedFullBuffer {
                pixelBuffer.bgraData.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return
                    }
                    baseTexture.replace(
                        region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: baseAddress,
                        bytesPerRow: pixelBuffer.bytesPerRow
                    )
                }
                lastFullUpdateSerial = snapshot.fullUpdateSerial
                lastDirtyUpdateSerial = snapshot.dirtyUpdateSerial
                didUpdateTexture = true
            }

            if !uploadedFullBuffer, let dirtyRectsOverride {
                for dirtyRect in dirtyRectsOverride {
                    uploadDirtyRect(dirtyRect, from: pixelBuffer, to: baseTexture)
                }
                lastDirtyUpdateSerial = snapshot.dirtyUpdateSerial
                didUpdateTexture = true
            } else if !uploadedFullBuffer,
                      let dirtyRect = snapshot.dirtyRect,
                      lastDirtyUpdateSerial != snapshot.dirtyUpdateSerial,
                      canUploadDirtyRect(dirtyRect, from: pixelBuffer, to: baseTexture) {
                uploadDirtyRect(dirtyRect, from: pixelBuffer, to: baseTexture)
                lastDirtyUpdateSerial = snapshot.dirtyUpdateSerial
                didUpdateTexture = true
            }

            return didUpdateTexture
        }

        @MainActor
        private func drawView() {
            guard !drawInFlight else {
                traceDrawScheduleSkip(reason: "in-flight")
                return
            }
            guard !drawScheduled else {
                traceDrawScheduleSkip(reason: "scheduled")
                return
            }
            guard let view else {
                traceDrawScheduleSkip(reason: "no-view")
                return
            }
            drawScheduled = true
            if visionXGLXDirectDrawEnabled {
                view.draw()
            } else {
                view.setNeedsDisplay()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            drawScheduled = false
            guard !drawInFlight else {
                return
            }
            if glxSurface != nil, let latestFrame = MainActor.assumeIsolated({ frameProvider?() }) {
                glxFrame = latestFrame
            }
            drawInFlight = true
            guard let device,
                  let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                finishDrawWithoutPresent(reason: "command-unavailable")
                return
            }
            let drawableWaitStart = ProcessInfo.processInfo.systemUptime
            guard let drawable = view.currentDrawable else {
                finishDrawWithoutPresent(reason: "drawable-unavailable")
                return
            }
            let drawableWaitMS = (ProcessInfo.processInfo.systemUptime - drawableWaitStart) * 1000
            let expectedDrawableWidth = max(1, Int(round(view.drawableSize.width)))
            let expectedDrawableHeight = max(1, Int(round(view.drawableSize.height)))
            guard drawable.texture.width == expectedDrawableWidth,
                  drawable.texture.height == expectedDrawableHeight else {
                finishDrawWithoutPresent(
                    reason: "drawable-size-mismatch expected=\(expectedDrawableWidth)x\(expectedDrawableHeight) actual=\(drawable.texture.width)x\(drawable.texture.height)"
                )
                return
            }

            let targetWidth = max(1, Int(round(windowSize.width)))
            let targetHeight = max(1, Int(round(windowSize.height)))

            if options.crtEnabled {
                guard let compositeTexture = ensureCompositeTexture(device: device, width: targetWidth, height: targetHeight),
                      clear(texture: compositeTexture, commandBuffer: commandBuffer),
                      blitCompositeInputs(to: compositeTexture, commandBuffer: commandBuffer),
                      ensurePipeline(device: device, pixelFormat: view.colorPixelFormat),
                      let pipelineState,
                      let samplerState,
                      let blackTexture = ensureBlackTexture(device: device) else {
                    finishDrawWithoutPresent(reason: "crt-setup-failed")
                    return
                }

                let renderPass = MTLRenderPassDescriptor()
                renderPass.colorAttachments[0].texture = drawable.texture
                renderPass.colorAttachments[0].loadAction = .clear
                renderPass.colorAttachments[0].storeAction = .store
                renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: outputClearAlpha)

                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
                    finishDrawWithoutPresent(reason: "encoder-unavailable")
                    return
                }

                var uniforms = currentCRTUniforms(compositeTexture: compositeTexture, drawableTexture: drawable.texture)
                encoder.setRenderPipelineState(pipelineState)
                encoder.setFragmentTexture(compositeTexture, index: 0)
                encoder.setFragmentTexture(blackTexture, index: 1)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()
            } else {
                guard clear(texture: drawable.texture, commandBuffer: commandBuffer, alpha: outputClearAlpha),
                      blitCompositeInputs(to: drawable.texture, commandBuffer: commandBuffer) else {
                    finishDrawWithoutPresent(reason: "composite-blit-failed")
                    return
                }
            }


            let presentedFrame = glxFrame
            let presentedWindowID = glxWindowID
#if !targetEnvironment(simulator)
            if let presentedFrame {
                drawable.addPresentedHandler { [weak self] _ in
                    self?.traceFrameLifecycle("compositePresented", frame: presentedFrame)
                    self?.reportPresentedIfNeeded(presentedFrame)
                }
            }
#endif
            commandBuffer.present(drawable)
            commandBuffer.addCompletedHandler { [weak self] _ in
                if let presentedFrame {
                    self?.traceFrameLifecycle("compositeComplete", frame: presentedFrame)
                }
                if let presentedWindowID, presentedFrame != nil {
                    XOrgBridge.setGLXWindowPresenterActive(window: presentedWindowID, active: true)
                }
#if targetEnvironment(simulator)
                if let presentedFrame {
                    self?.reportPresentedIfNeeded(presentedFrame)
                }
#endif
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    self.drawInFlight = false
                    self.drawRetryScheduled = false
                    guard let pendingUpdate = self.pendingUpdate else {
                        if self.glxFrame?.serial != presentedFrame?.serial {
                            self.drawView()
                        }
                        return
                    }
                    let forceFullUpload = self.pendingRequiresFullUpload
                    let dirtyRect = self.pendingDirtyRect
                    self.pendingUpdate = nil
                    self.pendingRequiresFullUpload = false
                    self.pendingDirtyRect = nil
                    self.apply(update: pendingUpdate, forceFullUpload: forceFullUpload, dirtyRectsOverride: dirtyRect.map { [$0] })
                }
            }
            commandBuffer.commit()

            if let glxFrame, glxFrame.serial != lastDrawnGLXSerial {
                if visionXGLXFrameTraceEnabled {
                    let now = ProcessInfo.processInfo.systemUptime
                    let delta = lastGLXTraceDrawUptime == 0 ? 0 : now - lastGLXTraceDrawUptime
                    lastGLXTraceDrawUptime = now
                    VisionXRuntimeLog.write(
                        String(format: "GLX frame trace compositeDraw frameSerial=%llu swapSerial=%llu dtMS=%.3f drawableWaitMS=%.3f transform=%.6f",
                               glxFrame.serial,
                               glxFrame.swapSerial,
                               delta * 1000,
                               drawableWaitMS,
                               Double(glxFrame.transformSignature))
                    )
                }
                lastDrawnGLXSerial = glxFrame.serial
                drawLogCount &+= 1
                if drawLogCount <= 12 || glxFrame.serial.isMultiple(of: 120) {
                    VisionXRuntimeLog.write(
                        "UI GLX composite draw window serial=\(glxFrame.serial) draws=\(glxFrame.drawCallCount) clears=\(glxFrame.clearCount) transform=\(glxFrame.transformSignature)"
                    )
                }
            }
        }

        private func ensurePipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> Bool {
            if pipelineState != nil, pipelinePixelFormat == pixelFormat {
                return true
            }
            guard
                let library = device.makeDefaultLibrary(),
                let vertexFunction = library.makeFunction(name: "xWindowCompositeVertex"),
                let fragmentFunction = library.makeFunction(name: "xWindowCompositeFragment")
            else {
                VisionXRuntimeLog.write("UI compositor pipeline unavailable")
                return false
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            do {
                pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
                pipelinePixelFormat = pixelFormat
                return true
            } catch {
                VisionXRuntimeLog.write("UI compositor pipeline failed error=\(error)")
                pipelineState = nil
                pipelinePixelFormat = nil
                return false
            }
        }

        private func ensureBlackTexture(device: MTLDevice) -> MTLTexture? {
            if let blackTexture {
                return blackTexture
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: 1,
                height: 1,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            var black: UInt32 = 0xff000000
            texture.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: &black,
                bytesPerRow: 4
            )
            blackTexture = texture
            return texture
        }

        private func ensureCompositeTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
            if let compositeTexture, compositeTexture.width == width, compositeTexture.height == height {
                return compositeTexture
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            compositeTexture = device.makeTexture(descriptor: descriptor)
            return compositeTexture
        }

        private func clear(texture: MTLTexture, commandBuffer: MTLCommandBuffer, alpha: Double = 0) -> Bool {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: alpha)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return false
            }
            encoder.endEncoding()
            return true
        }

        private func blitCompositeInputs(to target: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                return false
            }
            if let baseTexture {
                encodeBlit(
                    from: baseTexture,
                    to: target,
                    destinationX: 0,
                    destinationY: 0,
                    blitEncoder: blitEncoder
                )
            }
            if let glxTexture = glxFrame?.texture, let glxSurface {
                encodeBlit(
                    from: glxTexture,
                    to: target,
                    destinationX: glxSurface.frame.x,
                    destinationY: glxSurface.frame.y,
                    blitEncoder: blitEncoder
                )
            }
            blitEncoder.endEncoding()
            return true
        }

        private func encodeBlit(
            from source: MTLTexture,
            to target: MTLTexture,
            destinationX: Int,
            destinationY: Int,
            blitEncoder: MTLBlitCommandEncoder
        ) {
            let sourceX = max(0, -destinationX)
            let sourceY = max(0, -destinationY)
            let targetX = max(0, destinationX)
            let targetY = max(0, destinationY)
            let width = min(source.width - sourceX, target.width - targetX)
            let height = min(source.height - sourceY, target.height - targetY)
            guard width > 0, height > 0 else {
                return
            }
            blitEncoder.copy(
                from: source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: sourceX, y: sourceY, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: target,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: targetX, y: targetY, z: 0)
            )
        }

        private func currentCRTUniforms(compositeTexture: MTLTexture, drawableTexture: MTLTexture) -> Uniforms {
            let time = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            let outputWidth = max(1, drawableTexture.width)
            let outputHeight = max(1, drawableTexture.height)
            let sourceWidth = max(1, compositeTexture.width)
            let sourceHeight = max(1, compositeTexture.height)

            return Uniforms(
                viewSize: SIMD2(Float(outputWidth), Float(outputHeight)),
                baseSize: SIMD2(Float(sourceWidth), Float(sourceHeight)),
                glxOrigin: SIMD2(0, 0),
                glxSize: SIMD2(1, 1),
                hasBase: 1,
                hasGLX: 0,
                crtEnabled: 1,
                time: Float(time),
                scanlineIntensity: Float(options.scanlineIntensity),
                phosphorMaskIntensity: Float(options.phosphorMaskIntensity),
                glowIntensity: Float(options.glowIntensity),
                vignetteIntensity: Float(options.vignetteIntensity),
                curvatureIntensity: Float(options.curvatureIntensity),
                warbleIntensity: Float(options.warbleIntensity)
            )
        }

        @MainActor
        private func configurePresentationMode(on view: MTKView) {
            let config = PresentationConfig(
                transparentOutput: usesTransparentOutput,
                crtEnabled: options.crtEnabled,
                contentScale: options.crtEnabled ? crtSmoothScale() : 1
            )
            guard lastPresentationConfig != config else {
                return
            }
            lastPresentationConfig = config

            view.isOpaque = !config.transparentOutput
            view.backgroundColor = config.transparentOutput ? .clear : .black
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: config.transparentOutput ? 0 : 1)
            view.layer.isOpaque = !config.transparentOutput

            if config.crtEnabled {
                view.contentScaleFactor = config.contentScale
                view.layer.contentsScale = config.contentScale
                view.layer.magnificationFilter = .linear
                view.layer.minificationFilter = .linear
            } else {
                configurePixelExactPresentation(on: view)
            }
        }

        @MainActor
        private func configurePixelExactPresentation(on view: MTKView) {
            view.contentScaleFactor = 1
            view.layer.contentsScale = 1
            view.layer.magnificationFilter = .nearest
            view.layer.minificationFilter = .nearest
        }

        @MainActor
        private func desiredDrawableSize() -> CGSize {
            let width = max(1, round(windowSize.width))
            let height = max(1, round(windowSize.height))
            guard options.crtEnabled else {
                return CGSize(width: width, height: height)
            }

            let scale = crtSmoothScale()
            return CGSize(width: width * scale, height: height * scale)
        }

        @MainActor
        private func crtSmoothScale() -> CGFloat {
            let displayScale = view?.traitCollection.displayScale ?? 1
            return max(2, displayScale)
        }

        private var usesTransparentOutput: Bool {
            options.crtEnabled &&
                (options.curvatureIntensity > 0.001 || options.warbleIntensity > 0.001)
        }

        private var outputClearAlpha: Double {
            usesTransparentOutput ? 0 : 1
        }

        @MainActor
        private func queuePending(update: PendingUpdate, forceFullUpload: Bool) {
            pendingUpdate = update
            guard !forceFullUpload,
                  !pendingRequiresFullUpload,
                  let baseTexture,
                  let snapshot = update.snapshot,
                  baseTexture.width == snapshot.fullBuffer.width,
                  baseTexture.height == snapshot.fullBuffer.height,
                  lastFullUpdateSerial == snapshot.fullUpdateSerial,
                  let dirtyRect = snapshot.dirtyRect,
                  canUploadDirtyRect(dirtyRect, from: snapshot.fullBuffer, to: baseTexture) else {
                pendingRequiresFullUpload = true
                pendingDirtyRect = nil
                return
            }

            pendingDirtyRect = pendingDirtyRect.map { $0.union(dirtyRect) } ?? dirtyRect
        }

        private func canUploadDirtyRect(_ rect: XRectangle, from pixelBuffer: XWindowPixelBuffer, to texture: MTLTexture) -> Bool {
            rect.x >= 0 &&
                rect.y >= 0 &&
                rect.width > 0 &&
                rect.height > 0 &&
                rect.x + rect.width <= texture.width &&
                rect.y + rect.height <= texture.height &&
                rect.x + rect.width <= pixelBuffer.width &&
                rect.y + rect.height <= pixelBuffer.height &&
                pixelBuffer.bytesPerRow >= pixelBuffer.width * 4 &&
                pixelBuffer.bgraData.count >= pixelBuffer.bytesPerRow * pixelBuffer.height
        }

        private func uploadDirtyRect(_ rect: XRectangle, from pixelBuffer: XWindowPixelBuffer, to texture: MTLTexture) {
            guard canUploadDirtyRect(rect, from: pixelBuffer, to: texture) else {
                return
            }

            pixelBuffer.bgraData.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                let sourceOffset = rect.y * pixelBuffer.bytesPerRow + rect.x * 4
                texture.replace(
                    region: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress.advanced(by: sourceOffset),
                    bytesPerRow: pixelBuffer.bytesPerRow
                )
            }
        }

        @MainActor
        private func updateDisplayLink() {
            let shouldRun = glxSurface != nil || (options.crtEnabled && options.warbleIntensity > 0.001)
            if shouldRun {
                startDisplayLink()
            } else {
                stopDisplayLink()
            }
        }

        @MainActor
        private func startDisplayLink() {
            guard displayLink == nil else {
                return
            }
            let proxy = DisplayLinkProxy(coordinator: self)
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.displayLinkDidFire(_:)))
            link.preferredFramesPerSecond = 120
            link.add(to: .main, forMode: .common)
            displayLinkProxy = proxy
            displayLink = link
        }

        @MainActor
        func stopDisplayLink(clearGLXWindowID: Bool = true) {
            displayLink?.invalidate()
            displayLink = nil
            displayLinkProxy = nil
            if clearGLXWindowID {
                updateGLXWindowID(nil)
            }
        }

        @MainActor
        private func displayLinkDidFire() {
            var needsDraw = needsDisplayLinkDraw || (options.crtEnabled && options.warbleIntensity > 0.001)
            if let latestFrame = frameProvider?() {
                if latestFrame.serial != glxFrame?.serial {
                    glxFrame = latestFrame
                    needsDraw = true
                }
            }
            if needsDraw {
                needsDisplayLinkDraw = false
                traceDisplayLink(needsDraw: true)
                drawView()
            } else {
                traceDisplayLink(needsDraw: false)
            }
        }

        private func traceDisplayLink(needsDraw: Bool) {
            guard visionXGLXFrameTraceEnabled else {
                return
            }
            displayLinkTraceCount &+= 1
            if displayLinkTraceCount <= 12 || displayLinkTraceCount.isMultiple(of: 120) || needsDraw {
                VisionXRuntimeLog.write(
                    "GLX frame trace compositeDisplayLink count=\(displayLinkTraceCount) needsDraw=\(needsDraw ? 1 : 0) frameSerial=\(glxFrame?.serial ?? 0) inFlight=\(drawInFlight ? 1 : 0) scheduled=\(drawScheduled ? 1 : 0)"
                )
            }
        }

        private func traceDrawScheduleSkip(reason: String) {
            guard visionXGLXFrameTraceEnabled else {
                return
            }
            drawScheduleSkipLogCount &+= 1
            if drawScheduleSkipLogCount <= 12 || drawScheduleSkipLogCount.isMultiple(of: 120) {
                VisionXRuntimeLog.write(
                    "GLX frame trace compositeDrawRequest skipped reason=\(reason) count=\(drawScheduleSkipLogCount) frameSerial=\(glxFrame?.serial ?? 0) inFlight=\(drawInFlight ? 1 : 0) scheduled=\(drawScheduled ? 1 : 0)"
                )
            }
        }

        private func traceFrameLifecycle(_ event: String, frame: VisionGLMetalFrame) {
            guard visionXGLXFrameTraceEnabled else {
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            traceTimingLock.lock()
            let previous: TimeInterval
            if event == "compositePresented" {
                previous = lastGLXTracePresentedUptime
                lastGLXTracePresentedUptime = now
            } else {
                previous = lastGLXTraceCompleteUptime
                lastGLXTraceCompleteUptime = now
            }
            traceTimingLock.unlock()

            let delta = previous == 0 ? 0 : now - previous
            VisionXRuntimeLog.write(
                String(format: "GLX frame trace %@ frameSerial=%llu swapSerial=%llu dtMS=%.3f transform=%.6f",
                       event,
                       frame.serial,
                       frame.swapSerial,
                       delta * 1000,
                       Double(frame.transformSignature))
            )
        }

        @MainActor
        private func updateGLXWindowID(_ nextWindowID: XID?) {
            if glxWindowID == nextWindowID {
                return
            }
            if let glxWindowID {
                XOrgBridge.setGLXWindowPresenterActive(window: glxWindowID, active: false)
            }
            glxWindowID = nextWindowID
            resetPresentedSwapHistory()
            if let nextWindowID {
                XOrgBridge.setGLXWindowPresenterActive(window: nextWindowID, active: true)
            }
        }

        private func finishDrawWithoutPresent(reason: String) {
            drawInFlight = false
            drawFailureLogCount &+= 1
            if drawFailureLogCount <= 12 || drawFailureLogCount.isMultiple(of: 120) {
                VisionXRuntimeLog.write(
                    "UI GLX composite draw skipped reason=\(reason) window=\(glxWindowID ?? 0) frameSerial=\(glxFrame?.serial ?? 0) count=\(drawFailureLogCount)"
                )
            }
            scheduleDrawRetry()
        }

        private func scheduleDrawRetry() {
            guard !drawRetryScheduled else {
                return
            }
            drawRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
                guard let self else {
                    return
                }
                self.drawRetryScheduled = false
                self.drawView()
            }
        }

        private func reportPresentedIfNeeded(_ frame: VisionGLMetalFrame) {
            guard frame.drawable != 0, frame.swapSerial != 0 else {
                return
            }

            presentedSwapLock.lock()
            let inserted = presentedSwapSerials.insert(frame.swapSerial).inserted
            if inserted {
                presentedSwapSerialOrder.append(frame.swapSerial)
                if presentedSwapSerialOrder.count > 256 {
                    let overflow = presentedSwapSerialOrder.count - 256
                    let removed = presentedSwapSerialOrder.prefix(overflow)
                    presentedSwapSerialOrder.removeFirst(overflow)
                    for serial in removed {
                        presentedSwapSerials.remove(serial)
                    }
                }
            }
            presentedSwapLock.unlock()

            if inserted {
                XOrgBridge.reportGLXSwapPresented(drawable: frame.drawable, swapSerial: frame.swapSerial)
            }
        }

        private func resetPresentedSwapHistory() {
            presentedSwapLock.lock()
            presentedSwapSerials.removeAll(keepingCapacity: true)
            presentedSwapSerialOrder.removeAll(keepingCapacity: true)
            presentedSwapLock.unlock()
        }

        deinit {
            displayLink?.invalidate()
            if let glxWindowID {
                XOrgBridge.setGLXWindowPresenterActive(window: glxWindowID, active: false)
            }
        }

        private final class DisplayLinkProxy: NSObject {
            weak var coordinator: Coordinator?

            init(coordinator: Coordinator) {
                self.coordinator = coordinator
            }

            @MainActor
            @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
                coordinator?.displayLinkDidFire()
            }
        }
    }
}

private struct XWindowGLXTextureView: UIViewRepresentable {
    var windowID: XID
    var frame: VisionGLMetalFrame
    var frameProvider: @MainActor () -> VisionGLMetalFrame?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: frame.texture.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 120
        view.contentScaleFactor = 1
        view.autoResizeDrawable = false
        view.isOpaque = true
        view.backgroundColor = .black
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = true
        }
        view.layer.magnificationFilter = .nearest
        view.layer.minificationFilter = .nearest
        view.layer.contentsScale = 1
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.update(windowID: windowID, frame: frame, frameProvider: frameProvider)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.device = frame.texture.device
        context.coordinator.view = uiView
        context.coordinator.update(windowID: windowID, frame: frame, frameProvider: frameProvider)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
        uiView.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {
        private var frame: VisionGLMetalFrame?
        private var commandQueue: MTLCommandQueue?
        private var commandQueueDevice: MTLDevice?
        private var frameProvider: (@MainActor () -> VisionGLMetalFrame?)?
        private var displayLink: CADisplayLink?
        private var displayLinkProxy: DisplayLinkProxy?
        private var drawInFlight = false
        private var drawScheduled = false
        private var drawRetryScheduled = false
        private var needsDisplayLinkDraw = false
        private var lastDrawnSerial: UInt64 = 0
        private var drawLogCount: UInt64 = 0
        private var drawFailureLogCount: UInt64 = 0
        private var drawScheduleSkipLogCount: UInt64 = 0
        private var displayLinkTraceCount: UInt64 = 0
        private var lastGLXTraceDrawUptime: TimeInterval = 0
        private var lastGLXTraceCompleteUptime: TimeInterval = 0
        private var lastGLXTracePresentedUptime: TimeInterval = 0
        private let traceTimingLock = NSLock()
        private let presentedSwapLock = NSLock()
        private var presentedSwapSerials: Set<UInt64> = []
        private var presentedSwapSerialOrder: [UInt64] = []
        private var windowID: XID?
        weak var view: MTKView?

        @MainActor
        func update(windowID: XID, frame: VisionGLMetalFrame, frameProvider: @escaping @MainActor () -> VisionGLMetalFrame?) {
            updateWindowID(windowID)
            self.frameProvider = frameProvider
            startDisplayLink()
            updateLatestFrame(frame, drawImmediately: true)
        }

        @MainActor
        private func updateWindowID(_ nextWindowID: XID) {
            if windowID == nextWindowID {
                return
            }
            if let windowID {
                XOrgBridge.setGLXWindowPresenterActive(window: windowID, active: false)
            }
            windowID = nextWindowID
            resetPresentedSwapHistory()
            XOrgBridge.setGLXWindowPresenterActive(window: nextWindowID, active: true)
        }

        @MainActor
        func startDisplayLink() {
            guard displayLink == nil else {
                return
            }
            let proxy = DisplayLinkProxy(coordinator: self)
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.displayLinkDidFire(_:)))
            link.preferredFramesPerSecond = 120
            link.add(to: .main, forMode: .common)
            displayLinkProxy = proxy
            displayLink = link
        }

        @MainActor
        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
            displayLinkProxy = nil
            if let windowID {
                XOrgBridge.setGLXWindowPresenterActive(window: windowID, active: false)
            }
            windowID = nil
        }

        @MainActor
        func displayLinkDidFire() {
            var needsDraw = needsDisplayLinkDraw
            if let latestFrame = frameProvider?() {
                let previousSerial = frame?.serial
                needsDraw = needsDraw || previousSerial != latestFrame.serial
                traceDisplayLink(needsDraw: needsDraw)
                updateLatestFrame(latestFrame, drawImmediately: false)
                if needsDraw {
                    needsDisplayLinkDraw = false
                    drawView()
                }
                return
            }
            traceDisplayLink(needsDraw: needsDraw)
            if needsDraw {
                needsDisplayLinkDraw = false
                drawView()
            }
        }

        @MainActor
        private func updateLatestFrame(_ frame: VisionGLMetalFrame, drawImmediately: Bool) {
            let previousSerial = self.frame?.serial
            let isNewFrame = previousSerial != frame.serial
            self.frame = frame
            if commandQueue == nil || commandQueueDevice !== frame.texture.device {
                commandQueue = frame.texture.device.makeCommandQueue()
                commandQueueDevice = frame.texture.device
            }
            let nextDrawableSize = CGSize(width: frame.width, height: frame.height)
            let sizeChanged = view?.drawableSize != nextDrawableSize
            view?.drawableSize = nextDrawableSize
            if isNewFrame || sizeChanged {
                if drawImmediately {
                    drawView()
                } else {
                    needsDisplayLinkDraw = true
                }
            }
        }

        @MainActor
        private func drawView() {
            guard !drawInFlight else {
                traceDrawScheduleSkip(reason: "in-flight")
                return
            }
            guard !drawScheduled else {
                traceDrawScheduleSkip(reason: "scheduled")
                return
            }
            guard let view else {
                traceDrawScheduleSkip(reason: "no-view")
                return
            }
            drawScheduled = true
            if visionXGLXDirectDrawEnabled {
                view.draw()
            } else {
                view.setNeedsDisplay()
            }
        }

        private func traceDisplayLink(needsDraw: Bool) {
            guard visionXGLXFrameTraceEnabled else {
                return
            }
            displayLinkTraceCount &+= 1
            if displayLinkTraceCount <= 12 || displayLinkTraceCount.isMultiple(of: 120) || needsDraw {
                VisionXRuntimeLog.write(
                    "GLX frame trace textureDisplayLink count=\(displayLinkTraceCount) needsDraw=\(needsDraw ? 1 : 0) frameSerial=\(frame?.serial ?? 0) inFlight=\(drawInFlight ? 1 : 0) scheduled=\(drawScheduled ? 1 : 0)"
                )
            }
        }

        private func traceDrawScheduleSkip(reason: String) {
            guard visionXGLXFrameTraceEnabled else {
                return
            }
            drawScheduleSkipLogCount &+= 1
            if drawScheduleSkipLogCount <= 12 || drawScheduleSkipLogCount.isMultiple(of: 120) {
                VisionXRuntimeLog.write(
                    "GLX frame trace textureDrawRequest skipped reason=\(reason) count=\(drawScheduleSkipLogCount) frameSerial=\(frame?.serial ?? 0) inFlight=\(drawInFlight ? 1 : 0) scheduled=\(drawScheduled ? 1 : 0)"
                )
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            drawScheduled = false
            guard !drawInFlight else {
                return
            }
            guard let frame else {
                return
            }
            drawInFlight = true
            guard let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                finishDrawWithoutPresent(frame: frame, reason: "drawable-unavailable")
                return
            }
            let drawableWaitStart = ProcessInfo.processInfo.systemUptime
            guard let drawable = view.currentDrawable else {
                finishDrawWithoutPresent(frame: frame, reason: "drawable-unavailable")
                return
            }
            let drawableWaitMS = (ProcessInfo.processInfo.systemUptime - drawableWaitStart) * 1000
            guard drawable.texture.width == frame.width,
                  drawable.texture.height == frame.height else {
                view.drawableSize = CGSize(width: frame.width, height: frame.height)
                finishDrawWithoutPresent(
                    frame: frame,
                    reason: "drawable-size-mismatch expected=\(frame.width)x\(frame.height) actual=\(drawable.texture.width)x\(drawable.texture.height)"
                )
                return
            }
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                finishDrawWithoutPresent(frame: frame, reason: "blit-encoder-unavailable")
                return
            }

            let copyWidth = min(frame.texture.width, drawable.texture.width)
            let copyHeight = min(frame.texture.height, drawable.texture.height)
            if copyWidth > 0, copyHeight > 0 {
                blitEncoder.copy(
                    from: frame.texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                    to: drawable.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
            blitEncoder.endEncoding()
#if !targetEnvironment(simulator)
            drawable.addPresentedHandler { [weak self] _ in
                self?.traceFrameLifecycle("texturePresented", frame: frame)
                self?.reportPresentedIfNeeded(frame)
            }
#endif
            commandBuffer.present(drawable)
            let windowID = self.windowID
            commandBuffer.addCompletedHandler { _ in
                self.traceFrameLifecycle("textureComplete", frame: frame)
                if let windowID {
                    XOrgBridge.setGLXWindowPresenterActive(window: windowID, active: true)
                }
#if targetEnvironment(simulator)
                self.reportPresentedIfNeeded(frame)
#endif
                DispatchQueue.main.async {
                    self.drawInFlight = false
                    self.drawRetryScheduled = false
                    if self.frame?.serial != frame.serial {
                        self.needsDisplayLinkDraw = true
                    }
                }
            }
            commandBuffer.commit()

            if frame.serial != lastDrawnSerial {
                if visionXGLXFrameTraceEnabled {
                    let now = ProcessInfo.processInfo.systemUptime
                    let delta = lastGLXTraceDrawUptime == 0 ? 0 : now - lastGLXTraceDrawUptime
                    lastGLXTraceDrawUptime = now
                    VisionXRuntimeLog.write(
                        String(format: "GLX frame trace textureDraw frameSerial=%llu swapSerial=%llu dtMS=%.3f drawableWaitMS=%.3f transform=%.6f",
                               frame.serial,
                               frame.swapSerial,
                               delta * 1000,
                               drawableWaitMS,
                               Double(frame.transformSignature))
                    )
                }
                lastDrawnSerial = frame.serial
                drawLogCount &+= 1
                if drawLogCount <= 12 || frame.serial.isMultiple(of: 120) {
                    VisionXRuntimeLog.write(
                        "UI GLX draw window serial=\(frame.serial) draws=\(frame.drawCallCount) clears=\(frame.clearCount) transform=\(frame.transformSignature)"
                    )
                }
            }
        }

        private func finishDrawWithoutPresent(frame: VisionGLMetalFrame, reason: String) {
            drawInFlight = false
            drawFailureLogCount &+= 1
            if drawFailureLogCount <= 12 || drawFailureLogCount.isMultiple(of: 120) {
                VisionXRuntimeLog.write(
                    "UI GLX draw skipped reason=\(reason) window=\(windowID ?? 0) frameSerial=\(frame.serial) count=\(drawFailureLogCount)"
                )
            }
            scheduleDrawRetry()
        }

        private func scheduleDrawRetry() {
            guard !drawRetryScheduled else {
                return
            }
            drawRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
                guard let self else {
                    return
                }
                self.drawRetryScheduled = false
                self.drawView()
            }
        }

        private func traceFrameLifecycle(_ event: String, frame: VisionGLMetalFrame) {
            guard visionXGLXFrameTraceEnabled else {
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            traceTimingLock.lock()
            let previous: TimeInterval
            if event == "texturePresented" {
                previous = lastGLXTracePresentedUptime
                lastGLXTracePresentedUptime = now
            } else {
                previous = lastGLXTraceCompleteUptime
                lastGLXTraceCompleteUptime = now
            }
            traceTimingLock.unlock()

            let delta = previous == 0 ? 0 : now - previous
            VisionXRuntimeLog.write(
                String(format: "GLX frame trace %@ frameSerial=%llu swapSerial=%llu dtMS=%.3f transform=%.6f",
                       event,
                       frame.serial,
                       frame.swapSerial,
                       delta * 1000,
                       Double(frame.transformSignature))
            )
        }

        private func reportPresentedIfNeeded(_ frame: VisionGLMetalFrame) {
            guard frame.drawable != 0, frame.swapSerial != 0 else {
                return
            }

            presentedSwapLock.lock()
            let inserted = presentedSwapSerials.insert(frame.swapSerial).inserted
            if inserted {
                presentedSwapSerialOrder.append(frame.swapSerial)
                if presentedSwapSerialOrder.count > 256 {
                    let overflow = presentedSwapSerialOrder.count - 256
                    let removed = presentedSwapSerialOrder.prefix(overflow)
                    presentedSwapSerialOrder.removeFirst(overflow)
                    for serial in removed {
                        presentedSwapSerials.remove(serial)
                    }
                }
            }
            presentedSwapLock.unlock()

            if inserted {
                XOrgBridge.reportGLXSwapPresented(drawable: frame.drawable, swapSerial: frame.swapSerial)
            }
        }

        private func resetPresentedSwapHistory() {
            presentedSwapLock.lock()
            presentedSwapSerials.removeAll(keepingCapacity: true)
            presentedSwapSerialOrder.removeAll(keepingCapacity: true)
            presentedSwapLock.unlock()
        }

        deinit {
            displayLink?.invalidate()
            if let windowID {
                XOrgBridge.setGLXWindowPresenterActive(window: windowID, active: false)
            }
        }

        private final class DisplayLinkProxy: NSObject {
            weak var coordinator: Coordinator?

            init(coordinator: Coordinator) {
                self.coordinator = coordinator
            }

            @MainActor
            @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
                coordinator?.displayLinkDidFire()
            }
        }
    }
}

private struct XWindowMetalTextureView: UIViewRepresentable {
    var snapshot: XWindowPixelSnapshot

    static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(device: MTLCreateSystemDefaultDevice())
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.contentScaleFactor = 1
        view.autoResizeDrawable = false
        view.isOpaque = true
        view.backgroundColor = .black
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = true
        }
        view.layer.magnificationFilter = .nearest
        view.layer.minificationFilter = .nearest
        view.layer.contentsScale = 1
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.update(snapshot: snapshot)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.view = uiView
        context.coordinator.update(snapshot: snapshot)
    }

    final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {
        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private var texture: MTLTexture?
        private var textureSize = CGSize.zero
        private var lastFullUpdateSerial: UInt64?
        private var lastDirtyUpdateSerial: UInt64?
        private var drawInFlight = false
        private var drawRetryScheduled = false
        private var pendingSnapshot: XWindowPixelSnapshot?
        private var pendingRequiresFullUpload = false
        private var pendingDirtyRect: XRectangle?
        weak var view: MTKView?

        init(device: MTLDevice?) {
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            super.init()
        }

        @MainActor
        func update(snapshot: XWindowPixelSnapshot) {
            update(snapshot: snapshot, forceFullUpload: false)
        }

        @MainActor
        private func update(snapshot: XWindowPixelSnapshot, forceFullUpload: Bool) {
            update(snapshot: snapshot, forceFullUpload: forceFullUpload, dirtyRectsOverride: nil)
        }

        @MainActor
        private func update(snapshot: XWindowPixelSnapshot, forceFullUpload: Bool, dirtyRectsOverride: [XRectangle]?) {
            if drawInFlight {
                queuePending(snapshot: snapshot, forceFullUpload: forceFullUpload)
                return
            }

            guard let device else {
                return
            }

            var didUpdateTexture = false
            let pixelBuffer = snapshot.fullBuffer
            let width = max(1, pixelBuffer.width)
            let height = max(1, pixelBuffer.height)
            if texture?.width != width || texture?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                descriptor.usage = [.shaderRead]
                descriptor.storageMode = .shared
                texture = device.makeTexture(descriptor: descriptor)
                textureSize = CGSize(width: width, height: height)
                lastFullUpdateSerial = nil
                lastDirtyUpdateSerial = nil
            }

            guard let texture else {
                return
            }

            var uploadedFullBuffer = forceFullUpload || lastFullUpdateSerial != snapshot.fullUpdateSerial
            if !uploadedFullBuffer,
               let dirtyRectsOverride,
               !dirtyRectsOverride.allSatisfy({ canUploadDirtyRect($0, from: pixelBuffer, to: texture) }) {
                uploadedFullBuffer = true
            }
            if uploadedFullBuffer {
                pixelBuffer.bgraData.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return
                    }
                    texture.replace(
                        region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: baseAddress,
                        bytesPerRow: pixelBuffer.bytesPerRow
                    )
                }
                lastFullUpdateSerial = snapshot.fullUpdateSerial
                lastDirtyUpdateSerial = snapshot.dirtyUpdateSerial
                didUpdateTexture = true
            }

            if !uploadedFullBuffer, let dirtyRectsOverride {
                for dirtyRect in dirtyRectsOverride {
                    uploadDirtyRect(dirtyRect, from: pixelBuffer, to: texture)
                }
                lastDirtyUpdateSerial = snapshot.dirtyUpdateSerial
                didUpdateTexture = true
            } else if !uploadedFullBuffer,
               let dirtyRect = snapshot.dirtyRect,
               lastDirtyUpdateSerial != snapshot.dirtyUpdateSerial,
               canUploadDirtyRect(dirtyRect, from: pixelBuffer, to: texture) {
                uploadDirtyRect(dirtyRect, from: pixelBuffer, to: texture)
                lastDirtyUpdateSerial = snapshot.dirtyUpdateSerial
                didUpdateTexture = true
            }

            if didUpdateTexture, let view {
                view.drawableSize = textureSize
                view.draw()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard !drawInFlight else {
                return
            }
            drawInFlight = true
            guard
                let commandQueue,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else {
                drawInFlight = false
                return
            }
            guard let drawable = view.currentDrawable else {
                drawInFlight = false
                scheduleDrawRetry()
                return
            }
            let expectedDrawableWidth = max(1, Int(round(textureSize.width)))
            let expectedDrawableHeight = max(1, Int(round(textureSize.height)))
            guard drawable.texture.width == expectedDrawableWidth,
                  drawable.texture.height == expectedDrawableHeight else {
                view.drawableSize = textureSize
                drawInFlight = false
                scheduleDrawRetry()
                return
            }

            let clearDescriptor = MTLRenderPassDescriptor()
            clearDescriptor.colorAttachments[0].texture = drawable.texture
            clearDescriptor.colorAttachments[0].loadAction = .clear
            clearDescriptor.colorAttachments[0].storeAction = .store
            clearDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            commandBuffer.makeRenderCommandEncoder(descriptor: clearDescriptor)?.endEncoding()

            if let texture {
                let copyWidth = min(texture.width, drawable.texture.width)
                let copyHeight = min(texture.height, drawable.texture.height)
                if copyWidth > 0, copyHeight > 0, let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                    blitEncoder.copy(
                        from: texture,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                        to: drawable.texture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    blitEncoder.endEncoding()
                }
            }

            commandBuffer.present(drawable)
            commandBuffer.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    self.drawInFlight = false
                    self.drawRetryScheduled = false
                    guard let pendingSnapshot = self.pendingSnapshot else {
                        return
                    }
                    let forceFullUpload = self.pendingRequiresFullUpload
                    let dirtyRect = self.pendingDirtyRect
                    self.pendingSnapshot = nil
                    self.pendingRequiresFullUpload = false
                    self.pendingDirtyRect = nil
                    self.update(snapshot: pendingSnapshot, forceFullUpload: forceFullUpload, dirtyRectsOverride: dirtyRect.map { [$0] })
                }
            }
            commandBuffer.commit()
        }

        private func scheduleDrawRetry() {
            guard !drawRetryScheduled else {
                return
            }
            drawRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
                guard let self else {
                    return
                }
                self.drawRetryScheduled = false
                self.view?.draw()
            }
        }

        @MainActor
        private func queuePending(snapshot: XWindowPixelSnapshot, forceFullUpload: Bool) {
            pendingSnapshot = snapshot
            guard !forceFullUpload,
                  !pendingRequiresFullUpload,
                  let texture,
                  texture.width == snapshot.fullBuffer.width,
                  texture.height == snapshot.fullBuffer.height,
                  lastFullUpdateSerial == snapshot.fullUpdateSerial,
                  let dirtyRect = snapshot.dirtyRect,
                  canUploadDirtyRect(dirtyRect, from: snapshot.fullBuffer, to: texture) else {
                pendingRequiresFullUpload = true
                pendingDirtyRect = nil
                return
            }

            pendingDirtyRect = pendingDirtyRect.map { $0.union(dirtyRect) } ?? dirtyRect
        }

        private func canUploadDirtyRect(_ rect: XRectangle, from pixelBuffer: XWindowPixelBuffer, to texture: MTLTexture) -> Bool {
            rect.x >= 0 &&
                rect.y >= 0 &&
                rect.width > 0 &&
                rect.height > 0 &&
                rect.x + rect.width <= texture.width &&
                rect.y + rect.height <= texture.height &&
                rect.x + rect.width <= pixelBuffer.width &&
                rect.y + rect.height <= pixelBuffer.height &&
                pixelBuffer.bytesPerRow >= pixelBuffer.width * 4 &&
                pixelBuffer.bgraData.count >= pixelBuffer.bytesPerRow * pixelBuffer.height
        }

        private func uploadDirtyRect(_ rect: XRectangle, from pixelBuffer: XWindowPixelBuffer, to texture: MTLTexture) {
            guard canUploadDirtyRect(rect, from: pixelBuffer, to: texture) else {
                return
            }

            pixelBuffer.bgraData.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                let sourceOffset = rect.y * pixelBuffer.bytesPerRow + rect.x * 4
                texture.replace(
                    region: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress.advanced(by: sourceOffset),
                    bytesPerRow: pixelBuffer.bytesPerRow
                )
            }
        }
    }
}
#endif

private struct CRTWindowShaderEffect: ViewModifier {
    var options: XWindowVisualOptions
    var size: CGSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if options.crtEnabled {
            if options.warbleIntensity > 0.001 {
                TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { context in
                    content.layerEffect(
                        shader(time: context.date.timeIntervalSinceReferenceDate),
                        maxSampleOffset: maxSampleOffset
                    )
                }
            } else {
                content.layerEffect(
                    shader(time: 0),
                    maxSampleOffset: maxSampleOffset
                )
            }
        } else {
            content
        }
    }

    private var maxSampleOffset: CGSize {
        CGSize(
            width: max(4, size.width * 0.04),
            height: max(4, size.height * 0.04)
        )
    }

    private func shader(time: TimeInterval) -> Shader {
        ShaderLibrary.default.crtWindowShader(
            .float2(Float(size.width), Float(size.height)),
            .float(Float(time.truncatingRemainder(dividingBy: 3600))),
            .float(Float(options.scanlineIntensity)),
            .float(Float(options.phosphorMaskIntensity)),
            .float(Float(options.glowIntensity)),
            .float(Float(options.vignetteIntensity)),
            .float(Float(options.curvatureIntensity)),
            .float(Float(options.warbleIntensity))
        )
    }
}

private struct XWindowCursorView: View {
    var body: some View {
        ZStack {
            XWindowCursorShape()
                .stroke(.white, lineWidth: 3)
            XWindowCursorShape()
                .fill(.black)
        }
    }
}

private struct XWindowCursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.08, 0.02))
        path.addLine(to: point(0.08, 0.82))
        path.addLine(to: point(0.30, 0.63))
        path.addLine(to: point(0.45, 0.98))
        path.addLine(to: point(0.62, 0.91))
        path.addLine(to: point(0.47, 0.58))
        path.addLine(to: point(0.83, 0.58))
        path.closeSubpath()
        return path
    }
}

private struct XWindowPlaceholder: View {
    var window: XTopLevelWindow

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 42))
            Text(window.title.isEmpty ? "Window \(window.id)" : window.title)
                .font(.headline)
            Text("\(window.frame.width)x\(window.frame.height)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .frame(width: window.contentSize.width, height: window.contentSize.height)
        .contentShape(Rectangle())
    }
}

private extension XTopLevelWindow {
    var contentSize: CGSize {
        CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
    }

    var xWindowSize: CGSize {
        CGSize(width: max(1, frame.width), height: max(1, frame.height))
    }
}

private extension XRectangle {
    func contains(_ other: XRectangle) -> Bool {
        other.x >= x &&
            other.y >= y &&
            other.x + other.width <= x + width &&
            other.y + other.height <= y + height
    }

    func union(_ other: XRectangle) -> XRectangle {
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width)
        let maxY = max(y + height, other.y + other.height)
        return XRectangle(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private extension XPointerEvent.Kind {
    var shouldLog: Bool {
        switch self {
        case .motion:
            return false
        case .buttonPress, .buttonRelease, .enter, .leave:
            return true
        }
    }

    var logName: String {
        switch self {
        case .motion:
            return "motion"
        case .buttonPress(let button):
            return "buttonPress(\(button.rawValue))"
        case .buttonRelease(let button):
            return "buttonRelease(\(button.rawValue))"
        case .enter:
            return "enter"
        case .leave:
            return "leave"
        }
    }
}

private struct X11KeyMapping {
    var keycode: UInt8
    var needsShift: Bool
}

private struct ActiveKeyDispatch {
    var modifiers: [UInt8]
}

private enum KeyDispatchPhase {
    case down
    case repeated
    case up
    case cancelled

    var logName: String {
        switch self {
        case .down:
            return "down"
        case .repeated:
            return "repeat"
        case .up:
            return "up"
        case .cancelled:
            return "cancelled"
        }
    }
}

private enum X11KeyMapper {
    static func mapping(for press: KeyPress) -> X11KeyMapping? {
        switch press.key {
        case .escape:
            return X11KeyMapping(keycode: 9, needsShift: false)
        case .delete:
            return X11KeyMapping(keycode: 22, needsShift: false)
        case .deleteForward:
            return X11KeyMapping(keycode: 119, needsShift: false)
        case .tab:
            return X11KeyMapping(keycode: 23, needsShift: false)
        case .space:
            return X11KeyMapping(keycode: 65, needsShift: false)
        case .return:
            return X11KeyMapping(keycode: 36, needsShift: false)
        case .upArrow:
            return X11KeyMapping(keycode: 111, needsShift: false)
        case .downArrow:
            return X11KeyMapping(keycode: 116, needsShift: false)
        case .leftArrow:
            return X11KeyMapping(keycode: 113, needsShift: false)
        case .rightArrow:
            return X11KeyMapping(keycode: 114, needsShift: false)
        case .home:
            return X11KeyMapping(keycode: 110, needsShift: false)
        case .end:
            return X11KeyMapping(keycode: 115, needsShift: false)
        case .pageUp:
            return X11KeyMapping(keycode: 112, needsShift: false)
        case .pageDown:
            return X11KeyMapping(keycode: 117, needsShift: false)
        default:
            break
        }

        let text = press.characters.isEmpty ? String(press.key.character) : press.characters
        return mapping(forText: text)
    }

#if canImport(UIKit)
    @MainActor
    static func mapping(for key: UIKey) -> X11KeyMapping? {
        switch Int(key.keyCode.rawValue) {
        case 0x28:
            return X11KeyMapping(keycode: 36, needsShift: false)
        case 0x29:
            return X11KeyMapping(keycode: 9, needsShift: false)
        case 0x2a:
            return X11KeyMapping(keycode: 22, needsShift: false)
        case 0x2b:
            return X11KeyMapping(keycode: 23, needsShift: false)
        case 0x2c:
            return X11KeyMapping(keycode: 65, needsShift: false)
        case 0x3a...0x43:
            return X11KeyMapping(keycode: UInt8(67 + Int(key.keyCode.rawValue) - 0x3a), needsShift: false)
        case 0x44:
            return X11KeyMapping(keycode: 95, needsShift: false)
        case 0x45:
            return X11KeyMapping(keycode: 96, needsShift: false)
        case 0x49:
            return X11KeyMapping(keycode: 118, needsShift: false)
        case 0x4a:
            return X11KeyMapping(keycode: 110, needsShift: false)
        case 0x4b:
            return X11KeyMapping(keycode: 112, needsShift: false)
        case 0x4c:
            return X11KeyMapping(keycode: 119, needsShift: false)
        case 0x4d:
            return X11KeyMapping(keycode: 115, needsShift: false)
        case 0x4e:
            return X11KeyMapping(keycode: 117, needsShift: false)
        case 0x4f:
            return X11KeyMapping(keycode: 114, needsShift: false)
        case 0x50:
            return X11KeyMapping(keycode: 113, needsShift: false)
        case 0x51:
            return X11KeyMapping(keycode: 116, needsShift: false)
        case 0x52:
            return X11KeyMapping(keycode: 111, needsShift: false)
        default:
            return mapping(forText: key.characters)
                ?? mapping(forText: key.charactersIgnoringModifiers)
        }
    }
#endif

    static func modifierKeycodes(for modifiers: EventModifiers, forceShift: Bool) -> [UInt8] {
        var keycodes = modifierKeycodes(forceShift: forceShift)
        if modifiers.contains(.control) {
            keycodes.append(37)
        }
        if modifiers.contains(.option) {
            keycodes.append(64)
        }
        if modifiers.contains(.command) {
            keycodes.append(133)
        }
        return keycodes
    }

#if canImport(UIKit)
    @MainActor
    static func modifierKeycodes(for modifiers: UIKeyModifierFlags, forceShift: Bool) -> [UInt8] {
        var keycodes = modifierKeycodes(forceShift: forceShift)
        if modifiers.contains(.control) {
            keycodes.append(37)
        }
        if modifiers.contains(.alternate) {
            keycodes.append(64)
        }
        if modifiers.contains(.command) {
            keycodes.append(133)
        }
        return keycodes
    }
#endif

    static func modifierKeycodes(forceShift: Bool) -> [UInt8] {
        forceShift ? [50] : []
    }

    static func mapping(forText text: String) -> X11KeyMapping? {
        guard let scalar = text.unicodeScalars.first else {
            return nil
        }
        return characterMapping(scalar)
    }

    private static func characterMapping(_ scalar: UnicodeScalar) -> X11KeyMapping? {
        let value = scalar.value
        let isUppercaseLetter = value >= 65 && value <= 90

        switch Character(scalar) {
        case "q", "Q": return X11KeyMapping(keycode: 24, needsShift: isUppercaseLetter)
        case "w", "W": return X11KeyMapping(keycode: 25, needsShift: isUppercaseLetter)
        case "e", "E": return X11KeyMapping(keycode: 26, needsShift: isUppercaseLetter)
        case "r", "R": return X11KeyMapping(keycode: 27, needsShift: isUppercaseLetter)
        case "t", "T": return X11KeyMapping(keycode: 28, needsShift: isUppercaseLetter)
        case "y", "Y": return X11KeyMapping(keycode: 29, needsShift: isUppercaseLetter)
        case "u", "U": return X11KeyMapping(keycode: 30, needsShift: isUppercaseLetter)
        case "i", "I": return X11KeyMapping(keycode: 31, needsShift: isUppercaseLetter)
        case "o", "O": return X11KeyMapping(keycode: 32, needsShift: isUppercaseLetter)
        case "p", "P": return X11KeyMapping(keycode: 33, needsShift: isUppercaseLetter)
        case "a", "A": return X11KeyMapping(keycode: 38, needsShift: isUppercaseLetter)
        case "s", "S": return X11KeyMapping(keycode: 39, needsShift: isUppercaseLetter)
        case "d", "D": return X11KeyMapping(keycode: 40, needsShift: isUppercaseLetter)
        case "f", "F": return X11KeyMapping(keycode: 41, needsShift: isUppercaseLetter)
        case "g", "G": return X11KeyMapping(keycode: 42, needsShift: isUppercaseLetter)
        case "h", "H": return X11KeyMapping(keycode: 43, needsShift: isUppercaseLetter)
        case "j", "J": return X11KeyMapping(keycode: 44, needsShift: isUppercaseLetter)
        case "k", "K": return X11KeyMapping(keycode: 45, needsShift: isUppercaseLetter)
        case "l", "L": return X11KeyMapping(keycode: 46, needsShift: isUppercaseLetter)
        case "z", "Z": return X11KeyMapping(keycode: 52, needsShift: isUppercaseLetter)
        case "x", "X": return X11KeyMapping(keycode: 53, needsShift: isUppercaseLetter)
        case "c", "C": return X11KeyMapping(keycode: 54, needsShift: isUppercaseLetter)
        case "v", "V": return X11KeyMapping(keycode: 55, needsShift: isUppercaseLetter)
        case "b", "B": return X11KeyMapping(keycode: 56, needsShift: isUppercaseLetter)
        case "n", "N": return X11KeyMapping(keycode: 57, needsShift: isUppercaseLetter)
        case "m", "M": return X11KeyMapping(keycode: 58, needsShift: isUppercaseLetter)
        case "1": return X11KeyMapping(keycode: 10, needsShift: false)
        case "!": return X11KeyMapping(keycode: 10, needsShift: true)
        case "2": return X11KeyMapping(keycode: 11, needsShift: false)
        case "@": return X11KeyMapping(keycode: 11, needsShift: true)
        case "3": return X11KeyMapping(keycode: 12, needsShift: false)
        case "#": return X11KeyMapping(keycode: 12, needsShift: true)
        case "4": return X11KeyMapping(keycode: 13, needsShift: false)
        case "$": return X11KeyMapping(keycode: 13, needsShift: true)
        case "5": return X11KeyMapping(keycode: 14, needsShift: false)
        case "%": return X11KeyMapping(keycode: 14, needsShift: true)
        case "6": return X11KeyMapping(keycode: 15, needsShift: false)
        case "^": return X11KeyMapping(keycode: 15, needsShift: true)
        case "7": return X11KeyMapping(keycode: 16, needsShift: false)
        case "&": return X11KeyMapping(keycode: 16, needsShift: true)
        case "8": return X11KeyMapping(keycode: 17, needsShift: false)
        case "*": return X11KeyMapping(keycode: 17, needsShift: true)
        case "9": return X11KeyMapping(keycode: 18, needsShift: false)
        case "(": return X11KeyMapping(keycode: 18, needsShift: true)
        case "0": return X11KeyMapping(keycode: 19, needsShift: false)
        case ")": return X11KeyMapping(keycode: 19, needsShift: true)
        case "-": return X11KeyMapping(keycode: 20, needsShift: false)
        case "_": return X11KeyMapping(keycode: 20, needsShift: true)
        case "=": return X11KeyMapping(keycode: 21, needsShift: false)
        case "+": return X11KeyMapping(keycode: 21, needsShift: true)
        case "[": return X11KeyMapping(keycode: 34, needsShift: false)
        case "{": return X11KeyMapping(keycode: 34, needsShift: true)
        case "]": return X11KeyMapping(keycode: 35, needsShift: false)
        case "}": return X11KeyMapping(keycode: 35, needsShift: true)
        case ";": return X11KeyMapping(keycode: 47, needsShift: false)
        case ":": return X11KeyMapping(keycode: 47, needsShift: true)
        case "'": return X11KeyMapping(keycode: 48, needsShift: false)
        case "\"": return X11KeyMapping(keycode: 48, needsShift: true)
        case "`": return X11KeyMapping(keycode: 49, needsShift: false)
        case "~": return X11KeyMapping(keycode: 49, needsShift: true)
        case "\\": return X11KeyMapping(keycode: 51, needsShift: false)
        case "|": return X11KeyMapping(keycode: 51, needsShift: true)
        case ",": return X11KeyMapping(keycode: 59, needsShift: false)
        case "<": return X11KeyMapping(keycode: 59, needsShift: true)
        case ".": return X11KeyMapping(keycode: 60, needsShift: false)
        case ">": return X11KeyMapping(keycode: 60, needsShift: true)
        case "/": return X11KeyMapping(keycode: 61, needsShift: false)
        case "?": return X11KeyMapping(keycode: 61, needsShift: true)
        case " ": return X11KeyMapping(keycode: 65, needsShift: false)
        default: return nil
        }
    }
}

#if canImport(UIKit)
private struct UIKitKeyboardCaptureView: UIViewRepresentable {
    var isActive: Bool
    var focusRequestID: Int
    var windowID: XID
    var onKey: (UIKey, KeyDispatchPhase) -> Void
    var onScroll: (CGFloat, CGPoint) -> Void

    func makeUIView(context: Context) -> KeyboardCaptureUIView {
        let view = KeyboardCaptureUIView()
        view.windowID = windowID
        view.onKey = onKey
        view.onScroll = onScroll
        return view
    }

    func updateUIView(_ uiView: KeyboardCaptureUIView, context: Context) {
        uiView.windowID = windowID
        uiView.onKey = onKey
        uiView.onScroll = onScroll

        if isActive {
            uiView.requestFirstResponder(focusRequestID: focusRequestID, reason: "SwiftUI update")
        } else if uiView.isFirstResponder {
            VisionXRuntimeLog.write("UI keyboard responder resign window=\(windowID)")
            uiView.resignFirstResponder()
        }
    }
}

private final class KeyboardCaptureUIView: UIView, UIGestureRecognizerDelegate {
    var windowID: XID = 0
    var onKey: ((UIKey, KeyDispatchPhase) -> Void)?
    var onScroll: ((CGFloat, CGPoint) -> Void)?
    private var lastFocusRequestID: Int?
    private var scrollRecognizer: UIPanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true

        let scrollRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollRecognizer.allowedScrollTypesMask = .all
        scrollRecognizer.cancelsTouchesInView = false
        scrollRecognizer.delaysTouchesBegan = false
        scrollRecognizer.delaysTouchesEnded = false
        scrollRecognizer.requiresExclusiveTouchType = false
        scrollRecognizer.delegate = self
        addGestureRecognizer(scrollRecognizer)
        self.scrollRecognizer = scrollRecognizer
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        VisionXRuntimeLog.write("UI keyboard responder moved window=\(windowID) attached=\(window != nil)")
        if window != nil, let lastFocusRequestID {
            requestFirstResponder(focusRequestID: lastFocusRequestID, reason: "didMoveToWindow")
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard event?.type == .scroll else {
            return false
        }
        return bounds.contains(point)
    }

    func requestFirstResponder(focusRequestID: Int, reason: String) {
        if lastFocusRequestID == focusRequestID, isFirstResponder {
            return
        }
        lastFocusRequestID = focusRequestID
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.window != nil else {
                VisionXRuntimeLog.write("UI keyboard responder focus deferred window=\(self.windowID) request=\(focusRequestID) reason=\(reason)")
                return
            }
            let became = self.becomeFirstResponder()
            VisionXRuntimeLog.write(
                "UI keyboard responder focus window=\(self.windowID) request=\(focusRequestID) reason=\(reason) became=\(became) isFirst=\(self.isFirstResponder)"
            )
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                handled = true
                VisionXRuntimeLog.write("UI keyboard responder down window=\(windowID) usage=\(key.keyCode.rawValue) chars=\(key.characters)")
                onKey?(key, .down)
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                handled = true
                VisionXRuntimeLog.write("UI keyboard responder up window=\(windowID) usage=\(key.keyCode.rawValue) chars=\(key.characters)")
                onKey?(key, .up)
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                handled = true
                VisionXRuntimeLog.write("UI keyboard responder cancelled window=\(windowID) usage=\(key.keyCode.rawValue) chars=\(key.characters)")
                onKey?(key, .cancelled)
            }
        }
        if !handled {
            super.pressesCancelled(presses, with: event)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        event.type == .scroll
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        guard translation.y != 0 else {
            return
        }

        let location = recognizer.location(in: self)
        VisionXRuntimeLog.write("UI scroll responder window=\(windowID) deltaY=\(translation.y) location=\(location)")
        onScroll?(translation.y, location)
        recognizer.setTranslation(.zero, in: self)
    }
}
#endif

private extension XWindowPixelBuffer {
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: bgraData as CFData) else {
            return nil
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
