// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

public struct X11FontPackInstallResult: Equatable, Sendable {
    public var source: String
    public var destination: String

    public init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }
}

public enum X11FontPackInstallerError: Error, Equatable, LocalizedError {
    case sourceIsNotDirectory(String)
    case emptySourceName

    public var errorDescription: String? {
        switch self {
        case .sourceIsNotDirectory(let path):
            return "Font pack source is not a directory: \(path)"
        case .emptySourceName:
            return "Font pack source has no usable name."
        }
    }
}

public enum X11FontPackInstaller {
    public static func install(
        source: URL,
        into root: URL,
        fileManager: FileManager = .default
    ) throws -> X11FontPackInstallResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw X11FontPackInstallerError.sourceIsNotDirectory(source.path)
        }

        try X11FontPathBuilder.ensureUserFontPackRoot(root, fileManager: fileManager)

        let baseName = sanitizedDirectoryName(source.lastPathComponent)
        guard !baseName.isEmpty else {
            throw X11FontPackInstallerError.emptySourceName
        }

        let destination = availableDestination(named: baseName, in: root, fileManager: fileManager)
        try fileManager.copyItem(at: source, to: destination)

        return X11FontPackInstallResult(
            source: source.standardizedFileURL.path,
            destination: destination.standardizedFileURL.path
        )
    }

    private static func availableDestination(
        named baseName: String,
        in root: URL,
        fileManager: FileManager
    ) -> URL {
        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func sanitizedDirectoryName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let characters = name.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        return characters.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))
    }
}
