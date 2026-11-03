// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import SwiftUI
import RealityKit
import UIKit
import UniformTypeIdentifiers
import VisionXCore

struct ServerControlView: View {
    @EnvironmentObject private var model: VisionXAppModel
    @State private var isAboutPresented = false
    @State private var isFontImporterPresented = false
    @State private var isFontListPresented = false
    @State private var isXhostPlusRiskPresented = false
    @State private var fontListing = X11FontListing(
        userDirectories: [],
        bundledDirectories: [],
        skippedUserDirectories: [],
        includesBuiltIns: false
    )
    @State private var fontImportMessage: String?

    var body: some View {
        NavigationSplitView {
            List {
                Section("Server") {
                    HStack {
                        Label(model.state.title, systemImage: model.state.symbolName)
                        Spacer()
                        serverButton
                    }

                    Picker("Address", selection: $model.selectedHost) {
                        ForEach(model.localAddresses, id: \.self) { address in
                            Text(address).tag(address)
                        }
                    }

                    LabeledContent("Display", value: ":\(model.displayNumber)")
                    LabeledContent("TCP Port", value: "\(model.listenPort)")
                    LabeledContent("X.Org", value: XOrgBridge.expectedServerVersion)
                }

                Section("Authentication") {
                    Toggle(isOn: xhostPlusBinding) {
                        Label("xhost +", systemImage: "person.2.badge.key")
                    }
                    .disabled(!model.state.canChangeAccessControl)

                    Text(model.requireMITMagicCookie ? XhostPlusRiskDisclosure.keyBasedText : XhostPlusRiskDisclosure.xhostPlusEnabledText)
                        .font(.caption)
                        .foregroundStyle(model.requireMITMagicCookie ? Color.secondary : Color.orange)

                    LabeledContent("Mode", value: model.accessControlMode)

                    VStack(alignment: .leading, spacing: 8) {
                        AuthenticationCopyRow(
                            title: "Cookie",
                            value: model.cookieHex,
                            buttonTitle: "Copy Cookie"
                        )
                        AuthenticationCopyRow(
                            title: "xauth",
                            value: model.xauthCommand,
                            buttonTitle: "Copy xauth"
                        )
                    }
                    .opacity(model.requireMITMagicCookie ? 1 : 0.45)

                    Button {
                        model.rotateCookie()
                    } label: {
                        Label("Rotate Cookie", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.state.canRotateCookie)
                }

                Section("Fonts") {
                    LabeledContent("User Packs", value: "\(model.fontPathConfiguration.userFontDirectories.count)")
                    LabeledContent("Skipped", value: "\(model.fontPathConfiguration.skippedUserFontDirectories.count)")

                    if let root = model.fontPathConfiguration.userFontPackRoot {
                        Text(root)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }

                    Button {
                        isFontImporterPresented = true
                    } label: {
                        Label("Import Font Pack", systemImage: "folder.badge.plus")
                    }

                    Button {
                        model.refreshX11FontPath()
                    } label: {
                        Label("Rescan Fonts", systemImage: "textformat")
                    }

                    Button {
                        fontListing = model.listX11Fonts()
                        isFontListPresented = true
                    } label: {
                        Label("List Fonts", systemImage: "list.bullet.rectangle")
                    }

                    Text("Imported indexed bitmap font directories are used after server restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Control Window") {
                    Button {
                        isAboutPresented = true
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }

                    Button {
                        hideToMiniControl()
                    } label: {
                        Label("Hide to Mini Control", systemImage: "minus.circle")
                    }
                }

                Section("Experimental") {
                    Toggle(isOn: experimentalGLXBinding) {
                        Label("Experimental GLX", systemImage: "cube.transparent")
                    }
                    .disabled(!model.state.canChangeExperimentalGLX)
                }

                Section("Clients") {
                    if model.clients.isEmpty {
                        Text("No clients")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.clients, id: \.id) { client in
                            ClientRow(client: client)
                        }
                    }
                }
            }
            .navigationTitle(X11ProVisionBrand.appName)
        } detail: {
            TabView {
                WindowRoutingView()
                    .tabItem {
                        Label("Windows", systemImage: "macwindow")
                    }

                VisualOptionsView()
                    .tabItem {
                        Label("Visual", systemImage: "display")
                    }
            }
                .environmentObject(model)
        }
        .overlay {
            NativeXWindowSceneCoordinator()
                .environmentObject(model)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    hideToMiniControl()
                } label: {
                    Label("Mini Control", systemImage: "minus.circle")
                }
            }
        }
        .sheet(isPresented: $isAboutPresented) {
            AboutX11ProVisionView()
        }
        .sheet(isPresented: $isFontListPresented) {
            FontListingView(listing: fontListing)
        }
        .fileImporter(
            isPresented: $isFontImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            handleFontImport(result)
        }
        .alert(
            "Font Packs",
            isPresented: Binding(
                get: { fontImportMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        fontImportMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                fontImportMessage = nil
            }
        } message: {
            Text(fontImportMessage ?? "")
        }
        .alert("Enable xhost +?", isPresented: $isXhostPlusRiskPresented) {
            Button("Use Key-Based Access", role: .cancel) {
                model.xhostPlusEnabled = false
            }
            Button("Enable xhost +", role: .destructive) {
                UserDefaults.standard.set(true, forKey: XhostPlusRiskDisclosure.acknowledgementKey)
                model.xhostPlusEnabled = true
            }
        } message: {
            Text(XhostPlusRiskDisclosure.alertMessage)
        }
    }

