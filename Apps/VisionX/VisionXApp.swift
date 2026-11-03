// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import VisionXCore

@main
struct VisionXApp: App {
    @StateObject private var model: VisionXAppModel

    init() {
        VisionXRuntimeLog.configurePersistentLogging()
        XOrgBridge.installRuntimeLogCallback()
        _model = StateObject(wrappedValue: VisionXAppModel())
    }

    var body: some Scene {
        WindowGroup("UHF X11", id: "server-control") {
            ControlWindowRoot()
                .environmentObject(model)
        }
        .defaultSize(width: 820, height: 620)
        .windowResizability(.contentSize)
        .windowStyle(.plain)

        WindowGroup("X Window", for: XWindowHandle.self) { handle in
            XWindowSurfaceView(windowID: handle.wrappedValue?.id)
                .environmentObject(model)
        }
        .defaultSize(width: 320, height: 240)
        #if os(visionOS)
        .defaultWindowPlacement { content, context in
            let size = content.sizeThatFits(.unspecified)
            if let relativeWindow = context.windows.reversed().first(where: { window in
                window.phase != .background
            }) {
                return WindowPlacement(.trailing(relativeWindow), size: size)
            }
            return WindowPlacement(.utilityPanel, size: size)
        }
        #endif
        .windowResizability(.contentSize)
        .windowStyle(.plain)

        #if os(visionOS) && !targetEnvironment(simulator)
        ImmersiveSpace(id: "spatial-desktop") {
            SpatialDesktopView()
                .environmentObject(model)
        }
        #endif
    }
}

struct XWindowHandle: Codable, Hashable {
    var id: XID
}

private struct ControlWindowRoot: View {
    @EnvironmentObject private var model: VisionXAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sceneID = UUID()
    @State private var isRegisteredControlScene = false
    @State private var isRejectedControlScene = false

    var body: some View {
        Group {
            if isRejectedControlScene {
                Color.clear
                    .frame(width: 1, height: 1)
            } else if model.isControlWindowMiniaturized {
                MiniControlView()
                    .frame(width: MiniControlMetrics.windowSize, height: MiniControlMetrics.windowSize)
                    #if os(visionOS)
                    .glassBackgroundEffect(displayMode: .never)
                    #endif
            } else {
                ServerControlView()
                    .frame(width: 820, height: 620)
                    #if os(visionOS)
                    .glassBackgroundEffect(displayMode: .always)
                    #endif
                    .sheet(isPresented: $model.isLicenseNoticePresented) {
                        FirstRunLicenseView()
                    }
            }
        }
        .frame(
            width: model.isControlWindowMiniaturized ? MiniControlMetrics.windowSize : 820,
            height: model.isControlWindowMiniaturized ? MiniControlMetrics.windowSize : 620
        )
        #if os(visionOS)
        .persistentSystemOverlays(model.isControlWindowMiniaturized ? .hidden : .automatic)
        #endif
        .animation(.snappy(duration: 0.18), value: model.isControlWindowMiniaturized)
        .onAppear {
            guard model.controlWindowDidAppear(instance: sceneID) != nil else {
                isRegisteredControlScene = false
                isRejectedControlScene = true
                Task { @MainActor in
                    VisionXRuntimeLog.write("UI dismiss duplicate control scene instance=\(sceneID.uuidString)")
                    dismiss()
                }
                return
            }
            isRejectedControlScene = false
            isRegisteredControlScene = true
        }
        .onDisappear {
            guard isRegisteredControlScene else {
                return
            }
            isRegisteredControlScene = false
            _ = model.controlWindowDidDisappear(instance: sceneID)
        }
    }
}
