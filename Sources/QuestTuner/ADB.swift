import Foundation

enum ADB {
    /// GUI apps do not inherit the shell PATH, so look in the usual install locations.
    static let path: String? = {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs adb to completion and returns its exit status and combined output.
    /// With a timeout the process is terminated once it runs longer (a Wi-Fi `connect` to an
    /// address that does not answer otherwise blocks for a long time).
    /// `started` receives the process once it runs, so a caller can terminate a long transfer.
    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval? = nil,
                    started: (@Sendable (Process) -> Void)? = nil) async -> (status: Int32, output: String) {
        guard let path else { return (-1, "adb not found") }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                    return
                }
                started?(process)
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { process.terminate() }
                    }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Runs adb and returns raw stdout bytes (for binary output such as `exec-out screencap -p`).
    static func runData(_ args: [String]) async -> (status: Int32, data: Data) {
        guard let path else { return (-1, Data()) }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: (-1, Data()))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: (process.terminationStatus, data))
            }
        }
    }

    static func shell(_ serial: String, _ command: String) async -> (status: Int32, output: String) {
        await run(["-s", serial, "shell", command])
    }
}

/// A long-running adb process whose stdout is delivered line by line on the main actor.
final class LineStream {
    private let process = Process()
    private var buffer = Data()

    init?(args: [String],
          onLine: @escaping @MainActor (String) -> Void,
          onExit: @escaping @MainActor () -> Void) {
        guard let path = ADB.path else { return nil }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(chunk, onLine: onLine)
        }
        process.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit() } }
        }
        do { try process.run() } catch { return nil }
    }

    // readabilityHandler calls are serialized per handle, so the buffer needs no lock.
    private func consume(_ chunk: Data, onLine: @escaping @MainActor (String) -> Void) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}