    @ViewBuilder
    private var serverButton: some View {
        switch model.state {
        case .running:
            Button(role: .destructive) {
                model.stopServer()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        case .stopping:
            Button(role: .destructive) {
                model.forceStopServer()
            } label: {
                Label("Force Stop", systemImage: "exclamationmark.octagon")
            }
        case .starting:
            Button {
            } label: {
                Label(model.state.title, systemImage: "hourglass")
            }
            .disabled(true)
        case .failed:
            if model.canForceStopServer {
                Button(role: .destructive) {
                    model.forceStopServer()
                } label: {
                    Label("Force Stop", systemImage: "exclamationmark.octagon")
                }
            } else {
                Button {
                    model.startServer()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
            }
        case .stopped:
            Button {
                model.startServer()
            } label: {
                Label("Start", systemImage: "play.fill")
            }
        }
    }

    private func hideToMiniControl() {
        model.hideControlWindowToMini()
    }

    private func handleFontImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var imported = 0
            var failures: [String] = []
            for url in urls {
                do {
                    _ = try model.importFontPack(from: url)
                    imported += 1
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            if failures.isEmpty {
                fontImportMessage = "Imported \(imported) font pack\(imported == 1 ? "" : "s"). Restart the X server to use newly indexed fonts."
            } else {
                fontImportMessage = "Imported \(imported) font pack\(imported == 1 ? "" : "s"). Failed: \(failures.joined(separator: "; "))"
            }
        case .failure(let error):
            fontImportMessage = error.localizedDescription
        }
    }

    private var xhostPlusBinding: Binding<Bool> {
        Binding {
            model.xhostPlusEnabled
        } set: { isEnabled in
            guard isEnabled else {
                model.xhostPlusEnabled = false
                return
            }
            guard !UserDefaults.standard.bool(forKey: XhostPlusRiskDisclosure.acknowledgementKey) else {
                model.xhostPlusEnabled = true
                return
            }
            isXhostPlusRiskPresented = true
        }
    }

    private var experimentalGLXBinding: Binding<Bool> {
        Binding {
            model.experimentalGLXEnabled
        } set: { isEnabled in
            model.experimentalGLXEnabled = isEnabled
        }
    }
}

private enum XhostPlusRiskDisclosure {
    static let acknowledgementKey = "UHF_X11_XHOST_PLUS_RISK_ACKNOWLEDGED_2026_06_17"
    static let keyBasedText = "Recommended: MIT-MAGIC-COOKIE-1 key-based access. This controls who can connect, but X11 session data is still cleartext unless carried through a separate secure tunnel outside UHF X11."
    static let xhostPlusEnabledText = "xhost + disables key-based access. Any local network client will be able to display windows on this headset."
    static let alertMessage = """
    MIT-MAGIC-COOKIE-1 key-based access is recommended for normal use. It controls who can connect, but it does not encrypt X11 session data. Use a separate secure tunnel outside UHF X11 if you need transport encryption.

    Turning on xhost + disables that cookie check. Any local network client will be able to display windows on this headset if it can reach the selected address.
    """
}

private struct AuthenticationCopyRow: View {
    let title: String
    let value: String
    let buttonTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(3)
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label(buttonTitle, systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct FontListingView: View {
    @Environment(\.dismiss) private var dismiss
    let listing: X11FontListing

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    LabeledContent("Indexed Fonts", value: "\(listing.indexedFontCount)")
                    LabeledContent("User Directories", value: "\(listing.userDirectories.count)")
                    LabeledContent("Bundled Directories", value: "\(listing.bundledDirectories.count)")
                    LabeledContent("Built-Ins", value: listing.includesBuiltIns ? "Enabled" : "Disabled")
                }

                FontDirectoryListSection(title: "User Indexed", directories: listing.userDirectories)
                FontDirectoryListSection(title: "Bundled Indexed", directories: listing.bundledDirectories)

                if !listing.skippedUserDirectories.isEmpty {
                    Section("Skipped User Directories") {
                        ForEach(listing.skippedUserDirectories, id: \.self) { path in
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("X11 Fonts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct FontDirectoryListSection: View {
    let title: String
    let directories: [X11IndexedFontDirectory]

    var body: some View {
        Section(title) {
            if directories.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(directories) { directory in
                    DisclosureGroup {
                        Text(directory.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        if directory.fontNames.isEmpty {
                            Text("No indexed font names")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(directory.fontNames, id: \.self) { fontName in
                                Text(fontName)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(directory.displayName)
                            Text("\(directory.fontNames.count) \(directory.fontNames.count == 1 ? "font" : "fonts")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private extension X11IndexedFontDirectory {
    var displayName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}

struct MiniControlView: View {
    @EnvironmentObject private var model: VisionXAppModel

    var body: some View {
        Button {
            showControlWindow()
        } label: {
            MiniControlLogo(isRunning: model.state.isRunning)
                .frame(width: MiniControlMetrics.logoSize, height: MiniControlMetrics.logoSize)
                .accessibilityLabel("Show UHF X11 control window")
        }
        .buttonStyle(.plain)
        .frame(width: MiniControlMetrics.windowSize, height: MiniControlMetrics.windowSize)
        .contentShape(Rectangle())
    }

    private func showControlWindow() {
        model.restoreFullControlWindow()
    }
}

private struct MiniControlLogo: View {
    let isRunning: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image("Minimized_Logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.42), radius: 6, x: 0, y: 3)
                .shadow(color: .white.opacity(0.24), radius: 2)

            Circle()
                .fill(isRunning ? Color.green : Color.secondary)
                .frame(width: MiniControlMetrics.statusDotSize, height: MiniControlMetrics.statusDotSize)
                .padding(1.5)
                .background {
                    Circle()
                        .fill(.black.opacity(0.62))
                }
                .offset(x: -1, y: -1)
        }
    }
}

private enum LicenseAndNetworkNotice {
    static let eulaURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let appInfoURL = URL(string: "https://www.lispm.net/")!
    static let paragraphs = [
        "UHF X11 is freeware provided for retrocomputing, development, and interoperability with X11 clients. It is provided as-is, without warranty, and without any guarantee that a particular X11 client, network, workflow, or system configuration will be compatible, secure, or fit for a particular purpose.",
        "UHF X11 is a classic X11 display server. It implements the standard X11 client/server protocol because that is necessary for compatibility with legacy X11 clients.",
        "The legacy X11 protocol does not encrypt X11 session traffic by itself. X11 clients you allow to connect can exchange user input events, window/display contents, text selections, clipboard data, window titles, and other X11 protocol messages with UHF X11 as the display server.",
        "This notice is about information directed between connected X11 clients and the UHF X11 display server. It does not mean unrelated device, headset, Apple account, or app data is sent to X11 clients.",
        "UHF X11 does not include a built-in VPN, SSH tunnel, or other encrypted tunneling solution. If you need transport security, use a trusted private network or a separately configured secure tunnel appropriate for X11. Sensitive data should not be transferred through legacy X11 protocol connections unless you fully understand and accept the risks.",
        "When xhost + mode is enabled, X11 access control is disabled for testing. Use MIT-MAGIC-COOKIE-1 authentication for normal use, and bind the server to the narrowest appropriate local address.",
        "To the extent permitted by law, the developer is not liable for data loss, security issues, compatibility failures, lost work, or other damages arising from use of the app or from X11 clients you choose to connect.",
        "Unless UHF X11 is accompanied by a separate app license, your use of the app is governed by Apple's Standard Licensed Application End User License Agreement. Project-authored X.Org hw/visionx integration code is distributed under the MIT/X11 license. Bundled X.Org components and X.Org-distributed bitmap fonts retain their upstream license notices, listed in the About box."
    ]
}

private struct FreewareInfoView: View {
    var prominent = false

    var body: some View {
        VStack(alignment: prominent ? .center : .leading, spacing: prominent ? 10 : 8) {
            Text("UHF X11 is freeware. More information is available on the UHF X11 app page.")
                .multilineTextAlignment(prominent ? .center : .leading)
            Link(destination: LicenseAndNetworkNotice.appInfoURL) {
                Label("UHF X11 Fan? Visit us at LISPM.NET.", systemImage: "heart.circle")
            }
            .font(prominent ? .title2 : .body)
            .imageScale(prominent ? .large : .medium)
        }
        .frame(maxWidth: .infinity, alignment: prominent ? .center : .leading)
    }
}

private struct LicenseAndNetworkNoticeText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(LicenseAndNetworkNotice.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
            }
        }
    }
}

struct FirstRunLicenseView: View {
    @EnvironmentObject private var model: VisionXAppModel
    @State private var hasReachedNoticeBottom = false
    @State private var noticeViewportHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text("Ultra High Frequency X11")
                        .font(.largeTitle)
                    Text("License and Network Notice")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 22)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("License and Network Notice")
                    .font(.headline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LicenseAndNetworkNoticeText()
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Color.clear
                            .frame(height: 1)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: FirstRunNoticeBottomPreferenceKey.self,
                                        value: proxy.frame(in: .named(FirstRunNoticeScrollCoordinateSpace.name)).maxY
                                    )
                                }
                            }
                    }
                }
                .coordinateSpace(name: FirstRunNoticeScrollCoordinateSpace.name)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                noticeViewportHeight = proxy.size.height
                            }
                            .onChange(of: proxy.size.height) { _, height in
                                noticeViewportHeight = height
                            }
                    }
                }
                .onPreferenceChange(FirstRunNoticeBottomPreferenceKey.self) { bottomY in
                    guard bottomY.isFinite, noticeViewportHeight > 0 else {
                        return
                    }
                    if bottomY <= noticeViewportHeight + 12 {
                        hasReachedNoticeBottom = true
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 22)

            Divider()

            HStack(spacing: 18) {
                Link("Apple Standard EULA", destination: LicenseAndNetworkNotice.eulaURL)
                Spacer()
                if !hasReachedNoticeBottom {
                    Text("Scroll to the bottom to accept.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.acknowledgeEULA()
                } label: {
                    Label("Accept and Continue", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasReachedNoticeBottom)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
        }
        .frame(width: 760, height: 560)
    }
}

private enum FirstRunNoticeScrollCoordinateSpace {
    static let name = "first-run-notice-scroll"
}

private struct FirstRunNoticeBottomPreferenceKey: PreferenceKey {
    static let defaultValue = CGFloat.infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private struct VisualOptionsView: View {
    @EnvironmentObject private var model: VisionXAppModel

    var body: some View {
        Form {
            Section("CRT Shader") {
                Toggle(isOn: crtEnabledBinding) {
                    Label("Enabled", systemImage: "display")
                }

                VisualOptionSlider(
                    title: "Scanlines",
                    value: visualOptionBinding(\.scanlineIntensity),
                    range: 0...0.7
                )
                .disabled(!model.visualOptions.crtEnabled)

                VisualOptionSlider(
                    title: "Phosphor Mask",
                    value: visualOptionBinding(\.phosphorMaskIntensity),
                    range: 0...0.18
                )
                .disabled(!model.visualOptions.crtEnabled)

                VisualOptionSlider(
                    title: "Glow",
                    value: visualOptionBinding(\.glowIntensity),
                    range: 0...0.6
                )
                .disabled(!model.visualOptions.crtEnabled)

                VisualOptionSlider(
                    title: "Vignette",
                    value: visualOptionBinding(\.vignetteIntensity),
                    range: 0...0.8
                )
                .disabled(!model.visualOptions.crtEnabled)

                VisualOptionSlider(
                    title: "Curvature",
                    value: visualOptionBinding(\.curvatureIntensity),
                    range: 0...0.75
                )
                .disabled(!model.visualOptions.crtEnabled)

                VisualOptionSlider(
                    title: "Warble",
                    value: visualOptionBinding(\.warbleIntensity),
                    range: 0...0.5
                )
                .disabled(!model.visualOptions.crtEnabled)

                Button {
                    model.resetVisualOptions()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
            }

            Section("Window Policy") {
                Picker("Override-Redirect", selection: $model.overrideRedirectPolicy) {
                    ForEach(OverrideRedirectPresentationPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Text(model.overrideRedirectPolicy.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pointer") {
                Toggle(isOn: xCursorEnabledBinding) {
                    Label("X Cursor Overlay", systemImage: "cursorarrow")
                }

                VisualOptionSlider(
                    title: "Cursor Size",
                    value: visualOptionBinding(\.xCursorScale),
                    range: 0.15...1.0
                )
                .disabled(!model.visualOptions.xCursorEnabled)
            }
        }
        .navigationTitle("Visual Options")
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: 12)
        }
    }

    private var crtEnabledBinding: Binding<Bool> {
        Binding {
            model.visualOptions.crtEnabled
        } set: { isEnabled in
            model.visualOptions.crtEnabled = isEnabled
        }
    }

    private var xCursorEnabledBinding: Binding<Bool> {
        Binding {
            model.visualOptions.xCursorEnabled
        } set: { isEnabled in
            model.visualOptions.xCursorEnabled = isEnabled
        }
    }

    private func visualOptionBinding(_ keyPath: WritableKeyPath<XWindowVisualOptions, Double>) -> Binding<Double> {
        Binding {
            model.visualOptions[keyPath: keyPath]
        } set: { value in
            model.visualOptions[keyPath: keyPath] = value
        }
    }
}

private struct VisualOptionSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct AboutX11ProVisionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var symbolicsPoofProgress = 0.0

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(X11ProVisionBrand.fullName)
                        .font(.largeTitle)
                    Text(X11ProVisionBrand.appName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(X11ProVisionBrand.versionText)
                        .foregroundStyle(.secondary)
                    Text("Embedded X.Org \(XOrgBridge.expectedServerVersion)")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    Text(X11ProVisionBrand.copyright)
                    Link(X11ProVisionBrand.website, destination: URL(string: X11ProVisionBrand.website)!)
                    AboutSymbolicsPoofView(reportedProgress: $symbolicsPoofProgress)
                        .frame(width: 340, height: AboutSymbolicsPoof.slotHeight(progress: symbolicsPoofProgress))
                        .padding(.top, AboutSymbolicsPoof.verticalPadding(24, progress: symbolicsPoofProgress))
                        .padding(.bottom, AboutSymbolicsPoof.verticalPadding(22, progress: symbolicsPoofProgress))
                        .clipped()
                }
                .frame(maxWidth: .infinity)

                Divider()

                FreewareInfoView(prominent: true)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("License and Network Notice")
                        .font(.headline)
                    LicenseAndNetworkNoticeText()
                    Link("Apple Standard EULA", destination: LicenseAndNetworkNotice.eulaURL)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Project MIT/X11 License Notice")
                        .font(.headline)
                    Text("VisionX/UHF X11 integration code added under hw/visionx is distributed under the MIT/X11 license.")
                    Text(X11ProVisionBrand.mitLicenseText)
                    Text("Third-Party Notices")
                        .font(.headline)
                    Text(X11ProVisionBrand.thirdPartyNoticeText)
                    Text(X11ProVisionBrand.xorgLicenseSummary)
                    Text(X11ProVisionBrand.xorgOriginalAuthorNotice)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
            .padding(32)
        }
        .coordinateSpace(name: AboutScrollCoordinateSpace.name)
        .frame(width: 860, height: 760)
        .textSelection(.enabled)
    }
}

private enum AboutScrollCoordinateSpace {
    static let name = "about-scroll"
}

private struct AboutSymbolicsPoofView: View {
    @Binding var reportedProgress: Double
    @State private var restingMinY: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let currentMinY = proxy.frame(in: .named(AboutScrollCoordinateSpace.name)).minY
            let progress = AboutSymbolicsPoof.progress(
                currentMinY: currentMinY,
                restingMinY: restingMinY ?? currentMinY
            )

            SymbolicsAboutModelView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(AboutSymbolicsPoof.opacity(progress: progress))
                .scaleEffect(AboutSymbolicsPoof.scale(progress: progress), anchor: .center)
                .rotationEffect(.degrees(AboutSymbolicsPoof.flatRotation(progress: progress)))
                .rotation3DEffect(
                    .degrees(AboutSymbolicsPoof.depthRotation(progress: progress)),
                    axis: (x: 0.35, y: 1.0, z: 0.15),
                    anchor: .center
                )
                .onAppear {
                    updateProgress(currentMinY: currentMinY)
                }
                .onChange(of: currentMinY) { _, minY in
                    updateProgress(currentMinY: minY)
                }
        }
    }

    private func updateProgress(currentMinY: CGFloat) {
        guard currentMinY.isFinite else {
            return
        }
        if restingMinY == nil {
            restingMinY = currentMinY
        }
        let nextProgress = AboutSymbolicsPoof.progress(
            currentMinY: currentMinY,
            restingMinY: restingMinY ?? currentMinY
        )
        guard abs(reportedProgress - nextProgress) > 0.001 else {
            return
        }
        reportedProgress = nextProgress
    }
}

private enum AboutSymbolicsPoof {
    private static let vanishDistance: CGFloat = 288

    static func progress(currentMinY: CGFloat, restingMinY: CGFloat) -> Double {
        let scrolledDistance = max(0, restingMinY - currentMinY)
        return min(1.0, Double(scrolledDistance / vanishDistance))
    }

    static func opacity(progress: Double) -> Double {
        max(0.0, 1.0 - (accelerated(progress) * 3.2))
    }

    static func scale(progress: Double) -> CGFloat {
        let scaledProgress = min(1.0, accelerated(progress) * 1.45)
        return CGFloat(max(0.01, 1.0 - (scaledProgress * 0.99)))
    }

    static func slotHeight(progress: Double) -> CGFloat {
        max(2, 240 * scale(progress: progress))
    }

    static func verticalPadding(_ base: CGFloat, progress: Double) -> CGFloat {
        max(0, base * scale(progress: progress))
    }

    static func flatRotation(progress: Double) -> Double {
        accelerated(progress) * 180
    }

    static func depthRotation(progress: Double) -> Double {
        accelerated(progress) * 260
    }

    private static func accelerated(_ progress: Double) -> Double {
        let clamped = min(1.0, max(0.0, progress))
        return clamped * clamped
    }
}

private struct SymbolicsAboutModelView: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "AboutSymbolics3640", withExtension: "usda") ??
            Bundle.main.url(forResource: "symbolics-3640", withExtension: "usdz") {
            Model3D(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                case .success(let model):
                    model
                        .resizable()
                        .scaledToFit()
                case .failure:
                    fallback
                @unknown default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: "display")
            .font(.system(size: 42))
            .foregroundStyle(.secondary)
    }
}

private struct ClientRow: View {
    var client: XClientInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(client.endpointDescription)
                .lineLimit(1)
            if let setup = client.setup {
                Text("X11 \(setup.protocolMajor).\(setup.protocolMinor) \(setup.authorizationName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WindowRoutingView: View {
    @EnvironmentObject private var model: VisionXAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List {
            Section("X Windows") {
                if listedWindows.isEmpty {
                    ContentUnavailableView(
                        "No X windows",
                        systemImage: "macwindow",
                        description: Text(model.lastTransportMessage)
                    )
                } else {
                    ForEach(listedWindows) { window in
                        WindowRow(window: window)
                            .environmentObject(model)
                    }
                }
            }
        }
        .navigationTitle("Window Routing")
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: 4)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openMappedNativeWindows()
                } label: {
                    Label("Open Native Windows", systemImage: "rectangle.on.rectangle")
                }
                .disabled(listedWindows.isEmpty)
            }
        }
    }

    private var listedWindows: [XTopLevelWindow] {
        model.windows.filter { model.isVisibleInWindowList($0) }
    }

    private func openMappedNativeWindows() {
        for window in model.forceNativeWindowSceneOpenActions() {
            VisionXRuntimeLog.write("UI force-open native X window id=\(window.id)")
            openWindow(value: XWindowHandle(id: window.id))
        }
    }
}

