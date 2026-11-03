// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

public struct X11FontPathConfiguration: Equatable, Sendable {
    public var fontPath: String
    public var userFontPackRoot: String?
    public var userFontDirectories: [String]
    public var skippedUserFontDirectories: [String]
    public var bundledFontDirectories: [String]

    public init(
        fontPath: String,
        userFontPackRoot: String? = nil,
        userFontDirectories: [String] = [],
        skippedUserFontDirectories: [String] = [],
        bundledFontDirectories: [String] = []
    ) {
        self.fontPath = fontPath
        self.userFontPackRoot = userFontPackRoot
        self.userFontDirectories = userFontDirectories
        self.skippedUserFontDirectories = skippedUserFontDirectories
        self.bundledFontDirectories = bundledFontDirectories
    }
}

public struct X11IndexedFontDirectory: Equatable, Sendable, Identifiable {
    public var path: String
    public var fontNames: [String]

    public var id: String { path }

    public init(path: String, fontNames: [String]) {
        self.path = path
        self.fontNames = fontNames
    }
}

public struct X11FontListing: Equatable, Sendable {
    public var userDirectories: [X11IndexedFontDirectory]
    public var bundledDirectories: [X11IndexedFontDirectory]
    public var skippedUserDirectories: [String]
    public var includesBuiltIns: Bool

    public init(
        userDirectories: [X11IndexedFontDirectory],
        bundledDirectories: [X11IndexedFontDirectory],
        skippedUserDirectories: [String],
        includesBuiltIns: Bool
    ) {
        self.userDirectories = userDirectories
        self.bundledDirectories = bundledDirectories
        self.skippedUserDirectories = skippedUserDirectories
        self.includesBuiltIns = includesBuiltIns
    }

    public var indexedFontCount: Int {
        userDirectories.reduce(0) { $0 + $1.fontNames.count } +
            bundledDirectories.reduce(0) { $0 + $1.fontNames.count }
    }
}

public enum X11FontPathBuilder {
    public static let builtInsPathElement = "built-ins"

    public static func defaultUserFontPackRoot(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("X11ProVision", isDirectory: true)
            .appendingPathComponent("FontPacks", isDirectory: true)
    }

    public static func ensureUserFontPackRoot(
        _ root: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func build(
        bundledFontRoot: URL?,
        userFontPackRoot: URL?,
        fileManager: FileManager = .default
    ) -> X11FontPathConfiguration {
        let bundledDirectories = bundledFontDirectories(
            bundledFontRoot: bundledFontRoot,
            fileManager: fileManager
        )
        let userScan = userFontDirectories(
            userFontPackRoot: userFontPackRoot,
            fileManager: fileManager
        )
        let pathElements = userScan.indexed + bundledDirectories + [builtInsPathElement]

        return X11FontPathConfiguration(
            fontPath: pathElements.joined(separator: ","),
            userFontPackRoot: userFontPackRoot?.standardizedFileURL.path,
            userFontDirectories: userScan.indexed,
            skippedUserFontDirectories: userScan.skipped,
            bundledFontDirectories: bundledDirectories
        )
    }

    public static func listIndexedFonts(
        in configuration: X11FontPathConfiguration,
        fileManager: FileManager = .default
    ) -> X11FontListing {
        X11FontListing(
            userDirectories: configuration.userFontDirectories.map {
                X11IndexedFontDirectory(path: $0, fontNames: fontNames(in: URL(fileURLWithPath: $0), fileManager: fileManager))
            },
            bundledDirectories: configuration.bundledFontDirectories.map {
                X11IndexedFontDirectory(path: $0, fontNames: fontNames(in: URL(fileURLWithPath: $0), fileManager: fileManager))
            },
            skippedUserDirectories: configuration.skippedUserFontDirectories,
            includesBuiltIns: configuration.fontPath
                .split(separator: ",")
                .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == builtInsPathElement }
        )
    }

    private static func bundledFontDirectories(
        bundledFontRoot: URL?,
        fileManager: FileManager
    ) -> [String] {
        guard let bundledFontRoot else {
            return []
        }

        return ["misc", "75dpi", "100dpi"].compactMap { name in
            let directory = bundledFontRoot.appendingPathComponent(name, isDirectory: true)
            guard hasUsableFontsDir(at: directory, fileManager: fileManager) else {
                return nil
            }
            return directory.standardizedFileURL.path
        }
    }

    private static func userFontDirectories(
        userFontPackRoot: URL?,
        fileManager: FileManager
    ) -> (indexed: [String], skipped: [String]) {
        guard let userFontPackRoot else {
            return ([], [])
        }

        guard directoryExists(userFontPackRoot, fileManager: fileManager) else {
            return ([], [])
        }

        var indexed: [String] = []
        var skipped: [String] = []
        let candidates = candidateFontDirectories(in: userFontPackRoot, fileManager: fileManager)

        for directory in candidates {
            let path = directory.standardizedFileURL.path
            if hasUsableFontsDir(at: directory, fileManager: fileManager) {
                indexed.append(path)
            } else if containsBitmapFontFiles(at: directory, fileManager: fileManager) {
                skipped.append(path)
            }
        }

        return (indexed.sorted(), skipped.sorted())
    }

    private static func candidateFontDirectories(
        in root: URL,
        fileManager: FileManager
    ) -> [URL] {
        var directories = [root]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return directories
        }

        for case let url as URL in enumerator {
            guard isDirectory(url, fileManager: fileManager) else {
                continue
            }
            directories.append(url)
        }

        return directories
    }

    private static func hasUsableFontsDir(at directory: URL, fileManager: FileManager) -> Bool {
        let fontsDir = directory.appendingPathComponent("fonts.dir", isDirectory: false)
        guard fileManager.fileExists(atPath: fontsDir.path) else {
            return false
        }

        guard let text = try? String(contentsOf: fontsDir, encoding: .utf8) else {
            return false
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstLine = lines.first, let count = Int(firstLine), count > 0 else {
            return false
        }

        return lines.count > 1
    }

    private static func fontNames(in directory: URL, fileManager: FileManager) -> [String] {
        let fontsDir = directory.appendingPathComponent("fonts.dir", isDirectory: false)
        guard fileManager.fileExists(atPath: fontsDir.path),
              let text = try? String(contentsOf: fontsDir, encoding: .utf8) else {
            return []
        }

        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else {
                continue
            }
            names.append(String(parts[1]))
        }

        return Array(Set(names)).sorted()
    }

    private static func containsBitmapFontFiles(at directory: URL, fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return contents.contains { url in
            guard isRegularFile(url, fileManager: fileManager) else {
                return false
            }
            return isBitmapFontFilename(url.lastPathComponent)
        }
    }

    private static func isBitmapFontFilename(_ filename: String) -> Bool {
        let lowercased = filename.lowercased()
        return lowercased.hasSuffix(".pcf") ||
            lowercased.hasSuffix(".pcf.gz") ||
            lowercased.hasSuffix(".bdf") ||
            lowercased.hasSuffix(".bdf.gz") ||
            lowercased.hasSuffix(".snf") ||
            lowercased.hasSuffix(".snf.gz")
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ??
            directoryExists(url, fileManager: fileManager)
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ??
            fileManager.fileExists(atPath: url.path)
    }
}
