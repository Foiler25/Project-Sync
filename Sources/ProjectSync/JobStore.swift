import AppKit
import Combine
import Foundation
import ServiceManagement

private enum PendingOperation {
    case sync(jobID: UUID, dryRun: Bool, trigger: RunTrigger, attempt: Int)
    case verification(jobID: UUID)

    var jobID: UUID {
        switch self {
        case .sync(let jobID, _, _, _), .verification(let jobID): return jobID
        }
    }
}

@MainActor
final class JobStore: ObservableObject {
    static let historyLimitOptions = [25, 50, 100, 200, 500, 1_000]
    static let defaultHistoryLimit = 200
    static let concurrencyOptions = [1, 2, 3, 4]
    static let retryLimitOptions = [0, 1, 3, 5]
    static let retryDelayOptions = [5, 15, 30, 60, 300]
    static let staleReminderOptions = [0, 1, 3, 7, 14, 30]

    @Published private(set) var jobs: [SyncJob] = []
    @Published private(set) var history: [RunRecord] = []
    @Published private(set) var historyLimit: Int
    @Published private(set) var runningJobIDs: Set<UUID> = []
    @Published private(set) var watchingJobIDs: Set<UUID> = []
    @Published private(set) var queuedJobIDs: Set<UUID> = []
    @Published private(set) var verifyingJobIDs: Set<UUID> = []
    @Published private(set) var activeSyncSessions: [UUID: ActiveSyncSession] = [:]
    @Published private(set) var maximumConcurrentRuns: Int
    @Published private(set) var retryLimit: Int
    @Published private(set) var retryBaseDelaySeconds: Int
    @Published private(set) var staleReminderDays: Int
    @Published var bannerMessage: String?

    let applicationSupportURL: URL
    private let preferences: UserDefaults
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var processBoxes: [UUID: RunningProcess] = [:]
    private var nextScheduledRuns: [UUID: Date] = [:]
    private var fileWatchers: [UUID: FileSystemWatcher] = [:]
    private var watchedSourcePaths: [UUID: String] = [:]
    private var realtimeDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRealtimeRuns: Set<UUID> = []
    private var pendingOperations: [PendingOperation] = []
    private var mountObserver: NSObjectProtocol?
    private var scheduler: Timer?