struct NativeXWindowSceneCoordinator: View {
    @EnvironmentObject private var model: VisionXAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .task {
                syncNativeWindows()
            }
            .onChange(of: model.windows) { _, _ in
                syncNativeWindows()
            }
            .onChange(of: model.overrideRedirectPolicy) { _, policy in
                VisionXRuntimeLog.write("UI sync native X windows after override-redirect policy change policy=\(policy.rawValue)")
                syncNativeWindows()
            }
    }

    private func syncNativeWindows() {
        let actions = model.nativeWindowSceneSyncActions()

        for id in actions.dismiss {
            VisionXRuntimeLog.write("UI dismiss native X window from root coordinator id=\(id)")
            dismissWindow(value: XWindowHandle(id: id))
        }

        for window in actions.open {
            VisionXRuntimeLog.write("UI open native X window from root coordinator id=\(window.id)")
            openWindow(value: XWindowHandle(id: window.id))
        }
    }
}

private struct WindowRow: View {
    @EnvironmentObject private var model: VisionXAppModel
    var window: XTopLevelWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(window.title.isEmpty ? "Window \(window.id)" : window.title)
                    Text(window.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    model.close(window: window.id)
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }

            /*
            Picker("Route", selection: routeBinding) {
                Text("Native").tag(XWindowRoute.nativeWindow)
                Text("Immersive").tag(XWindowRoute.immersivePanel)
            }
            .pickerStyle(.segmented)
            .disabled(window.overrideRedirect)
            */
        }
        .padding(.vertical, 4)
    }

    private var routeBinding: Binding<XWindowRoute> {
        Binding {
            window.route == .overrideRedirect ? .nativeWindow : window.route
        } set: { route in
            model.route(window: window.id, to: route)
        }
    }
}

private extension XTopLevelWindow {
    var subtitle: String {
        let classPart = wmClass.className.isEmpty ? "unknown class" : wmClass.className
        return "\(classPart) \(frame.width)x\(frame.height)"
    }
}

private extension VisionXServerState {
    var title: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running(let port):
            return "Running on \(port)"
        case .stopping:
            return "Stopping"
        case .failed:
            return "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .running:
            return "network"
        case .failed:
            return "exclamationmark.triangle"
        case .starting, .stopping:
            return "hourglass"
        case .stopped:
            return "power"
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    var canRotateCookie: Bool {
        if case .stopped = self {
            return true
        }
        return false
    }

    var canChangeAccessControl: Bool {
        if case .stopped = self {
            return true
        }
        return false
    }

    var canChangeExperimentalGLX: Bool {
        if case .stopped = self {
            return true
        }
        return false
    }
}
