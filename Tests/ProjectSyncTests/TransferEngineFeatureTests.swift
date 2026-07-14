import XCTest
@testable import ProjectSync

final class TransferEngineFeatureTests: XCTestCase {
    func testCancellationRequestedBeforeLaunchPreventsProcessRegistration() {
        let runningProcess = RunningProcess()
        runningProcess.cancel()

        XCTAssertTrue(runningProcess.isCancelled)
        XCTAssertFalse(runningProcess.set(Process()))
    }

    func testCommandRequestsStats() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let command = try RsyncCommand.build(for: fixture.job)

        XCTAssertTrue(command.arguments.contains("--stats"))
    }

    func testStatsParserReadsOpenRsyncOutput() {
        let output = """
        Transfer starting: 3 files
        >f+++++++ first.bin
        .f...p... second.bin
        *deleting obsolete.bin
        Number of files: 3
        Number of files transferred: 1
        Total file size: 2.5 M
        Total transferred file size: 1.25 M
        sent 152 bytes  received 42 bytes  176k bytes/sec
        """

        let summary = RsyncOutputParser.parse(output)

        XCTAssertEqual(summary.filesChanged, 3)
        XCTAssertEqual(summary.filesTransferred, 1)
        XCTAssertEqual(summary.filesDeleted, 1)
        XCTAssertEqual(summary.totalBytes, 2_500_000)
        XCTAssertEqual(summary.transferredBytes, 1_250_000)
        XCTAssertEqual(summary.bytesPerSecond, 176_000)
    }

    func testRunPopulatesStatsAndTriggerWhileKeepingLog() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("hello transfer summary".utf8).write(to: fixture.source.appendingPathComponent("hello.txt"))

        let record = try await fixture.runner.run(
            job: fixture.job,
            dryRun: false,
            processBox: RunningProcess(),
            trigger: .schedule
        )

        XCTAssertEqual(record.state, .succeeded)
        XCTAssertEqual(record.trigger, .schedule)
        XCTAssertEqual(record.transferSummary?.filesTransferred, 1)
        XCTAssertEqual(record.transferSummary?.filesChanged, 1)
        XCTAssertEqual(record.transferSummary?.transferredBytes, 22)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.logPath))
    }

    func testArchiveCommandIsLocalOnlyAndProtected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var localJob = fixture.job
        localJob.archiveReplacedFiles = true

        let command = try RsyncCommand.build(for: localJob, archiveDate: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(command.arguments.contains("--backup"))
        XCTAssertTrue(command.arguments.contains("/.project-sync-archive/"))
        XCTAssertTrue(command.arguments.contains { $0.hasPrefix("--backup-dir=") })
        XCTAssertNotNil(RsyncCommand.archiveDirectory(for: localJob, at: Date()))

        var remoteJob = localJob
        remoteJob.destination = SyncEndpoint(kind: .remote, path: "/backups", host: "nas.local")
        let remoteCommand = try RsyncCommand.build(for: remoteJob)
        XCTAssertFalse(remoteCommand.arguments.contains("--backup"))
        XCTAssertFalse(remoteCommand.arguments.contains { $0.hasPrefix("--backup-dir=") })
        XCTAssertFalse(remoteCommand.arguments.contains("/.project-sync-archive/"))
        XCTAssertNil(RsyncCommand.archiveDirectory(for: remoteJob, at: Date()))
    }

    func testArchiveCanEnumerateRestoreAndPruneVersions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var job = fixture.job
        job.archiveReplacedFiles = true
        job.archiveRetentionCount = 1
        let sourceFile = fixture.source.appendingPathComponent("document.txt")
        let destinationFile = fixture.destination.appendingPathComponent("document.txt")
        try Data("new first revision".utf8).write(to: sourceFile)
        try Data("original destination".utf8).write(to: destinationFile)

        let first = try await fixture.runner.run(job: job, dryRun: false, processBox: RunningProcess())
        XCTAssertEqual(first.state, .succeeded)
        var versions = try fixture.runner.archivedVersions(for: job)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(
            try String(contentsOf: versions[0].directoryURL.appendingPathComponent("document.txt"), encoding: .utf8),
            "original destination"
        )

        try fixture.runner.restoreArchivedItem(job: job, version: versions[0], relativePath: "document.txt")
        XCTAssertEqual(try String(contentsOf: destinationFile, encoding: .utf8), "original destination")
        XCTAssertThrowsError(
            try fixture.runner.restoreArchivedItem(job: job, version: versions[0], relativePath: "../outside.txt")
        )

        try Data("second revision with a different size".utf8).write(to: sourceFile)
        let second = try await fixture.runner.run(job: job, dryRun: false, processBox: RunningProcess())
        XCTAssertEqual(second.state, .succeeded)
        versions = try fixture.runner.archivedVersions(for: job)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(
            try String(contentsOf: versions[0].directoryURL.appendingPathComponent("document.txt"), encoding: .utf8),
            "original destination"
        )
    }

    func testVerificationUsesChecksumDryRunWithoutMutatingDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceFile = fixture.source.appendingPathComponent("verified.txt")
        let destinationFile = fixture.destination.appendingPathComponent("verified.txt")
        try Data("matching".utf8).write(to: sourceFile)
        let initialRun = try await fixture.runner.run(
            job: fixture.job,
            dryRun: false,
            processBox: RunningProcess()
        )
        XCTAssertEqual(initialRun.state, .succeeded)

        let matching = try await fixture.runner.verify(job: fixture.job)
        XCTAssertTrue(matching.matches)

        try Data("source changed and is longer".utf8).write(to: sourceFile)
        let mismatch = try await fixture.runner.verify(job: fixture.job)
        XCTAssertFalse(mismatch.matches)
        XCTAssertEqual(try String(contentsOf: destinationFile, encoding: .utf8), "matching")
        let verificationCommand = try RsyncCommand.buildVerification(for: fixture.job)
        XCTAssertTrue(verificationCommand.arguments.contains("--checksum"))
        XCTAssertTrue(verificationCommand.arguments.contains("--dry-run"))
        XCTAssertFalse(verificationCommand.arguments.contains("--backup"))
    }
}

private struct Fixture {
    let root: URL
    let source: URL
    let destination: URL
    let support: URL
    let job: SyncJob
    let runner: SyncRunner

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var value = SyncJob()
        value.name = "Transfer Engine Test"
        value.source = SyncEndpoint(kind: .local, path: source.path)
        value.destination = SyncEndpoint(kind: .local, path: destination.path)
        value.exclusions = []
        value.preserveExtendedAttributes = false
        job = value
        runner = SyncRunner(applicationSupportURL: support)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
