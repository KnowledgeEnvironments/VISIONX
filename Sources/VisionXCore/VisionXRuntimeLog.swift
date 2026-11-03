// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import Foundation

public enum VisionXRuntimeLog {
    private static let logger = VisionXRuntimeLogger()

    public static var isEnabled: Bool {
        logger.isEnabled
    }

    public static var currentLogFileURL: URL? {
        logger.currentLogFileURL
    }

    public static func configurePersistentLogging(fileURL: URL? = nil) {
        logger.configurePersistentLogging(fileURL: fileURL)
    }

    public static func write(_ message: @autoclosure () -> String) {
        logger.write("[VisionX] \(message())")
    }

    public static func writeCLog(_ message: String) {
        logger.write("[VisionX C] \(message)")
    }
}

private final class VisionXRuntimeLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var persistentLogHandle: FileHandle?
    private var persistentLogURL: URL?
    let isEnabled: Bool
    private let mirrorsToStandardError: Bool

    init() {
        let value = ProcessInfo.processInfo.environment["VISIONX_RUNTIME_LOG"]
#if DEBUG
        isEnabled = value != "0"
#else
        isEnabled = value == "1"
#endif
        mirrorsToStandardError = ProcessInfo.processInfo.environment["VISIONX_RUNTIME_LOG_STDERR"] == "1"
    }

    var currentLogFileURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return persistentLogURL
    }

    func configurePersistentLogging(fileURL: URL? = nil) {
        guard isEnabled else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            let url = try fileURL ?? defaultLogFileURL()
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)

            persistentLogHandle = handle
            persistentLogURL = url
            writeLocked("persistent log path=\(url.path)")
        } catch {
            writeLocked("persistent log unavailable error=\(error.localizedDescription)")
        }
    }

    func write(_ line: String) {
        guard isEnabled else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        writeLocked(line)
    }

    private func writeLocked(_ line: String) {
        let timestampedLine = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(line)\n"
        if let data = timestampedLine.data(using: .utf8) {
            if mirrorsToStandardError {
                FileHandle.standardError.write(data)
            }
            persistentLogHandle?.write(data)
        }
    }

    private func defaultLogFileURL() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("X11ProVision", isDirectory: true)
            .appendingPathComponent("runtime.log", isDirectory: false)
    }
}
