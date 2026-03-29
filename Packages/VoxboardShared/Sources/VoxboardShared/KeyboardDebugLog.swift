import Foundation
import os

/// Crash-safe, file-backed debug logger for the keyboard extension.
///
/// Writes every entry to disk immediately so the log survives if the OS
/// kills the extension. The main app can read the same file to display logs.
///
/// Memory stats are recorded with each entry via `os_proc_available_memory()`
/// (memory remaining before the OS jettisons the process) and `mach_task_info`
/// (current resident memory of the process).
public final class KeyboardDebugLog: Sendable {
    public static let shared = KeyboardDebugLog()

    private let fileURL: URL?
    private let queue = DispatchQueue(label: "com.voxboard.keyboard-debug-log")

    /// Maximum log size before we truncate old entries (~64 KB).
    private let maxBytes = 64 * 1024

    private init() {
        fileURL = AppConstants.sharedContainerURL?
            .appendingPathComponent("keyboard_debug.log")
    }

    // MARK: - Writing

    /// Append a timestamped line with memory stats. Safe to call from any thread.
    public func log(_ message: String, function: String = #function) {
        queue.async { [weak self] in
            guard let self, let url = self.fileURL else { return }

            let mem = Self.memoryStats()
            let ts = Self.timestamp()
            let line = "[\(ts)] [\(mem)] [\(function)] \(message)\n"

            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }

            // Trim if too large — keep the tail
            self.trimIfNeeded()
        }
    }

    /// Clear the log file.
    public func clear() {
        queue.async { [weak self] in
            guard let url = self?.fileURL else { return }
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Reading (main app)

    /// Read the full log. Call from the main app to display in UI.
    public func read() -> String {
        guard let url = fileURL,
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "(no log file)"
        }
        return contents.isEmpty ? "(empty)" : contents
    }

    // MARK: - Memory helpers

    /// Returns a compact string: "used: XX MB | avail: YY MB"
    private static func memoryStats() -> String {
        let used = residentMemoryMB()
        let avail = availableMemoryMB()
        return "used: \(used) MB | avail: \(avail) MB"
    }

    /// Resident (RSS) memory of this process in MB.
    private static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size / (1024 * 1024))
    }

    /// Memory remaining before the OS kills this process (iOS 13+).
    private static func availableMemoryMB() -> Int {
        #if os(iOS)
        Int(os_proc_available_memory() / (1024 * 1024))
        #else
        0
        #endif
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private func trimIfNeeded() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              data.count > maxBytes else { return }

        // Keep last maxBytes/2 worth of data
        let keepFrom = data.count - maxBytes / 2
        let trimmed = data.subdata(in: keepFrom..<data.count)
        // Find the first newline so we don't start mid-line
        if let nlIndex = trimmed.firstIndex(of: UInt8(ascii: "\n")) {
            let clean = trimmed.subdata(in: trimmed.index(after: nlIndex)..<trimmed.endIndex)
            try? clean.write(to: url)
        } else {
            try? trimmed.write(to: url)
        }
    }
}
