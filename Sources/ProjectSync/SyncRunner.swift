import Foundation

final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let active = process
        lock.unlock()
        active?.interrupt()
    }
}

struct SyncRunner {
    let applicationSupportURL: URL

    func run(job: SyncJob, dryRun: Bool, processBox: RunningProcess) async throws -> RunRecord {
        let command = try RsyncCommand.build(for: job, dryRun: dryRun)
        let startedAt = Date()
        let logsURL = applicationSupportURL.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        let logURL = logsURL.appendingPathComponent("\(safeFilename(job.name))-\(stamp).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        return try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            let heading = "Project Sync\nStarted: \(startedAt.formatted())\nCommand: \(command.preview)\n\n"
            try handle.write(contentsOf: Data(heading.utf8))

            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.standardOutput = handle
            process.standardError = handle
            processBox.set(process)
            defer { processBox.clear() }

            try process.run()
            process.waitUntilExit()
            let endedAt = Date()

            let tail = Self.tail(of: logURL, bytes: 2_000)
            let state: JobState
            let message: String
            if Task.isCancelled || process.terminationReason == .uncaughtSignal {
                state = .cancelled
                message = "The sync was cancelled."
            } else if process.terminationStatus != 0 {
                state = .failed
                message = "rsync exited with code \(process.terminationStatus). \(tail)"
            } else {
                state = .succeeded
                message = dryRun ? "Preview completed. No files were modified." : "Sync completed successfully."
            }

            return RunRecord(
                jobID: job.id,
                jobName: job.name,
                startedAt: startedAt,
                endedAt: endedAt,
                state: state,
                dryRun: dryRun,
                message: message,
                logPath: logURL.path
            )
        }.value
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet.alphanumerics.inverted
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.joined(separator: "-").lowercased().prefix(60).description.ifEmpty("sync")
    }

    private static func tail(of url: URL, bytes: Int) -> String {
        guard let data = try? Data(contentsOf: url) else { return "See the run log for details." }
        let slice = data.suffix(bytes)
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
