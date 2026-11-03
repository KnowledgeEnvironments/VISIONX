// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VisionXCore

@Test
func fontPathBuilderPrependsIndexedUserFontDirectories() throws {
    let root = try TemporaryDirectory()
    let bundledRoot = root.url.appendingPathComponent("bundled", isDirectory: true)
    let userRoot = root.url.appendingPathComponent("user", isDirectory: true)
    let userPack = userRoot.appendingPathComponent("example-pack", isDirectory: true)
    let bundledMisc = bundledRoot.appendingPathComponent("misc", isDirectory: true)

    try FileManager.default.createDirectory(at: userPack, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bundledMisc, withIntermediateDirectories: true)
    try writeFontsDir(
        to: userPack,
        entries: ["sample.pcf custom-sample"]
    )
    try writeFontsDir(
        to: bundledMisc,
        entries: ["fixed.pcf.gz fixed"]
    )

    let configuration = X11FontPathBuilder.build(
        bundledFontRoot: bundledRoot,
        userFontPackRoot: userRoot
    )

    #expect(configuration.userFontDirectories == [userPack.standardizedFileURL.path])
    #expect(configuration.bundledFontDirectories == [bundledMisc.standardizedFileURL.path])
    #expect(configuration.skippedUserFontDirectories.isEmpty)
    #expect(
        configuration.fontPath == [
            userPack.standardizedFileURL.path,
            bundledMisc.standardizedFileURL.path,
            X11FontPathBuilder.builtInsPathElement,
        ].joined(separator: ",")
    )
}

@Test
func fontPathBuilderReportsBitmapFontDirectoriesMissingFontsDir() throws {
    let root = try TemporaryDirectory()
    let userRoot = root.url.appendingPathComponent("user", isDirectory: true)
    let incompletePack = userRoot.appendingPathComponent("needs-index", isDirectory: true)

    try FileManager.default.createDirectory(at: incompletePack, withIntermediateDirectories: true)
    try Data().write(to: incompletePack.appendingPathComponent("sample.pcf", isDirectory: false))

    let configuration = X11FontPathBuilder.build(
        bundledFontRoot: nil,
        userFontPackRoot: userRoot
    )

    #expect(configuration.userFontDirectories.isEmpty)
    #expect(configuration.skippedUserFontDirectories == [incompletePack.standardizedFileURL.path])
    #expect(configuration.fontPath == X11FontPathBuilder.builtInsPathElement)
}

@Test
func fontPathBuilderListsIndexedFontNames() throws {
    let root = try TemporaryDirectory()
    let userPack = root.url.appendingPathComponent("user/example-pack", isDirectory: true)
    let bundledMisc = root.url.appendingPathComponent("bundled/misc", isDirectory: true)
    let skipped = root.url.appendingPathComponent("user/needs-index", isDirectory: true)

    try FileManager.default.createDirectory(at: userPack, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bundledMisc, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skipped, withIntermediateDirectories: true)
    try writeFontsDir(
        to: userPack,
        entries: [
            "sample.pcf custom-sample",
            "fixed.pcf fixed",
            "fixed-alias.pcf fixed",
        ]
    )
    try writeFontsDir(
        to: bundledMisc,
        entries: ["helvR12.pcf -adobe-helvetica-medium-r-normal--12-120-75-75-p-67-iso10646-1"]
    )

    let configuration = X11FontPathConfiguration(
        fontPath: [
            userPack.standardizedFileURL.path,
            bundledMisc.standardizedFileURL.path,
            X11FontPathBuilder.builtInsPathElement,
        ].joined(separator: ","),
        userFontDirectories: [userPack.standardizedFileURL.path],
        skippedUserFontDirectories: [skipped.standardizedFileURL.path],
        bundledFontDirectories: [bundledMisc.standardizedFileURL.path]
    )

    let listing = X11FontPathBuilder.listIndexedFonts(in: configuration)

    #expect(listing.userDirectories == [
        X11IndexedFontDirectory(
            path: userPack.standardizedFileURL.path,
            fontNames: ["custom-sample", "fixed"]
        )
    ])
    #expect(listing.bundledDirectories == [
        X11IndexedFontDirectory(
            path: bundledMisc.standardizedFileURL.path,
            fontNames: ["-adobe-helvetica-medium-r-normal--12-120-75-75-p-67-iso10646-1"]
        )
    ])
    #expect(listing.skippedUserDirectories == [skipped.standardizedFileURL.path])
    #expect(listing.includesBuiltIns)
    #expect(listing.indexedFontCount == 3)
}

@Test
func fontPathBuilderCreatesUserFontPackRoot() throws {
    let root = try TemporaryDirectory()
    let userRoot = root.url.appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("X11ProVision", isDirectory: true)
        .appendingPathComponent("FontPacks", isDirectory: true)

    try X11FontPathBuilder.ensureUserFontPackRoot(userRoot)

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: userRoot.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test
func fontPackInstallerCopiesDirectoryIntoUserFontPackRoot() throws {
    let root = try TemporaryDirectory()
    let source = root.url.appendingPathComponent("Example Fonts", isDirectory: true)
    let destinationRoot = root.url.appendingPathComponent("FontPacks", isDirectory: true)

    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try writeFontsDir(to: source, entries: ["sample.pcf custom-sample"])

    let result = try X11FontPackInstaller.install(source: source, into: destinationRoot)

    #expect(result.destination.hasSuffix("/Example-Fonts"))
    #expect(FileManager.default.fileExists(atPath: "\(result.destination)/fonts.dir"))
}

@Test
func fontPackInstallerDoesNotOverwriteExistingPack() throws {
    let root = try TemporaryDirectory()
    let source = root.url.appendingPathComponent("fonts", isDirectory: true)
    let destinationRoot = root.url.appendingPathComponent("FontPacks", isDirectory: true)

    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: destinationRoot.appendingPathComponent("fonts", isDirectory: true),
        withIntermediateDirectories: true
    )
    try writeFontsDir(to: source, entries: ["fixed.pcf fixed"])

    let result = try X11FontPackInstaller.install(source: source, into: destinationRoot)

    #expect(result.destination.hasSuffix("/fonts-2"))
    #expect(FileManager.default.fileExists(atPath: "\(result.destination)/fonts.dir"))
}

private func writeFontsDir(to directory: URL, entries: [String]) throws {
    let text = ([String(entries.count)] + entries).joined(separator: "\n") + "\n"
    try text.write(
        to: directory.appendingPathComponent("fonts.dir", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("X11FontPathBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