    init(applicationSupportURL: URL? = nil, preferences: UserDefaults = .standard) {
        self.applicationSupportURL = applicationSupportURL ?? Self.defaultApplicationSupportURL
        self.preferences = preferences
        let savedLimit = preferences.integer(forKey: Self.historyLimitDefaultsKey)
        historyLimit = Self.historyLimitOptions.contains(savedLimit) ? savedLimit : Self.defaultHistoryLimit
        let savedConcurrency = preferences.integer(forKey: Self.maximumConcurrentRunsDefaultsKey)
        maximumConcurrentRuns = Self.concurrencyOptions.contains(savedConcurrency) ? savedConcurrency : 2
        let savedRetryLimit = preferences.integer(forKey: Self.retryLimitDefaultsKey)
        retryLimit = Self.retryLimitOptions.contains(savedRetryLimit) ? savedRetryLimit : 3
        let savedRetryDelay = preferences.integer(forKey: Self.retryDelayDefaultsKey)
        retryBaseDelaySeconds = Self.retryDelayOptions.contains(savedRetryDelay) ? savedRetryDelay : 15
        let savedReminderDays = preferences.integer(forKey: Self.staleReminderDefaultsKey)
        staleReminderDays = Self.staleReminderOptions.contains(savedReminderDays) ? savedReminderDays : 0
        load()
        if trimHistoryToLimit() { save() }
        rebuildSchedule()
        rebuildFileWatchers()
        scheduler = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.schedulerTick() }
        }
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor [weak self] in self?.volumeDidMount(url) }
        }
    }

    deinit {
        scheduler?.invalidate()
        if let mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(mountObserver) }
        realtimeDebounceTasks.values.forEach { $0.cancel() }
        retryTasks.values.forEach { $0.cancel() }
        fileWatchers.values.forEach { $0.stop() }
    }

    static var defaultApplicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Project Sync", isDirectory: true)
    }

    var activeCount: Int { runningJobIDs.count + verifyingJobIDs.count }
    var successfulJobs: Int { jobs.filter { $0.lastState == .succeeded }.count }
    var attentionJobs: Int { jobs.filter { $0.lastState == .failed }.count }

    func job(withID id: UUID?) -> SyncJob? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    func upsert(_ job: SyncJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            var updated = job
            updated.lastRunAt = jobs[index].lastRunAt
            updated.lastState = jobs[index].lastState
            updated.lastMessage = jobs[index].lastMessage
            jobs[index] = updated
        } else {
            jobs.append(job)
        }
        jobs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
        rebuildSchedule()
        rebuildFileWatchers()
    }

    func delete(_ id: UUID) {
        cancel(id)
        jobs.removeAll { $0.id == id }
        nextScheduledRuns[id] = nil
        removeFileWatcher(for: id)
        pendingRealtimeRuns.remove(id)
        save()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].enabled = enabled
        if !enabled {
            realtimeDebounceTasks[id]?.cancel()
            realtimeDebounceTasks[id] = nil
            pendingRealtimeRuns.remove(id)
            retryTasks[id]?.cancel()
            retryTasks[id] = nil
            retryAttempts[id] = nil
            pendingOperations.removeAll { $0.jobID == id }
            queuedJobIDs.remove(id)
            if !runningJobIDs.contains(id), !verifyingJobIDs.contains(id) {
                jobs[index].lastMessage = "Disabled. Scheduled, queued, and retry runs are paused."
            }
        }
        save()
        rebuildSchedule()
        rebuildFileWatchers()
    }

    func run(_ id: UUID, dryRun: Bool = false, trigger: RunTrigger? = nil) {
        guard job(withID: id) != nil,
              !runningJobIDs.contains(id),
              !verifyingJobIDs.contains(id),
              !queuedJobIDs.contains(id) else { return }
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = nil
        let resolvedTrigger = trigger ?? (dryRun ? .preview : .manual)
        enqueue(.sync(jobID: id, dryRun: dryRun, trigger: resolvedTrigger, attempt: 0))
    }

    private func enqueue(_ operation: PendingOperation) {
        guard job(withID: operation.jobID) != nil else { return }
        if activeCount < maximumConcurrentRuns {
            start(operation)
        } else {
            pendingOperations.append(operation)
            queuedJobIDs.insert(operation.jobID)
            updateJob(operation.jobID) { $0.lastMessage = "Queued—waiting for another job to finish…" }
            save()
        }
    }

    private func start(_ operation: PendingOperation) {
        queuedJobIDs.remove(operation.jobID)
        switch operation {
        case .sync(let id, let dryRun, let trigger, let attempt):
            startSync(id, dryRun: dryRun, trigger: trigger, attempt: attempt)
        case .verification:
            startVerification(operation.jobID)
        }
    }

    private func startSync(_ id: UUID, dryRun: Bool, trigger: RunTrigger, attempt: Int) {
        guard let job = job(withID: id), !runningJobIDs.contains(id) else { return }
        updateJob(id) {
            $0.lastState = .running
            if attempt > 0 {
                $0.lastMessage = "Retry \(attempt) of \(retryLimit) in progress…"
            } else {
                $0.lastMessage = dryRun ? "Previewing changes…" : "Sync in progress…"
            }
        }
        runningJobIDs.insert(id)
        NotificationCenter.default.post(
            name: .projectSyncDidStart,
            object: nil,
            userInfo: ["jobName": job.name, "dryRun": dryRun]
        )
        Task { await SystemNotificationManager.shared.post(.started, for: job) }
        let box = RunningProcess()
        processBoxes[id] = box
        let runner = SyncRunner(applicationSupportURL: applicationSupportURL)

        tasks[id] = Task { [weak self] in
            do {
                var record = try await runner.run(
                    job: job,
                    dryRun: dryRun,
                    processBox: box
                ) { [weak self] logURL, startedAt in
                    self?.activeSyncSessions[id] = ActiveSyncSession(
                        jobID: id,
                        jobName: job.name,
                        startedAt: startedAt,
                        logPath: logURL.path,
                        dryRun: dryRun
                    )
                }
                record.trigger = trigger
                guard let self else { return }
                self.finish(record, attempt: attempt)
            } catch {
                guard let self else { return }
                let now = Date()
                var record = RunRecord(
                    jobID: job.id,
                    jobName: job.name,
                    startedAt: now,
                    endedAt: now,
                    state: error is CancellationError ? .cancelled : .failed,
                    dryRun: dryRun,
                    message: error.localizedDescription,
                    logPath: ""
                )
                record.trigger = trigger
                self.finish(record, attempt: attempt)
            }
        }
    }

    private func startVerification(_ id: UUID) {
        guard let job = job(withID: id), !verifyingJobIDs.contains(id), !runningJobIDs.contains(id) else { return }
        verifyingJobIDs.insert(id)
        updateJob(id) { $0.lastMessage = "Checksum verification in progress…" }
        let box = RunningProcess()
        processBoxes[id] = box
        let runner = SyncRunner(applicationSupportURL: applicationSupportURL)
        let startedAt = Date()

        tasks[id] = Task { [weak self] in
            do {
                let report = try await runner.verify(job: job, processBox: box)
                guard let self else { return }
                self.finishVerification(job: job, report: report, startedAt: startedAt)
            } catch {
                guard let self else { return }
                if Self.isCancellation(error) {
                    self.finishCancelledVerification(job: job, startedAt: startedAt)
                    return
                }
                let report = VerificationReport(
                    verifiedAt: Date(),
                    matches: false,
                    message: error.localizedDescription
                )
                self.finishVerification(job: job, report: report, startedAt: startedAt)
            }
        }
    }

    private func finishVerification(job: SyncJob, report: VerificationReport, startedAt: Date) {
        verifyingJobIDs.remove(job.id)
        tasks[job.id] = nil
        processBoxes[job.id] = nil
        let state: JobState = report.matches ? .succeeded : .failed
        var record = RunRecord(
            jobID: job.id,
            jobName: job.name,
            startedAt: startedAt,
            endedAt: report.verifiedAt,
            state: state,
            dryRun: false,
            message: report.message,
            logPath: report.logPath ?? ""
        )
        record.verification = report
        record.trigger = .verification
        history.insert(record, at: 0)
        _ = trimHistoryToLimit()
        updateJob(job.id) {
            $0.lastVerificationAt = report.verifiedAt
            $0.lastVerificationSucceeded = report.matches
            $0.lastMessage = report.message
            if !report.matches { $0.lastState = .failed }
        }
        save()
        if report.matches {
            Task { await SystemNotificationManager.shared.post(.succeeded(summary: report.message), for: job) }
        } else {
            Task { await SystemNotificationManager.shared.post(.failed(message: report.message), for: job) }
        }
        let runPendingRealtime = pendingRealtimeRuns.remove(job.id) != nil &&
            job.enabled && job.schedule.kind == .realtime && !job.realtimeIsPaused()
        if runPendingRealtime { run(job.id, trigger: .realtime) }
        startNextPendingOperations()
    }

    private func finishCancelledVerification(job: SyncJob, startedAt: Date) {
        verifyingJobIDs.remove(job.id)
        tasks[job.id] = nil
        processBoxes[job.id] = nil
        let endedAt = Date()
        let message = "Checksum verification was cancelled."
        var record = RunRecord(
            jobID: job.id,
            jobName: job.name,
            startedAt: startedAt,
            endedAt: endedAt,
            state: .cancelled,
            dryRun: false,
            message: message,
            logPath: ""
        )
        record.trigger = .verification
        history.insert(record, at: 0)
        _ = trimHistoryToLimit()
        updateJob(job.id) { $0.lastMessage = message }
        save()
        let runPendingRealtime = pendingRealtimeRuns.remove(job.id) != nil &&
            job.enabled && job.schedule.kind == .realtime && !job.realtimeIsPaused()
        if runPendingRealtime { run(job.id, trigger: .realtime) }
        startNextPendingOperations()
    }

    func cancel(_ id: UUID) {
        let wasWaiting = queuedJobIDs.contains(id) || retryTasks[id] != nil
        realtimeDebounceTasks[id]?.cancel()
        realtimeDebounceTasks[id] = nil
        pendingRealtimeRuns.remove(id)
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = nil
        pendingOperations.removeAll { $0.jobID == id }
        queuedJobIDs.remove(id)
        processBoxes[id]?.cancel()
        tasks[id]?.cancel()
        if wasWaiting, !runningJobIDs.contains(id), !verifyingJobIDs.contains(id) {
            updateJob(id) { $0.lastMessage = "Removed from the queue." }
            save()
        }
    }

    func runAll() {
        for job in jobs where job.enabled { run(job.id) }
    }

    func nextRun(for job: SyncJob) -> Date? { nextScheduledRuns[job.id] }

    func isWatching(_ job: SyncJob) -> Bool { watchingJobIDs.contains(job.id) }

    func activeSync(for id: UUID) -> ActiveSyncSession? { activeSyncSessions[id] }

    func setHistoryLimit(_ limit: Int) {
        guard Self.historyLimitOptions.contains(limit) else { return }
        historyLimit = limit
        preferences.set(limit, forKey: Self.historyLimitDefaultsKey)
        if trimHistoryToLimit() { save() }
    }

    func setMaximumConcurrentRuns(_ value: Int) {
        guard Self.concurrencyOptions.contains(value) else { return }
        maximumConcurrentRuns = value
        preferences.set(value, forKey: Self.maximumConcurrentRunsDefaultsKey)
        startNextPendingOperations()
    }

    func setRetryLimit(_ value: Int) {
        guard Self.retryLimitOptions.contains(value) else { return }
        retryLimit = value
        preferences.set(value, forKey: Self.retryLimitDefaultsKey)
        let waitingIDs = retryAttempts.compactMap { $0.value > value ? $0.key : nil }
        if !waitingIDs.isEmpty {
            for id in waitingIDs {
                retryTasks[id]?.cancel()
                retryTasks[id] = nil
                retryAttempts[id] = nil
            }
            for id in waitingIDs where !runningJobIDs.contains(id) {
                updateJob(id) { $0.lastMessage = "The pending retry was cancelled by the new retry limit." }
            }
            save()
        }
    }

    func setRetryBaseDelaySeconds(_ value: Int) {
        guard Self.retryDelayOptions.contains(value) else { return }
        retryBaseDelaySeconds = value
        preferences.set(value, forKey: Self.retryDelayDefaultsKey)
    }

    func setStaleReminderDays(_ value: Int) {
        guard Self.staleReminderOptions.contains(value) else { return }
        staleReminderDays = value
        preferences.set(value, forKey: Self.staleReminderDefaultsKey)
        checkForStaleBackups()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard var copy = job(withID: id) else { return nil }
        copy.id = UUID()
        copy.name = uniqueCopyName(for: copy.name)
        copy.enabled = false
        copy.lastRunAt = nil
        copy.lastState = .idle
        copy.lastMessage = "Review this duplicated job, then enable it when ready."
        copy.lastVerificationAt = nil
        copy.lastVerificationSucceeded = nil
        jobs.append(copy)
        jobs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
        rebuildSchedule()
        rebuildFileWatchers()
        return copy.id
    }

    func pauseRealtime(_ id: UUID, until: Date?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].schedule.kind == .realtime else { return }
        jobs[index].realtimePausedUntil = until
        jobs[index].lastMessage = until.map {
            "Real-time watching paused until \($0.formatted(date: .abbreviated, time: .shortened))."
        } ?? "Real-time watching resumed."
        save()
        rebuildFileWatchers()
    }

    func verify(_ id: UUID) {
        guard job(withID: id) != nil,
              !runningJobIDs.contains(id),
              !verifyingJobIDs.contains(id),
              !queuedJobIDs.contains(id) else { return }
        enqueueVerification(id)
    }

    private func enqueueVerification(_ id: UUID) {
        enqueue(.verification(jobID: id))
    }

    func deleteHistoryRecord(_ id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        let record = history.remove(at: index)
        deleteLog(for: record)
        save()
    }

    func clearHistory(jobID: UUID? = nil) {
        let removed: [RunRecord]
        if let jobID {
            removed = history.filter { $0.jobID == jobID }
            history.removeAll { $0.jobID == jobID }
        } else {
            removed = history
            history.removeAll()
        }
        guard !removed.isEmpty else { return }
        removed.forEach(deleteLog)
        save()
    }

    func dismissMessage(for id: UUID) {
        guard job(withID: id)?.lastMessage != nil else { return }
        updateJob(id) { $0.lastMessage = nil }
        save()
    }

    func setPermissionVerification(_ enabled: Bool, for id: UUID) {
        guard job(withID: id) != nil else { return }
        updateJob(id) { $0.verifyPermissions = enabled }
        save()
    }

    func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFolder(_ endpoint: SyncEndpoint) {
        guard endpoint.kind != .remote else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: endpoint.path))
    }

    func archivedVersions(for id: UUID) -> [ArchivedVersion] {
        guard let job = job(withID: id), job.destination.kind != .remote else { return [] }
        do {
            return try SyncRunner(applicationSupportURL: applicationSupportURL).archivedVersions(for: job)
        } catch {
            bannerMessage = "Could not load archived versions: \(error.localizedDescription)"
            return []
        }
    }

    func chooseAndRestoreArchivedItem(
        jobID: UUID,
        version: ArchivedVersion,
        completion: @escaping () -> Void = {}
    ) {
        guard let job = job(withID: jobID), job.destination.kind != .remote else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Item to Restore"
        panel.prompt = "Choose"
        panel.directoryURL = version.directoryURL
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let rootPath = version.directoryURL.standardizedFileURL.path
        let selectedPath = selectedURL.standardizedFileURL.path
        guard selectedPath.hasPrefix(rootPath + "/") else {
            bannerMessage = "Choose an item inside the selected archive version."
            return
        }
        let relativePath = String(selectedPath.dropFirst(rootPath.count + 1))
        let alert = NSAlert()
        alert.messageText = "Restore \(selectedURL.lastPathComponent)?"
        alert.informativeText = "This replaces the current destination item. Project Sync will archive the current copy first when one exists."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let supportURL = applicationSupportURL
        let itemName = selectedURL.lastPathComponent
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try Self.archiveCurrentDestinationItem(
                        job: job,
                        relativePath: relativePath,
                        applicationSupportURL: supportURL
                    )
                    try SyncRunner(applicationSupportURL: supportURL).restoreArchivedItem(
                        job: job,
                        version: version,
                        relativePath: relativePath
                    )
                }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                self.bannerMessage = "Restored \(itemName) to the destination."
            case .failure(let error):
                self.bannerMessage = "Could not restore the archived item: \(error.localizedDescription)"
            }
            completion()
        }
    }

    private nonisolated static func archiveCurrentDestinationItem(
        job: SyncJob,
        relativePath: String,
        applicationSupportURL: URL
    ) throws {
        let destination = URL(fileURLWithPath: job.destination.path, isDirectory: true)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: destination.path),
              let archiveRun = RsyncCommand.archiveDirectory(for: job, at: Date()) else { return }
        let archiveItem = archiveRun.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: archiveItem.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: destination, to: archiveItem)
        FileManager.default.createFile(
            atPath: archiveRun.appendingPathComponent(".project-sync-complete").path,
            contents: Data()
        )
        let runner = SyncRunner(applicationSupportURL: applicationSupportURL)
        if let versions = try? runner.archivedVersions(for: job), versions.count > job.archiveVersionLimit {
            for oldVersion in versions.dropFirst(job.archiveVersionLimit) {
                try? FileManager.default.removeItem(at: oldVersion.directoryURL)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private func finish(_ record: RunRecord, attempt: Int) {
        runningJobIDs.remove(record.jobID)
        activeSyncSessions[record.jobID] = nil
        tasks[record.jobID] = nil
        processBoxes[record.jobID] = nil
        history.insert(record, at: 0)
        _ = trimHistoryToLimit()
        updateJob(record.jobID) {
            $0.lastRunAt = record.endedAt
            $0.lastState = record.state
            $0.lastMessage = record.message
        }
        save()
        if let job = job(withID: record.jobID) {
            if record.state == .succeeded {
                Task {
                    await SystemNotificationManager.shared.post(
                        .succeeded(summary: notificationSummary(for: record)),
                        for: job
                    )
                }
            } else if record.state == .failed {
                Task { await SystemNotificationManager.shared.post(.failed(message: record.message), for: job) }
            }
            nextScheduledRuns[job.id] = job.enabled ? job.schedule.nextDate(after: Date()) : nil
            let hasPendingRealtimeRun = pendingRealtimeRuns.remove(record.jobID) != nil &&
                job.enabled && job.schedule.kind == .realtime && !job.realtimeIsPaused()

            if shouldRetry(record), !record.dryRun, job.enabled, attempt < retryLimit {
                scheduleRetry(for: job, nextAttempt: attempt + 1)
            } else if hasPendingRealtimeRun {
                run(job.id, trigger: .realtime)
            } else if record.state == .succeeded, !record.dryRun, job.verifiesAfterSync {
                enqueueVerification(job.id)
            }
        }
        startNextPendingOperations()
    }

    private func scheduleRetry(for job: SyncJob, nextAttempt: Int) {
        retryTasks[job.id]?.cancel()
        retryAttempts[job.id] = nextAttempt
        let multiplier = 1 << max(0, nextAttempt - 1)
        let delay = min(3_600, retryBaseDelaySeconds * multiplier)
        updateJob(job.id) {
            $0.lastMessage = "Waiting to retry \(nextAttempt) of \(retryLimit) in \(Self.durationLabel(seconds: delay))…"
        }
        save()
        Task {
            await SystemNotificationManager.shared.post(
                .retryScheduled(attempt: nextAttempt, delay: TimeInterval(delay)),
                for: job
            )
        }
        retryTasks[job.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  let currentJob = self.job(withID: job.id), currentJob.enabled else { return }
            self.retryTasks[job.id] = nil
            self.retryAttempts[job.id] = nil
            self.enqueue(.sync(jobID: job.id, dryRun: false, trigger: .retry, attempt: nextAttempt))
        }
    }

    private func startNextPendingOperations() {
        while activeCount < maximumConcurrentRuns, !pendingOperations.isEmpty {
            let operation = pendingOperations.removeFirst()
            guard job(withID: operation.jobID) != nil else {
                queuedJobIDs.remove(operation.jobID)
                continue
            }
            start(operation)
        }
    }

    private static func durationLabel(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        return "\(seconds / 60) minutes"
    }

    private func shouldRetry(_ record: RunRecord) -> Bool {
        guard record.state == .failed else { return false }
        let message = record.message.lowercased()
        let transientExitCodes = [10, 11, 12, 23, 30, 35, 255]
        if transientExitCodes.contains(where: { message.contains("rsync exited with code \($0)") }) {
            return true
        }
        return [
            "source folder is unavailable",
            "network drive",
            "not mounted",
            "connection refused",
            "connection reset",
            "connection timed out",
            "operation timed out",
            "no route to host",
            "host is down"
        ].contains(where: message.contains)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let syncError = error as? SyncError else { return false }
        if case .cancelled = syncError { return true }
        return false
    }

    private func notificationSummary(for record: RunRecord) -> String? {
        guard let summary = record.transferSummary else { return record.message }
        var parts: [String] = []
        if let files = summary.filesTransferred { parts.append("\(files) files") }
        if let bytes = summary.transferredBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.isEmpty ? record.message : parts.joined(separator: ", ")
    }

    private func updateJob(_ id: UUID, change: (inout SyncJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func rebuildSchedule() {
        nextScheduledRuns = Dictionary(uniqueKeysWithValues: jobs.compactMap { job in
            guard job.enabled, let date = job.schedule.nextDate(after: Date()) else { return nil }
            return (job.id, date)
        })
    }

    private func rebuildFileWatchers() {
        let desiredJobs = jobs.filter {
            $0.enabled && $0.schedule.kind == .realtime && $0.source.kind != .remote && !$0.realtimeIsPaused()
        }
        let desiredPaths = Dictionary(uniqueKeysWithValues: desiredJobs.map {
            ($0.id, URL(fileURLWithPath: $0.source.path).standardizedFileURL.path)
        })

        for id in Array(fileWatchers.keys) {
            if desiredPaths[id] == nil || desiredPaths[id] != watchedSourcePaths[id] {
                removeFileWatcher(for: id)
            }
        }

        for job in desiredJobs where fileWatchers[job.id] == nil {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: job.source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let jobID = job.id
            let watcher = FileSystemWatcher(path: job.source.path) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.sourceDidChange(jobID)
                }
            }
            guard watcher.start() else { continue }
            fileWatchers[jobID] = watcher
            watchedSourcePaths[jobID] = desiredPaths[jobID]
            watchingJobIDs.insert(jobID)

            // FSEvents only reports activity from this point forward. Run once
            // when a watcher starts to catch changes made while the app or mount
            // was unavailable; later events are handled by the debounce path.
            if runningJobIDs.contains(jobID) || verifyingJobIDs.contains(jobID) || queuedJobIDs.contains(jobID) {
                pendingRealtimeRuns.insert(jobID)
            } else {
                run(jobID, trigger: .realtime)
            }
        }
    }

    private func removeFileWatcher(for id: UUID) {
        realtimeDebounceTasks[id]?.cancel()
        realtimeDebounceTasks[id] = nil
        fileWatchers.removeValue(forKey: id)?.stop()
        watchedSourcePaths[id] = nil
        watchingJobIDs.remove(id)
    }

    private func sourceDidChange(_ id: UUID) {
        guard let job = job(withID: id), job.enabled, job.schedule.kind == .realtime,
              !job.realtimeIsPaused() else { return }
        realtimeDebounceTasks[id]?.cancel()
        realtimeDebounceTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.realtimeDebounceTasks[id] = nil
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: job.source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                self.removeFileWatcher(for: id)
                return
            }
            if self.runningJobIDs.contains(id) ||
                self.verifyingJobIDs.contains(id) ||
                self.queuedJobIDs.contains(id) {
                self.pendingRealtimeRuns.insert(id)
            } else {
                self.run(id, trigger: .realtime)
            }
        }
    }

    private func schedulerTick() {
        resumeExpiredRealtimePauses()
        rebuildFileWatchers()
        checkForStaleBackups()
        let now = Date()
        for job in jobs where job.enabled &&
            !runningJobIDs.contains(job.id) &&
            !verifyingJobIDs.contains(job.id) &&
            !queuedJobIDs.contains(job.id) {
            guard let due = nextScheduledRuns[job.id], due <= now else { continue }
            run(job.id, trigger: .schedule)
            nextScheduledRuns[job.id] = job.schedule.nextDate(after: now.addingTimeInterval(1))
        }
    }

    private func volumeDidMount(_ volumeURL: URL) {
        let mountedPath = volumeURL.standardizedFileURL.path
        for job in jobs where job.enabled && endpoints(of: job, touchVolumeAt: mountedPath) {
            if let attempt = retryAttempts[job.id] {
                guard !runningJobIDs.contains(job.id),
                      !verifyingJobIDs.contains(job.id),
                      !queuedJobIDs.contains(job.id) else { continue }
                retryTasks[job.id]?.cancel()
                retryTasks[job.id] = nil
                retryAttempts[job.id] = nil
                enqueue(.sync(jobID: job.id, dryRun: false, trigger: .retry, attempt: attempt))
            } else if job.runsWhenVolumeMounts {
                run(job.id, trigger: .volumeMount)
            }
        }
        rebuildFileWatchers()
    }

    private func endpoints(of job: SyncJob, touchVolumeAt volumePath: String) -> Bool {
        [job.source, job.destination].contains { endpoint in
            guard endpoint.kind != .remote else { return false }
            let path = URL(fileURLWithPath: endpoint.path).standardizedFileURL.path
            return path == volumePath || path.hasPrefix(volumePath.hasSuffix("/") ? volumePath : volumePath + "/")
        }
    }

    private func resumeExpiredRealtimePauses() {
        let now = Date()
        var changed = false
        for index in jobs.indices {
            if let pausedUntil = jobs[index].realtimePausedUntil, pausedUntil <= now {
                jobs[index].realtimePausedUntil = nil
                changed = true
            }
        }
        if changed { save() }
    }

    private func checkForStaleBackups() {
        guard staleReminderDays > 0 else { return }
        let now = Date()
        let cutoff = now.addingTimeInterval(-TimeInterval(staleReminderDays * 86_400))
        for job in jobs where job.enabled {
            guard let lastSuccess = history.first(where: {
                $0.jobID == job.id && $0.state == .succeeded && !$0.dryRun && $0.trigger != .verification
            })?.endedAt, lastSuccess < cutoff else { continue }
            let key = Self.staleReminderSentPrefix + job.id.uuidString
            let lastReminder = preferences.object(forKey: key) as? Date
            guard lastReminder == nil || now.timeIntervalSince(lastReminder!) >= 86_400 else { continue }
            preferences.set(now, forKey: key)
            Task {
                await SystemNotificationManager.shared.post(
                    .staleBackup(lastSuccessfulRun: lastSuccess),
                    for: job
                )
            }
            NotificationCenter.default.post(
                name: .projectSyncBackupIsStale,
                object: nil,
                userInfo: ["jobName": job.name, "days": staleReminderDays]
            )
        }
    }

    private func uniqueCopyName(for original: String) -> String {
        let base = original + " Copy"
        if !jobs.contains(where: { $0.name.localizedCaseInsensitiveCompare(base) == .orderedSame }) {
            return base
        }
        var number = 2
        while jobs.contains(where: {
            $0.name.localizedCaseInsensitiveCompare("\(base) \(number)") == .orderedSame
        }) {
            number += 1
        }
        return "\(base) \(number)"
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: jobsURL), let decoded = try? decoder.decode([SyncJob].self, from: data) {
            jobs = decoded
        }
        if let data = try? Data(contentsOf: historyURL), let decoded = try? decoder.decode([RunRecord].self, from: data) {
            history = decoded
        }
    }

    @discardableResult
    private func trimHistoryToLimit() -> Bool {
        guard history.count > historyLimit else { return false }
        let removed = Array(history.dropFirst(historyLimit))
        history.removeLast(history.count - historyLimit)
        removed.forEach(deleteLog)
        return true
    }

    private func deleteLog(for record: RunRecord) {
        guard !record.logPath.isEmpty else { return }
        let logsDirectory = applicationSupportURL
            .appendingPathComponent("Logs", isDirectory: true)
            .standardizedFileURL
        let logURL = URL(fileURLWithPath: record.logPath).standardizedFileURL
        guard logURL.path.hasPrefix(logsDirectory.path + "/") else { return }
        try? FileManager.default.removeItem(at: logURL)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(jobs).write(to: jobsURL, options: .atomic)
            try encoder.encode(history).write(to: historyURL, options: .atomic)
        } catch {
            bannerMessage = "Could not save Project Sync data: \(error.localizedDescription)"
        }
    }

    private var jobsURL: URL { applicationSupportURL.appendingPathComponent("jobs.json") }
    private var historyURL: URL { applicationSupportURL.appendingPathComponent("history.json") }
    private static let historyLimitDefaultsKey = "historyLimit"
    private static let maximumConcurrentRunsDefaultsKey = "maximumConcurrentRuns"
    private static let retryLimitDefaultsKey = "retryLimit"
    private static let retryDelayDefaultsKey = "retryBaseDelaySeconds"
    private static let staleReminderDefaultsKey = "staleReminderDays"
    private static let staleReminderSentPrefix = "staleReminderSent."
}

extension Notification.Name {
    static let projectSyncBackupIsStale = Notification.Name("ProjectSync.backupIsStale")
}
