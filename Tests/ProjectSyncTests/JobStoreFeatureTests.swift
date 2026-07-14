import XCTest
@testable import ProjectSync

final class JobStoreFeatureTests: XCTestCase {
    @MainActor
    func testConcurrencyLimitQueuesAndEventuallyRunsJobs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = JobStore(applicationSupportURL: fixture.support, preferences: fixture.preferences)
        store.setMaximumConcurrentRuns(1)

        let first = try fixture.makeJob(name: "First")
        let second = try fixture.makeJob(name: "Second")
        store.upsert(first)
        store.upsert(second)
        store.run(first.id)
        store.run(second.id)

        XCTAssertEqual(store.activeCount, 1)
        XCTAssertTrue(store.queuedJobIDs.contains(second.id))

        let deadline = Date().addingTimeInterval(8)
        while store.history.filter({ $0.jobID == first.id || $0.jobID == second.id }).count < 2,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(store.history.filter { $0.jobID == first.id || $0.jobID == second.id }.count, 2)
        XCTAssertTrue(store.queuedJobIDs.isEmpty)
    }

    @MainActor
    func testDisablingQueuedJobRemovesItBeforeItRuns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = JobStore(applicationSupportURL: fixture.support, preferences: fixture.preferences)
        store.setMaximumConcurrentRuns(1)

        let first = try fixture.makeJob(name: "Active")
        let second = try fixture.makeJob(name: "Queued")
        store.upsert(first)
        store.upsert(second)
        store.run(first.id)
        store.run(second.id)
        XCTAssertTrue(store.queuedJobIDs.contains(second.id))

        store.setEnabled(false, for: second.id)
        XCTAssertFalse(store.queuedJobIDs.contains(second.id))
        XCTAssertFalse(try XCTUnwrap(store.job(withID: second.id)).enabled)

        let deadline = Date().addingTimeInterval(5)
        while store.runningJobIDs.contains(first.id), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(store.history.contains { $0.jobID == second.id })
    }

    @MainActor
    func testDuplicateIsDisabledAndResetsRunState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = JobStore(applicationSupportURL: fixture.support, preferences: fixture.preferences)
        var job = try fixture.makeJob(name: "Documents")
        job.notes = "Keep this context"
        job.lastRunAt = Date()
        job.lastState = .failed
        job.lastMessage = "Old failure"
        store.upsert(job)

        let duplicateID = try XCTUnwrap(store.duplicate(job.id))
        let duplicate = try XCTUnwrap(store.job(withID: duplicateID))

        XCTAssertEqual(duplicate.name, "Documents Copy")
        XCTAssertFalse(duplicate.enabled)
        XCTAssertNil(duplicate.lastRunAt)
        XCTAssertEqual(duplicate.lastState, .idle)
        XCTAssertEqual(duplicate.notes, "Keep this context")
    }

    @MainActor
    func testOperationalPreferencesPersist() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var store: JobStore? = JobStore(applicationSupportURL: fixture.support, preferences: fixture.preferences)
        store?.setMaximumConcurrentRuns(4)
        store?.setRetryLimit(5)
        store?.setRetryBaseDelaySeconds(60)
        store?.setStaleReminderDays(14)
        store = nil

        let reloaded = JobStore(applicationSupportURL: fixture.support, preferences: fixture.preferences)
        XCTAssertEqual(reloaded.maximumConcurrentRuns, 4)
        XCTAssertEqual(reloaded.retryLimit, 5)
        XCTAssertEqual(reloaded.retryBaseDelaySeconds, 60)
        XCTAssertEqual(reloaded.staleReminderDays, 14)
    }

    func testNewOptionalFieldsDecodeFromLegacyData() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var jobObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(SyncJob())) as? [String: Any])
        for key in [
            "notes", "archiveReplacedFiles", "archiveRetentionCount", "verifyAfterSync",
            "verifyPermissions", "runWhenVolumeMounts", "realtimePausedUntil", "lastVerificationAt", "lastVerificationSucceeded"
        ] { jobObject.removeValue(forKey: key) }
        let decodedJob = try decoder.decode(SyncJob.self, from: JSONSerialization.data(withJSONObject: jobObject))
        XCTAssertNil(decodedJob.notes)
        XCTAssertFalse(decodedJob.keepsVersionedArchive)

        let now = Date()
        let record = RunRecord(
            jobID: UUID(), jobName: "Legacy", startedAt: now, endedAt: now,
            state: .succeeded, dryRun: false, message: "OK", logPath: ""
        )
        var recordObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        for key in ["transferSummary", "verification", "trigger"] { recordObject.removeValue(forKey: key) }
        let decodedRecord = try decoder.decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: recordObject))
        XCTAssertNil(decodedRecord.transferSummary)
        XCTAssertNil(decodedRecord.trigger)
    }
}

private final class Fixture {
    let root: URL
    let support: URL
    let preferences: UserDefaults
    private let suiteName: String
    private var jobNumber = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        suiteName = "ProjectSyncTests.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suiteName)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeJob(name: String) throws -> SyncJob {
        jobNumber += 1
        let source = root.appendingPathComponent("source-\(jobNumber)", isDirectory: true)
        let destination = root.appendingPathComponent("destination-\(jobNumber)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(name.utf8).write(to: source.appendingPathComponent("file.txt"))
        var job = SyncJob()
        job.name = name
        job.source = SyncEndpoint(kind: .local, path: source.path)
        job.destination = SyncEndpoint(kind: .local, path: destination.path)
        job.exclusions = []
        job.preserveExtendedAttributes = false
        return job
    }

    func cleanup() {
        preferences.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
