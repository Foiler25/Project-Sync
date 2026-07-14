import Foundation

final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    @discardableResult
    func set(_ process: Process) -> Bool {
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            return false
        }
        self.process = process
        lock.unlock()
        return true
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let active = process
        lock.unlock()
        if active?.isRunning == true { active?.interrupt() }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}

struct ArchivedVersion: Identifiable, Equatable, Sendable {
    let jobID: UUID
    let directoryURL: URL
    let createdAt: Date

    var id: String { directoryURL.path }
    var displayName: String { createdAt.formatted(date: .abbreviated, time: .standard) }
}

struct SyncRunner {
    let applicationSupportURL: URL

    func run(
        job: SyncJob,
        dryRun: Bool,
        processBox: RunningProcess,
        trigger: RunTrigger = .manual
    ) async throws -> RunRecord {
        let startedAt = Date()
        let command = try RsyncCommand.build(for: job, dryRun: dryRun, archiveDate: startedAt)
        let archiveURL = dryRun ? nil : RsyncCommand.archiveDirectory(for: job, at: startedAt)
        if let archiveURL {
            try Self.prepareArchiveParent(for: archiveURL, destinationPath: job.destination.path)
        }
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
            process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
            process.standardOutput = handle
            process.standardError = handle
            guard processBox.set(process) else { throw SyncError.cancelled }
            defer { processBox.clear() }

            try process.run()
            if processBox.isCancelled, process.isRunning { process.interrupt() }
            process.waitUntilExit()
            try? handle.synchronize()
            let endedAt = Date()
            let summary = RsyncOutputParser.parse(url: logURL)

            let tail = Self.tail(of: logURL, bytes: 2_000)
            let state: JobState
            let message: String
            if processBox.isCancelled || Task.isCancelled || process.terminationReason == .uncaughtSignal {
                state = .cancelled
                message = "The sync was cancelled."
            } else if process.terminationStatus != 0 {
                state = .failed
                message = "rsync exited with code \(process.terminationStatus). \(tail)"
            } else {
                state = .succeeded
                message = dryRun ? "Preview completed. No files were modified." : "Sync completed successfully."
            }

            if let archiveURL {
                if state == .succeeded {
                    if FileManager.default.fileExists(atPath: archiveURL.path) {
                        let marker = archiveURL.appendingPathComponent(Self.archiveCompletionMarker)
                        FileManager.default.createFile(atPath: marker.path, contents: Data())
                    }
                    Self.pruneArchives(for: job, keeping: job.archiveVersionLimit)
                } else {
                    // A failed transfer can leave an incomplete backup directory. It must
                    // never be presented as a restorable version.
                    try? FileManager.default.removeItem(at: archiveURL)
                }
            }

            return RunRecord(
                jobID: job.id,
                jobName: job.name,
                startedAt: startedAt,
                endedAt: endedAt,
                state: state,
                dryRun: dryRun,
                message: message,
                logPath: logURL.path,
                transferSummary: summary,
                trigger: trigger
            )
        }.value
    }

    /// Performs a checksum comparison using rsync dry-run mode. A successful comparison
    /// never writes to the destination, including version archive directories.
    func verify(job: SyncJob, processBox: RunningProcess = RunningProcess()) async throws -> VerificationReport {
        let command = try RsyncCommand.buildVerification(for: job)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-sync-verification-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)

        return try await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
            process.standardOutput = handle
            process.standardError = handle
            guard processBox.set(process) else { throw SyncError.cancelled }
            defer { processBox.clear() }

            try process.run()
            if processBox.isCancelled, process.isRunning { process.interrupt() }
            process.waitUntilExit()
            try? handle.synchronize()

            if processBox.isCancelled || Task.isCancelled || process.terminationReason == .uncaughtSignal {
                throw SyncError.cancelled
            }
            guard process.terminationStatus == 0 else {
                throw SyncError.processFailed(
                    process.terminationStatus,
                    Self.tail(of: temporaryURL, bytes: 2_000)
                )
            }

            let summary = RsyncOutputParser.parse(url: temporaryURL)
            let changed = summary.filesChanged ?? 0
            let deleted = summary.filesDeleted ?? 0
            let matches = changed == 0 && deleted == 0
            let message: String
            if job.mode == .mirror {
                message = matches
                    ? "Verification completed. Source and destination match."
                    : "Verification found \(changed) changed item\(changed == 1 ? "" : "s") and \(deleted) destination-only item\(deleted == 1 ? "" : "s")."
            } else {
                message = matches
                    ? "Verification completed. All source items match the destination."
                    : "Verification found \(changed) source item\(changed == 1 ? "" : "s") that differ from the destination. Extra backup files are intentionally allowed."
            }
            return VerificationReport(verifiedAt: Date(), matches: matches, message: message)
        }.value
    }

    func archivedVersions(for job: SyncJob) throws -> [ArchivedVersion] {
        guard job.destination.kind != .remote else { return [] }
        let root = Self.archiveRoot(for: job)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey])
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent(Self.archiveCompletionMarker).path) else {
                return nil
            }
            let date = Self.date(fromArchiveDirectoryName: url.lastPathComponent)
                ?? values?.creationDate
                ?? values?.contentModificationDate
                ?? .distantPast
            return ArchivedVersion(jobID: job.id, directoryURL: url, createdAt: date)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Restores one relative item from an archive version. Absolute paths, traversal,
    /// foreign archive directories, and symlinked destination parents are rejected.
    func restoreArchivedItem(job: SyncJob, version: ArchivedVersion, relativePath: String) throws {
        guard job.destination.kind != .remote, version.jobID == job.id else {
            throw SyncError.invalidConfiguration("This archive does not belong to the selected local job.")
        }
        let components = try Self.safeRelativeComponents(relativePath)
        let expectedRoot = Self.archiveRoot(for: job).standardizedFileURL
        let versionURL = version.directoryURL.standardizedFileURL
        guard versionURL.deletingLastPathComponent() == expectedRoot else {
            throw SyncError.invalidConfiguration("The selected archive directory is outside this job's archive.")
        }

        let sourceURL = components.reduce(versionURL) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard sourceURL.path.hasPrefix(versionURL.path.withTrailingSlash),
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw SyncError.invalidConfiguration("The selected archived item is unavailable.")
        }
        try Self.rejectSymlinkedParents(of: sourceURL, below: versionURL)

        let destinationRoot = URL(fileURLWithPath: job.destination.path, isDirectory: true).standardizedFileURL
        let destinationURL = components.reduce(destinationRoot) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard destinationURL.path.hasPrefix(destinationRoot.path.withTrailingSlash) else {
            throw SyncError.invalidConfiguration("The restore destination is outside the job's destination.")
        }
        try Self.rejectSymlinkedParents(of: destinationURL, below: destinationRoot)

        let parentURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let stagingURL = parentURL.appendingPathComponent(".project-sync-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet.alphanumerics.inverted
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.joined(separator: "-").lowercased().prefix(60).description.ifEmpty("sync")
    }

    private static func archiveRoot(for job: SyncJob) -> URL {
        URL(fileURLWithPath: job.destination.path, isDirectory: true)
            .appendingPathComponent(".project-sync-archive", isDirectory: true)
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
            .standardizedFileURL
    }

    private static let archiveCompletionMarker = ".project-sync-complete"

    private static func prepareArchiveParent(for archiveURL: URL, destinationPath: String) throws {
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL
        let parent = archiveURL.deletingLastPathComponent().standardizedFileURL
        guard parent.path.hasPrefix(destination.path.withTrailingSlash) else {
            throw SyncError.invalidConfiguration("The version archive path is outside the destination.")
        }
        var destinationIsDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } else if !destinationIsDirectory.boolValue {
            throw SyncError.invalidConfiguration("The sync destination is not a folder.")
        }
        let relative = String(parent.path.dropFirst(destination.path.count))
        var current = destination
        for component in NSString(string: relative).pathComponents where component != "/" && component != "." {
            current.appendPathComponent(component, isDirectory: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path) {
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw SyncError.invalidConfiguration("The version archive cannot use a symbolic-link folder.")
                }
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw SyncError.invalidConfiguration("The version archive path is not a folder.")
                }
            } else {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }

    private static func pruneArchives(for job: SyncJob, keeping limit: Int) {
        let runner = SyncRunner(applicationSupportURL: FileManager.default.temporaryDirectory)
        guard let versions = try? runner.archivedVersions(for: job), versions.count > limit else { return }
        for version in versions.dropFirst(max(1, limit)) {
            try? FileManager.default.removeItem(at: version.directoryURL)
        }
    }

    private static func safeRelativeComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else {
            throw SyncError.invalidConfiguration("Choose an item inside the archive.")
        }
        let components = NSString(string: relativePath).pathComponents
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != "/" }) else {
            throw SyncError.invalidConfiguration("The archived item path contains unsafe traversal components.")
        }
        return components
    }

    private static func rejectSymlinkedParents(of destination: URL, below root: URL) throws {
        var current = root
        let relative = String(destination.deletingLastPathComponent().path.dropFirst(root.path.count))
        for component in NSString(string: relative).pathComponents where component != "/" && component != "." {
            current.appendPathComponent(component)
            guard FileManager.default.fileExists(atPath: current.path) else { continue }
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw SyncError.invalidConfiguration("Restore cannot write through a symbolic-link folder.")
            }
        }
    }

    private static func date(fromArchiveDirectoryName name: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: name)
    }

    private static func tail(of url: URL, bytes: Int) -> String {
        guard let data = try? Data(contentsOf: url) else { return "See the run log for details." }
        let slice = data.suffix(bytes)
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RsyncOutputParser {
    static func parse(url: URL) -> TransferSummary {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return TransferSummary() }
        defer { try? handle.close() }

        var parser = Parser()
        var pending = Data()
        while true {
            let chunk = (try? handle.read(upToCount: 64 * 1_024)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                parser.consume(String(decoding: line, as: UTF8.self))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { parser.consume(String(decoding: pending, as: UTF8.self)) }
        return parser.summary
    }

    static func parse(_ output: String) -> TransferSummary {
        var parser = Parser()
        output.enumerateLines { line, _ in parser.consume(line) }
        return parser.summary
    }

    private struct Parser {
        var filesChanged = 0
        var filesDeleted = 0
        var filesTransferred: Int?
        var totalBytes: Int64?
        var transferredBytes: Int64?
        var bytesPerSecond: Double?

        mutating func consume(_ rawLine: String) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("*deleting ") {
                filesDeleted += 1
                filesChanged += 1
                return
            }
            if isChangedItemLine(line) { filesChanged += 1 }
            if let value = value(after: "Number of files transferred:", in: line) {
                filesTransferred = Int(value.replacingOccurrences(of: ",", with: ""))
            } else if let value = value(after: "Total file size:", in: line) {
                totalBytes = Self.byteCount(value)
            } else if let value = value(after: "Total transferred file size:", in: line) {
                transferredBytes = Self.byteCount(value)
            } else if let range = line.range(of: " bytes/sec") {
                let prefix = line[..<range.lowerBound]
                if let token = prefix.split(whereSeparator: { $0.isWhitespace }).last {
                    bytesPerSecond = Self.byteRate(String(token))
                }
            }
        }

        var summary: TransferSummary {
            TransferSummary(
                filesChanged: filesChanged,
                filesTransferred: filesTransferred,
                filesDeleted: filesDeleted,
                totalBytes: totalBytes,
                transferredBytes: transferredBytes,
                bytesPerSecond: bytesPerSecond
            )
        }

        private func value(after label: String, in line: String) -> String? {
            guard line.hasPrefix(label) else { return nil }
            return String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }

        private func isChangedItemLine(_ line: String) -> Bool {
            guard line.count >= 9 else { return false }
            let characters = Array(line.prefix(2))
            guard characters.count == 2,
                  "<>ch.".contains(characters[0]),
                  "fLDSd".contains(characters[1]) else { return false }
            return true
        }

        private static func byteCount(_ value: String) -> Int64? {
            guard let result = scaledNumber(value) else { return nil }
            return Int64(result.rounded())
        }

        private static func byteRate(_ value: String) -> Double? {
            scaledNumber(value)
        }

        private static func scaledNumber(_ rawValue: String) -> Double? {
            let compact = rawValue.replacingOccurrences(of: ",", with: "")
            guard let first = compact.firstIndex(where: { $0.isLetter }) else {
                return Double(compact.trimmingCharacters(in: .whitespaces))
            }
            let numericPart = compact[..<first].trimmingCharacters(in: .whitespaces)
            let number = Double(numericPart)
            guard let number else { return nil }
            let suffix = compact[first].lowercased()
            let multiplier: Double
            switch suffix {
            case "k": multiplier = 1_000
            case "m": multiplier = 1_000_000
            case "g": multiplier = 1_000_000_000
            case "t": multiplier = 1_000_000_000_000
            default: multiplier = 1
            }
            return number * multiplier
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
    var withTrailingSlash: String { hasSuffix("/") ? self : self + "/" }
}
