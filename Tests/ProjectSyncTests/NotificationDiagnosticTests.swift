import Foundation
import XCTest
@testable import ProjectSync

final class NotificationDiagnosticTests: XCTestCase {
    @MainActor
    func testNotificationPreferencesHaveSafeDefaultsAndPersist() throws {
        let suiteName = "ProjectSync.NotificationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let manager = SystemNotificationManager(
            preferences: preferences,
            notificationCenter: nil
        )

        XCTAssertFalse(manager.notifyOnStart)
        XCTAssertTrue(manager.notifyOnSuccess)
        XCTAssertTrue(manager.notifyOnFailure)
        XCTAssertTrue(manager.notifyOnRetryOrWaiting)
        XCTAssertTrue(manager.notifyOnStaleBackup)

        manager.notifyOnStart = true
        manager.notifyOnSuccess = false
        manager.notifyOnRetryOrWaiting = false

        let reloaded = SystemNotificationManager(
            preferences: preferences,
            notificationCenter: nil
        )
        XCTAssertTrue(reloaded.notifyOnStart)
        XCTAssertFalse(reloaded.notifyOnSuccess)
        XCTAssertFalse(reloaded.notifyOnRetryOrWaiting)
        XCTAssertTrue(reloaded.isEnabled(.failed(message: "failed")))
        XCTAssertFalse(reloaded.isEnabled(.retryScheduled(attempt: 2, delay: 30)))
    }

    @MainActor
    func testDisabledDeliveryDoesNotRequestNotificationUI() async throws {
        let suiteName = "ProjectSync.NotificationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let manager = SystemNotificationManager(preferences: preferences, notificationCenter: nil)

        let authorized = await manager.requestAuthorization()
        XCTAssertFalse(authorized)
        await manager.post(.failed(message: "No UI should appear"), for: SyncJob())
    }

    @MainActor
    func testJobCanDisableNotificationsIndependentlyOfGlobalPreferences() throws {
        let suiteName = "ProjectSync.NotificationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let manager = SystemNotificationManager(preferences: preferences, notificationCenter: nil)

        var job = SyncJob()
        job.notificationsEnabled = false

        XCTAssertTrue(manager.isEnabled(.failed(message: "failed")))
        XCTAssertFalse(job.sendsNotifications)
        XCTAssertFalse(manager.isEnabled(.failed(message: "failed"), for: job))
    }

    func testDiagnosticReportRedactsPrivateDetailsAndIncludesUsefulState() throws {
        var job = SyncJob()
        job.name = "Nightly Backup"
        job.source = SyncEndpoint(kind: .local, path: "/Users/alice/Private Project")
        job.destination = SyncEndpoint(
            kind: .remote,
            path: "/backups/alice",
            host: "nas.example.test",
            username: "backup-admin",
            port: 2222
        )
        job.schedule = JobSchedule(kind: .daily, minute: 15, hour: 2)
        job.exclusions = ["Family Taxes", ".DS_Store"]
        job.notes = "Password: must-never-appear"

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let record = RunRecord(
            jobID: job.id,
            jobName: job.name,
            startedAt: started,
            endedAt: started.addingTimeInterval(12.5),
            state: .failed,
            dryRun: false,
            message: "SSH backup-admin@nas.example.test password=hunter2 failed at /Users/alice/Private Project",
            logPath: "/Users/alice/Library/Application Support/Project Sync/secret.log",
            transferSummary: TransferSummary(filesChanged: 3, filesTransferred: 2),
            trigger: .schedule
        )

        let report = DiagnosticReportBuilder(
            jobs: [job],
            runRecords: [record],
            appVersion: "1.2.0 (7)",
            settingsSummary: ["History limit": "100", "SSH token": "abc123"],
            recentLogTails: [record.id: "identityFile /Users/alice/.ssh/id_ed25519\nbackup-admin@nas.example.test: permission denied"]
        ).makeText(generatedAt: started)

        XCTAssertTrue(report.contains("Project Sync Diagnostic Report"))
        XCTAssertTrue(report.contains("App version: 1.2.0 (7)"))
        XCTAssertTrue(report.contains("Nightly Backup"))
        XCTAssertTrue(report.contains("Outcome: failed"))
        XCTAssertTrue(report.contains("3 changed, 2 transferred"))
        XCTAssertTrue(report.contains("<redacted-user>@nas.example.test"))
        XCTAssertTrue(report.contains("/Users/<redacted>/Private Project"))
        XCTAssertTrue(report.contains("Exclusions: 2 configured (names omitted)"))
        XCTAssertFalse(report.contains("backup-admin"))
        XCTAssertFalse(report.contains("hunter2"))
        XCTAssertFalse(report.contains("abc123"))
        XCTAssertFalse(report.contains("id_ed25519"))
        XCTAssertFalse(report.contains("must-never-appear"))
        XCTAssertFalse(report.contains("Family Taxes"))
        XCTAssertFalse(report.contains("secret.log"))
    }

    func testDiagnosticReportCanBeSavedAsUTF8() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectSync-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let builder = DiagnosticReportBuilder(
            jobs: [],
            runRecords: [],
            appVersion: "Test"
        )
        try builder.save(to: url, generatedAt: Date(timeIntervalSince1970: 0))

        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("No jobs configured"))
        XCTAssertTrue(saved.contains("No runs recorded"))
    }
}
