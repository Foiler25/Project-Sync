import Combine
import Foundation
import UserNotifications

enum SyncNotificationEvent: Equatable {
    case started
    case succeeded(summary: String? = nil)
    case failed(message: String)
    case waitingForDestination(message: String? = nil)
    case retryScheduled(attempt: Int, delay: TimeInterval)
    case staleBackup(lastSuccessfulRun: Date?)
}

/// Owns Project Sync's persistent notification preferences and delivery.
///
/// Creating the manager never presents an authorization prompt. Permission is
/// requested only by `requestAuthorization()` or when an enabled event is posted.
@MainActor
final class SystemNotificationManager: ObservableObject {
    static let shared = SystemNotificationManager(notificationCenter: defaultNotificationCenter)

    private static var defaultNotificationCenter: UNUserNotificationCenter? {
        // UNUserNotificationCenter raises an Objective-C exception when the host is
        // a command-line executable or XCTest runner rather than an application bundle.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else { return nil }
        return .current()
    }

    @Published var notifyOnStart: Bool {
        didSet { preferences.set(notifyOnStart, forKey: Keys.start) }
    }

    @Published var notifyOnSuccess: Bool {
        didSet { preferences.set(notifyOnSuccess, forKey: Keys.success) }
    }

    @Published var notifyOnFailure: Bool {
        didSet { preferences.set(notifyOnFailure, forKey: Keys.failure) }
    }

    @Published var notifyOnRetryOrWaiting: Bool {
        didSet { preferences.set(notifyOnRetryOrWaiting, forKey: Keys.retryOrWaiting) }
    }

    @Published var notifyOnStaleBackup: Bool {
        didSet { preferences.set(notifyOnStaleBackup, forKey: Keys.staleBackup) }
    }

    private enum Keys {
        static let start = "notifications.syncStart"
        static let success = "notifications.syncSuccess"
        static let failure = "notifications.syncFailure"
        static let retryOrWaiting = "notifications.retryOrWaiting"
        static let staleBackup = "notifications.staleBackup"
    }

    private let preferences: UserDefaults
    private let notificationCenter: UNUserNotificationCenter?

    /// Pass `nil` as the notification center in tests or non-UI contexts where
    /// delivery should be disabled while preference behavior remains available.
    init(
        preferences: UserDefaults = .standard,
        notificationCenter: UNUserNotificationCenter? = nil
    ) {
        self.preferences = preferences
        self.notificationCenter = notificationCenter

        preferences.register(defaults: [
            Keys.start: false,
            Keys.success: true,
            Keys.failure: true,
            Keys.retryOrWaiting: true,
            Keys.staleBackup: true
        ])

        notifyOnStart = preferences.bool(forKey: Keys.start)
        notifyOnSuccess = preferences.bool(forKey: Keys.success)
        notifyOnFailure = preferences.bool(forKey: Keys.failure)
        notifyOnRetryOrWaiting = preferences.bool(forKey: Keys.retryOrWaiting)
        notifyOnStaleBackup = preferences.bool(forKey: Keys.staleBackup)
    }

    /// Explicitly asks for notification permission. A denied or unavailable
    /// notification service is reported as `false` and is otherwise harmless.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let notificationCenter else { return false }

        do {
            let settings = await notificationCenter.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .notDetermined:
                return try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            case .denied:
                return false
            @unknown default:
                return false
            }
        } catch {
            return false
        }
    }

    /// Posts a concise notification when its corresponding preference is on.
    /// The method is safe to call after permission has been denied.
    func post(_ event: SyncNotificationEvent, for job: SyncJob) async {
        guard isEnabled(event), let notificationCenter else { return }
        guard await requestAuthorization() else { return }

        let presentation = presentation(for: event, jobName: job.name)
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.body = presentation.body
        content.sound = presentation.playsSound ? .default : nil
        content.userInfo = [
            "jobID": job.id.uuidString,
            "event": presentation.eventIdentifier
        ]

        let request = UNNotificationRequest(
            identifier: "project-sync.\(presentation.eventIdentifier).\(job.id.uuidString).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await notificationCenter.add(request)
    }

    func isEnabled(_ event: SyncNotificationEvent) -> Bool {
        switch event {
        case .started:
            return notifyOnStart
        case .succeeded:
            return notifyOnSuccess
        case .failed:
            return notifyOnFailure
        case .waitingForDestination, .retryScheduled:
            return notifyOnRetryOrWaiting
        case .staleBackup:
            return notifyOnStaleBackup
        }
    }

    private func presentation(
        for event: SyncNotificationEvent,
        jobName: String
    ) -> (title: String, body: String, eventIdentifier: String, playsSound: Bool) {
        switch event {
        case .started:
            return ("Sync started", jobName, "started", false)
        case .succeeded(let summary):
            return ("Sync complete", concise(summary, fallback: jobName), "succeeded", false)
        case .failed(let message):
            return ("Sync needs attention", "\(jobName): \(concise(message, fallback: "Sync failed"))", "failed", true)
        case .waitingForDestination(let message):
            return ("Waiting for destination", "\(jobName): \(concise(message, fallback: "The destination is unavailable"))", "waiting", false)
        case .retryScheduled(let attempt, let delay):
            let seconds = max(0, Int(delay.rounded()))
            return ("Sync retry scheduled", "\(jobName): attempt \(attempt) in \(formattedDelay(seconds))", "retry", false)
        case .staleBackup(let lastSuccessfulRun):
            let detail: String
            if let lastSuccessfulRun {
                detail = "Last successful sync was \(lastSuccessfulRun.formatted(date: .abbreviated, time: .shortened))."
            } else {
                detail = "No successful sync has been recorded."
            }
            return ("Backup may be out of date", "\(jobName): \(detail)", "stale", true)
        }
    }

    private func concise(_ value: String?, fallback: String) -> String {
        let normalized = value?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return fallback }
        return String(normalized.prefix(180))
    }

    private func formattedDelay(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = seconds / 60
        return "\(minutes) min"
    }
}
