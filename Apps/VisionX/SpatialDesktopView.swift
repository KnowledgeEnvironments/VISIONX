// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import SwiftUI
import VisionXCore

struct SpatialDesktopView: View {
    @EnvironmentObject private var model: VisionXAppModel

    private var spatialWindows: [XTopLevelWindow] {
        model.windows.filter { $0.route == .immersivePanel && $0.mapState == .mapped }
    }

    var body: some View {
        ZStack {
            ForEach(Array(spatialWindows.enumerated()), id: \.element.id) { index, window in
                SpatialPanel(window: window)
                    .frame(width: 520, height: 340)
                    .offset(x: CGFloat(index % 3 - 1) * 560, y: CGFloat(index / 3) * 380)
            }
        }
    }
}

private struct SpatialPanel: View {
    var window: XTopLevelWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(window.title.isEmpty ? "Window \(window.id)" : window.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(window.frame.width)x\(window.frame.height)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial)

            Rectangle()
                .fill(.black)
                .overlay {
                    Image(systemName: "display")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.secondary)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
