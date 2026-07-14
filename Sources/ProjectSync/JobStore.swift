import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [SyncJob] = []
    @Published private(set) var history: [RunRecord] = []
    @Published private(set) var runningJobIDs: Set<UUID> = []
    @Published private(set) var watchingJobIDs: Set<UUID> = []
    @Published var bannerMessage: String?

    let applicationSupportURL: URL
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var processBoxes: [UUID: RunningProcess] = [:]
    private var nextScheduledRuns: [UUID: Date] = [:]
    private var fileWatchers: [UUID: FileSystemWatcher] = [:]
    private var watchedSourcePaths: [UUID: String] = [:]
    private var realtimeDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRealtimeRuns: Set<UUID> = []
    private var scheduler: Timer?

    init(applicationSupportURL: URL? = nil) {
        self.applicationSupportURL = applicationSupportURL ?? Self.defaultApplicationSupportURL
        load()
        rebuildSchedule()
        rebuildFileWatchers()
        scheduler = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.schedulerTick() }
        }
    }

    deinit {
        scheduler?.invalidate()
        realtimeDebounceTasks.values.forEach { $0.cancel() }
        fileWatchers.values.forEach { $0.stop() }
    }

    static var defaultApplicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Project Sync", isDirectory: true)
    }

    var activeCount: Int { runningJobIDs.count }
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
        save()
        rebuildSchedule()
        rebuildFileWatchers()
    }

    func run(_ id: UUID, dryRun: Bool = false) {
        guard let job = job(withID: id), !runningJobIDs.contains(id) else { return }
        updateJob(id) {
            $0.lastState = .running
            $0.lastMessage = dryRun ? "Previewing changes…" : "Sync in progress…"
        }
        runningJobIDs.insert(id)
        let box = RunningProcess()
        processBoxes[id] = box
        let runner = SyncRunner(applicationSupportURL: applicationSupportURL)

        tasks[id] = Task { [weak self] in
            do {
                let record = try await runner.run(job: job, dryRun: dryRun, processBox: box)
                guard let self else { return }
                self.finish(record)
            } catch {
                guard let self else { return }
                let now = Date()
                let record = RunRecord(
                    jobID: job.id,
                    jobName: job.name,
                    startedAt: now,
                    endedAt: now,
                    state: error is CancellationError ? .cancelled : .failed,
                    dryRun: dryRun,
                    message: error.localizedDescription,
                    logPath: ""
                )
                self.finish(record)
            }
        }
    }

    func cancel(_ id: UUID) {
        realtimeDebounceTasks[id]?.cancel()
        realtimeDebounceTasks[id] = nil
        pendingRealtimeRuns.remove(id)
        processBoxes[id]?.cancel()
        tasks[id]?.cancel()
    }

    func runAll() {
        for job in jobs where job.enabled { run(job.id) }
    }

    func nextRun(for job: SyncJob) -> Date? { nextScheduledRuns[job.id] }

    func isWatching(_ job: SyncJob) -> Bool { watchingJobIDs.contains(job.id) }

    func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFolder(_ endpoint: SyncEndpoint) {
        guard endpoint.kind != .remote else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: endpoint.path))
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

    private func finish(_ record: RunRecord) {
        runningJobIDs.remove(record.jobID)
        tasks[record.jobID] = nil
        processBoxes[record.jobID] = nil
        history.insert(record, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        updateJob(record.jobID) {
            $0.lastRunAt = record.endedAt
            $0.lastState = record.state
            $0.lastMessage = record.message
        }
        save()
        if let job = job(withID: record.jobID) {
            nextScheduledRuns[job.id] = job.enabled ? job.schedule.nextDate(after: Date()) : nil
            if pendingRealtimeRuns.remove(record.jobID) != nil,
               job.enabled, job.schedule.kind == .realtime {
                run(job.id)
            }
        }
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
            $0.enabled && $0.schedule.kind == .realtime && $0.source.kind != .remote
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
            if !runningJobIDs.contains(jobID) {
                run(jobID)
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
        guard let job = job(withID: id), job.enabled, job.schedule.kind == .realtime else { return }
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
            if self.runningJobIDs.contains(id) {
                self.pendingRealtimeRuns.insert(id)
            } else {
                self.run(id)
            }
        }
    }

    private func schedulerTick() {
        rebuildFileWatchers()
        let now = Date()
        for job in jobs where job.enabled && !runningJobIDs.contains(job.id) {
            guard let due = nextScheduledRuns[job.id], due <= now else { continue }
            run(job.id)
            nextScheduledRuns[job.id] = job.schedule.nextDate(after: now.addingTimeInterval(1))
        }
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
}
