import XCTest
@testable import ProjectSync

final class ProjectSyncTests: XCTestCase {
    func testBackupDoesNotDeleteDestinationFiles() throws {
        let command = try RsyncCommand.build(for: localJob(mode: .backup))
        XCTAssertFalse(command.arguments.contains("--delete"))
        XCTAssertEqual(command.executable, "/usr/bin/rsync")
    }

    func testMirrorAddsDeleteFlag() throws {
        let command = try RsyncCommand.build(for: localJob(mode: .mirror))
        XCTAssertTrue(command.arguments.contains("--delete"))
    }

    func testDryRunAddsPreviewFlag() throws {
        let command = try RsyncCommand.build(for: localJob(mode: .backup), dryRun: true)
        XCTAssertTrue(command.arguments.contains("--dry-run"))
    }

    func testRemoteUsesSSHWithoutShellInterpolation() throws {
        var job = localJob(mode: .backup)
        job.destination = SyncEndpoint(kind: .remote, path: "/volume one/Backups", host: "nas.local", username: "alex", port: 2222)
        let command = try RsyncCommand.build(for: job)
        XCTAssertTrue(command.arguments.contains("ssh -p 2222 -o BatchMode=yes -o ConnectTimeout=15"))
        XCTAssertEqual(command.arguments.last, "alex@nas.local:'/volume one/Backups/'")
    }

    func testRemoteToRemoteIsRejected() {
        var job = localJob(mode: .backup)
        job.source = SyncEndpoint(kind: .remote, path: "/a", host: "one.local")
        job.destination = SyncEndpoint(kind: .remote, path: "/b", host: "two.local")
        XCTAssertThrowsError(try RsyncCommand.build(for: job))
    }

    func testHourlyScheduleReturnsFutureDateAtSelectedMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 9, minute: 20)))
        let next = try XCTUnwrap(JobSchedule(kind: .hourly, minute: 45).nextDate(after: start, calendar: calendar))
        let parts = calendar.dateComponents([.hour, .minute], from: next)
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 45)
    }

    func testRealtimeScheduleHasNoClockDate() {
        let schedule = JobSchedule(kind: .realtime)
        XCTAssertEqual(schedule.summary, "When files change")
        XCTAssertNil(schedule.nextDate(after: Date()))
    }

    func testFileWatcherReportsNestedChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let changed = expectation(description: "FSEvents reports a nested file change")
        changed.assertForOverFulfill = false
        let watcher = FileSystemWatcher(path: root.path) { changed.fulfill() }
        defer { watcher.stop() }

        XCTAssertTrue(watcher.start())
        try Data("changed".utf8).write(to: nested.appendingPathComponent("file.txt"))
        wait(for: [changed], timeout: 5)
    }

    @MainActor
    func testRealtimeJobCopiesAChangedFileEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let store = JobStore(applicationSupportURL: support)
        var job = SyncJob()
        job.name = "Real-time Integration Test"
        job.source = SyncEndpoint(kind: .local, path: source.path)
        job.destination = SyncEndpoint(kind: .local, path: destination.path)
        job.schedule.kind = .realtime
        job.exclusions = []
        job.preserveExtendedAttributes = false
        store.upsert(job)
        defer {
            store.delete(job.id)
            try? FileManager.default.removeItem(at: root)
        }

        try Data("watched".utf8).write(to: source.appendingPathComponent("watched.txt"))
        let copiedURL = destination.appendingPathComponent("watched.txt")
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: copiedURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        XCTAssertEqual(try String(contentsOf: copiedURL, encoding: .utf8), "watched")
    }

    func testNestedLocalDestinationIsRejected() {
        var job = localJob(mode: .backup)
        job.source.path = NSTemporaryDirectory()
        job.destination.path = URL(fileURLWithPath: job.source.path)
            .appendingPathComponent("nested-backup")
            .path
        XCTAssertThrowsError(try RsyncCommand.build(for: job))
    }

    func testRunnerCopiesAFileEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello project sync".utf8).write(to: source.appendingPathComponent("hello.txt"))

        var job = SyncJob()
        job.name = "Integration Test"
        job.source = SyncEndpoint(kind: .local, path: source.path)
        job.destination = SyncEndpoint(kind: .local, path: destination.path)
        job.exclusions = []
        job.preserveExtendedAttributes = false

        let record = try await SyncRunner(applicationSupportURL: support).run(
            job: job,
            dryRun: false,
            processBox: RunningProcess()
        )

        XCTAssertEqual(record.state, .succeeded)
        let copied = try String(contentsOf: destination.appendingPathComponent("hello.txt"), encoding: .utf8)
        XCTAssertEqual(copied, "hello project sync")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.logPath))
    }

    func testLargeLogPreviewLoadsOnlyTail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let content = (0..<2_000).map { "line \($0)" }.joined(separator: "\n")
        try Data(content.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = await LogPreviewLoader.load(path: url.path, fallback: "fallback", limit: 1_024)

        XCTAssertTrue(preview.isTruncated)
        XCTAssertLessThanOrEqual(preview.loadedBytes, 1_024)
        XCTAssertTrue(preview.text.contains("Earlier output omitted"))
        XCTAssertTrue(preview.text.contains("line 1999"))
        XCTAssertFalse(preview.text.contains("line 0\n"))
    }

    private func localJob(mode: TransferMode) -> SyncJob {
        var job = SyncJob()
        job.source = SyncEndpoint(kind: .local, path: NSTemporaryDirectory())
        job.destination = SyncEndpoint(kind: .network, path: "/Users/Shared/project-sync-output")
        job.mode = mode
        return job
    }
}
