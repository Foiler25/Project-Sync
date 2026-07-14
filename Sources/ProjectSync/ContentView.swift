import AppKit
import SwiftUI

private struct EditorPresentation: Identifiable {
    let id = UUID()
    let job: SyncJob
    let isNew: Bool
}

private enum SidebarSelection: Hashable {
    case overview
    case job(UUID)
}

struct ContentView: View {
    @EnvironmentObject private var store: JobStore
    @State private var selection: SidebarSelection? = .overview
    @State private var editor: EditorPresentation?
    @State private var pendingDelete: SyncJob?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 330)
        } detail: {
            if case .job(let id) = selection, let job = store.job(withID: id) {
                JobDetailView(job: job) {
                    editor = EditorPresentation(job: job, isNew: false)
                } onDuplicate: {
                    if let duplicateID = store.duplicate(job.id) {
                        selection = .job(duplicateID)
                    }
                } onDelete: {
                    pendingDelete = job
                }
            } else {
                OverviewView(onCreate: createJob)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: createJob) { Label("New Sync", systemImage: "plus") }
                    .help("Create a new sync job")
                Button { store.runAll() } label: { Label("Run All", systemImage: "play.fill") }
                    .disabled(store.jobs.isEmpty)
                    .help("Run all enabled sync jobs")
                SettingsLink { Label("Settings", systemImage: "gear") }
                    .help("Open Project Sync settings")
            }
        }
        .sheet(item: $editor) { presentation in
            JobEditorView(job: presentation.job, isNew: presentation.isNew) { saved in
                store.upsert(saved)
                selection = .job(saved.id)
            }
        }
        .alert("Delete \(pendingDelete?.name ?? "sync")?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.id { store.delete(id) }
                selection = .overview
                pendingDelete = nil
            }
        } message: {
            Text("The job and its schedule will be removed. Your files will not be changed.")
        }
        .alert("Project Sync", isPresented: Binding(
            get: { store.bannerMessage != nil },
            set: { if !$0 { store.bannerMessage = nil } }
        )) { Button("OK") { store.bannerMessage = nil } } message: {
            Text(store.bannerMessage ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.overview)
            }
            Section("Sync Jobs") {
                ForEach(store.jobs) { job in
                    JobSidebarRow(
                        job: job,
                        running: store.runningJobIDs.contains(job.id) || store.verifyingJobIDs.contains(job.id),
                        queued: store.queuedJobIDs.contains(job.id)
                    )
                        .tag(SidebarSelection.job(job.id))
                        .contextMenu {
                            Button("Run Now") { store.run(job.id) }
                            Button("Preview Changes") { store.run(job.id, dryRun: true) }
                            Divider()
                            Button("Edit…") { editor = EditorPresentation(job: job, isNew: false) }
                            Button("Duplicate Job") {
                                if let duplicateID = store.duplicate(job.id) {
                                    selection = .job(duplicateID)
                                }
                            }
                            Button("Delete", role: .destructive) { pendingDelete = job }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: createJob) { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("New sync job")
                Spacer()
                Text(store.activeCount > 0 ? "\(store.activeCount) running" : "Local first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.bar)
        }
    }

    private func createJob() {
        editor = EditorPresentation(job: SyncJob(), isNew: true)
    }
}

private struct JobSidebarRow: View {
    let job: SyncJob
    let running: Bool
    let queued: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: running ? "arrow.triangle.2.circlepath" : (queued ? "hourglass" : job.lastState.symbol))
                .foregroundStyle((running || queued) ? Color.accentColor : job.lastState.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                Text(queued ? "Queued" : job.schedule.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !job.enabled { Image(systemName: "pause.fill").foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 3)
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: JobStore
    let onCreate: () -> Void
    @State private var selectedRecord: RunRecord?
    @State private var historySearchText = ""

    private var filteredHistory: [RunRecord] {
        store.history.filter { $0.matchesHistorySearch(historySearchText) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Project Sync").font(.largeTitle.bold())
                        Text("Your files, where you want them—without leaving your network.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onCreate) { Label("New Sync", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }

                HStack(spacing: 14) {
                    MetricCard(title: "Sync Jobs", value: "\(store.jobs.count)", symbol: "arrow.left.arrow.right", color: .blue)
                    MetricCard(title: "Up to Date", value: "\(store.successfulJobs)", symbol: "checkmark.circle", color: .green)
                    MetricCard(title: "Running", value: "\(store.activeCount)", symbol: "arrow.triangle.2.circlepath", color: .indigo)
                    MetricCard(title: "Attention", value: "\(store.attentionJobs)", symbol: "exclamationmark.triangle", color: .orange)
                }

                if store.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("Create your first sync", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Connect folders on this Mac, mounted NAS drives, or remote servers over SSH.")
                    } actions: {
                        Button("Create Sync Job", action: onCreate).buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Run history").font(.title2.bold())
                            Spacer()
                            Text(historySearchText.isEmpty
                                 ? "\(store.history.count) of up to \(store.historyLimit) entries"
                                 : "\(filteredHistory.count) of \(store.history.count) entries")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        TextField("Search history", text: $historySearchText)
                            .textFieldStyle(.roundedBorder)
                        if store.history.isEmpty {
                            Text("Runs will appear here after your first sync.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 30)
                        } else if filteredHistory.isEmpty {
                            ContentUnavailableView.search(text: historySearchText)
                                .frame(maxWidth: .infinity, minHeight: 150)
                        } else {
                            ForEach(filteredHistory) { record in
                                RunRecordRow(record: record) {
                                    if selectedRecord?.id == record.id { selectedRecord = nil }
                                    store.deleteHistoryRecord(record.id)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { selectedRecord = record }
                                .contextMenu {
                                    Button("Delete History Entry", role: .destructive) {
                                        store.deleteHistoryRecord(record.id)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(32)
        }
        .sheet(item: $selectedRecord) { LogView(record: $0) }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title2.bold()).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)) }
    }
}

struct JobDetailView: View {
    @EnvironmentObject private var store: JobStore
    let job: SyncJob
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    @State private var selectedRecord: RunRecord?
    @State private var confirmingClearHistory = false
    @State private var historySearchText = ""
    @State private var showingArchives = false
    @State private var selectedLiveSync: ActiveSyncSession?
    private let centerGutterWidth: CGFloat = 34

    private var running: Bool { store.runningJobIDs.contains(job.id) }
    private var verifying: Bool { store.verifyingJobIDs.contains(job.id) }
    private var queued: Bool { store.queuedJobIDs.contains(job.id) }
    private var active: Bool { running || verifying }
    private var busy: Bool { active || queued }
    private var jobHistory: [RunRecord] {
        store.history.filter { $0.jobID == job.id }
    }
    private var filteredJobHistory: [RunRecord] {
        jobHistory.filter { $0.matchesHistorySearch(historySearchText) }
    }
    private var latestVerification: VerificationReport? {
        jobHistory.compactMap(\.verification).first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(job.name).font(.largeTitle.bold())
                        Label(busy ? (queued ? "Queued" : (verifying ? "Verifying now" : "Syncing now")) : job.lastState.label,
                              systemImage: busy ? (queued ? "hourglass" : (verifying ? "checkmark.shield" : "arrow.triangle.2.circlepath")) : job.lastState.symbol)
                            .foregroundStyle(busy ? Color.accentColor : job.lastState.color)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(
                        get: { job.enabled },
                        set: { store.setEnabled($0, for: job.id) }
                    )).toggleStyle(.switch)
                }

                HStack(spacing: 12) {
                    Button {
                        busy ? store.cancel(job.id) : store.run(job.id)
                    } label: {
                        Label(busy ? (queued ? "Remove from Queue" : "Stop") : "Run Now",
                              systemImage: busy ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if let session = store.activeSync(for: job.id) {
                        Button {
                            selectedLiveSync = session
                        } label: {
                            Label("View Live Sync…", systemImage: "waveform.path.ecg")
                        }
                        .controlSize(.large)
                    }
                    Button { store.run(job.id, dryRun: true) } label: { Label("Preview Changes", systemImage: "doc.text.magnifyingglass") }
                        .controlSize(.large).disabled(busy)
                    Button { store.verify(job.id) } label: { Label("Verify", systemImage: "checkmark.shield") }
                        .controlSize(.large).disabled(busy)
                    Button("Edit…", action: onEdit).controlSize(.large)
                    Spacer()
                    Menu {
                        Button("Duplicate Job", systemImage: "plus.square.on.square", action: onDuplicate)
                        if job.keepsVersionedArchive && job.destination.kind != .remote {
                            Button("Browse Archives…", systemImage: "archivebox") {
                                showingArchives = true
                            }
                        }
                        if job.schedule.kind == .realtime {
                            Divider()
                            if job.realtimeIsPaused() {
                                Button("Resume Real-time Watching", systemImage: "play.fill") {
                                    store.pauseRealtime(job.id, until: nil)
                                }
                            } else {
                                Button("Pause for 1 Hour", systemImage: "pause.fill") {
                                    store.pauseRealtime(job.id, until: Date().addingTimeInterval(60 * 60))
                                }
                                Button("Pause Until Tomorrow", systemImage: "moon.fill") {
                                    store.pauseRealtime(job.id, until: tomorrow)
                                }
                            }
                        }
                        Divider()
                        Button("Delete Job", role: .destructive, action: onDelete)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                }

                if busy {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(queued ? "Waiting for an available run slot" : (verifying ? "Verification in progress" : "Sync in progress"),
                                  systemImage: queued ? "hourglass" : (verifying ? "checkmark.shield" : "arrow.triangle.2.circlepath"))
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(queued ? "Queued" : (verifying ? "Comparing source and destination…" : "Preparing and transferring files…"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    .padding(.horizontal, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 12) {
                    EndpointCard(title: "FROM", endpoint: job.source) { store.openFolder(job.source) }
                    Image(systemName: "arrow.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: centerGutterWidth, height: centerGutterWidth)
                        .background(.quaternary.opacity(0.55), in: Circle())
                        .overlay { Circle().stroke(.separator.opacity(0.5)) }
                    EndpointCard(title: "TO", endpoint: job.destination) { store.openFolder(job.destination) }
                }

                if let notes = job.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Notes", systemImage: "note.text").font(.headline)
                        Text(notes)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)) }
                }

                HStack(spacing: 12) {
                    InfoCard(title: "Mode", value: job.mode.rawValue, detail: job.mode.detail, symbol: job.mode == .mirror ? "rectangle.2.swap" : "archivebox")
                    Color.clear
                        .frame(width: centerGutterWidth)
                        .accessibilityHidden(true)
                    InfoCard(
                        title: "Schedule",
                        value: job.schedule.summary,
                        detail: scheduleDetail,
                        symbol: job.schedule.kind == .realtime ? "eye" : "calendar.badge.clock"
                    )
                }

                if let report = latestVerification {
                    VerificationResultCard(report: report) {
                        store.setPermissionVerification(false, for: job.id)
                    }
                } else if let verifiedAt = job.lastVerificationAt, let succeeded = job.lastVerificationSucceeded {
                    Label {
                        Text(succeeded ? "Backup verified" : "Verification found differences")
                            .fontWeight(.medium)
                        + Text(" • \(verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: succeeded ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(succeeded ? Color.green : Color.orange)
                }

                if let message = job.lastMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: job.lastState.symbol)
                            .padding(.top, 2)
                        Text(message)
                            .lineLimit(4)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            store.dismissMessage(for: job.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss message")
                        .accessibilityLabel("Dismiss message")
                    }
                    .font(.callout)
                    .foregroundStyle(job.lastState.color)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(job.lastState.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Run history").font(.title2.bold())
                        Text(historySearchText.isEmpty
                             ? "\(jobHistory.count) entries"
                             : "\(filteredJobHistory.count) of \(jobHistory.count) entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !jobHistory.isEmpty {
                            Button("Clear Job History…") { confirmingClearHistory = true }
                                .controlSize(.small)
                        }
                    }
                    TextField("Search this job’s history", text: $historySearchText)
                        .textFieldStyle(.roundedBorder)
                    if jobHistory.isEmpty {
                        Text("No runs yet. Preview the job to verify what will change.")
                            .foregroundStyle(.secondary).padding(.vertical, 18)
                    } else if filteredJobHistory.isEmpty {
                        ContentUnavailableView.search(text: historySearchText)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        ForEach(filteredJobHistory) { record in
                            RunRecordRow(record: record) {
                                if selectedRecord?.id == record.id { selectedRecord = nil }
                                store.deleteHistoryRecord(record.id)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedRecord = record }
                            .contextMenu {
                                Button("Delete History Entry", role: .destructive) {
                                    store.deleteHistoryRecord(record.id)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            .padding(32)
        }
        .sheet(item: $selectedRecord) { LogView(record: $0) }
        .sheet(item: $selectedLiveSync) { LiveSyncView(session: $0) }
        .sheet(isPresented: $showingArchives) {
            ArchiveBrowserView(job: job)
        }
        .alert("Clear History for \(job.name)?", isPresented: $confirmingClearHistory) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { store.clearHistory(jobID: job.id) }
        } message: {
            Text("This permanently removes this job’s run records and saved log files. Synced files are not affected.")
        }
    }

    private var scheduleDetail: String {
        if job.schedule.kind == .realtime {
            if !job.enabled { return "Watcher paused" }
            if let pausedUntil = job.realtimePausedUntil, pausedUntil > Date() {
                return "Paused until \(pausedUntil.formatted(date: .abbreviated, time: .shortened))"
            }
            return store.isWatching(job)
                ? "Watching the source; changes sync after a 2-second pause"
                : "Source unavailable; watcher will retry"
        }
        return store.nextRun(for: job).map {
            "Next: \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "Runs only when you start it"
    }

    private var tomorrow: Date {
        Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    }
}

private struct ArchiveBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JobStore
    let job: SyncJob
    @State private var versions: [ArchivedVersion] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Versioned Archive").font(.title2.bold())
                    Text(job.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if versions.isEmpty {
                ContentUnavailableView {
                    Label("No Archived Items", systemImage: "archivebox")
                } description: {
                    Text("Archive versions appear after a sync replaces or removes files from the destination.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(versions) { version in
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(version.createdAt.formatted(date: .long, time: .shortened))
                                .fontWeight(.medium)
                            Text(version.directoryURL.lastPathComponent)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Restore Item…") {
                            store.chooseAndRestoreArchivedItem(jobID: job.id, version: version) {
                                versions = store.archivedVersions(for: job.id)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            versions = store.archivedVersions(for: job.id)
        }
    }
}

private struct EndpointCard: View {
    let title: String
    let endpoint: SyncEndpoint
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: endpoint.kind.symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(endpoint.kind.rawValue).font(.headline)
                    Text(endpoint.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                if endpoint.kind != .remote { Button(action: open) { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.plain) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 105)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.7)) }
    }
}

private struct InfoCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                Text(value).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 112, alignment: .top)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.7)) }
    }
}

private struct VerificationResultCard: View {
    let report: VerificationReport
    var makePermissionsAdvisory: (() -> Void)? = nil
    @State private var showsFixes = false

    private var contentDifferences: Int { report.contentDifferences ?? 0 }
    private var permissionDifferences: Int { report.permissionDifferences ?? 0 }
    private var metadataDifferences: Int { report.metadataDifferences ?? 0 }
    private var destinationOnlyItems: Int { report.destinationOnlyItems ?? 0 }
    private var permissionsRequired: Bool { report.permissionVerificationEnabled ?? false }
    private var title: String {
        if !report.hasDetailedResults { return "Verification could not complete" }
        if !report.fileContentMatches { return "File content needs attention" }
        if permissionsRequired && permissionDifferences > 0 { return "File content verified; permissions differ" }
        return "File content verified"
    }
    private var color: Color {
        if !report.hasDetailedResults { return .red }
        return report.fileContentMatches && (!permissionsRequired || permissionDifferences == 0) ? .green : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: !report.hasDetailedResults
                      ? "xmark.octagon.fill"
                      : (report.fileContentMatches ? "checkmark.shield.fill" : "exclamationmark.shield.fill"))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(report.message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(report.verifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if report.hasDetailedResults {
                HStack(spacing: 8) {
                    VerificationMetric(
                        title: "File content",
                        value: contentDifferences == 0 && destinationOnlyItems == 0
                            ? "Matches" : "\(contentDifferences + destinationOnlyItems) different",
                        symbol: contentDifferences == 0 && destinationOnlyItems == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        color: contentDifferences == 0 && destinationOnlyItems == 0 ? .green : .orange
                    )
                    VerificationMetric(
                        title: "Permissions",
                        value: permissionDifferences == 0
                            ? "Match" : "\(permissionDifferences) \(permissionsRequired ? "different" : "advisory")",
                        symbol: permissionDifferences == 0 ? "checkmark.circle.fill" : "lock.trianglebadge.exclamationmark",
                        color: permissionDifferences == 0 ? .green : (permissionsRequired ? .orange : .secondary)
                    )
                    VerificationMetric(
                        title: "Other metadata",
                        value: metadataDifferences == 0 ? "Matches" : "\(metadataDifferences) advisory",
                        symbol: metadataDifferences == 0 ? "checkmark.circle.fill" : "info.circle.fill",
                        color: metadataDifferences == 0 ? .green : .secondary
                    )
                }
            }

            if permissionsRequired, permissionDifferences > 0, let makePermissionsAdvisory {
                Button("Treat Permission Differences as Advisory for This Job") {
                    makePermissionsAdvisory()
                }
                .controlSize(.small)
            }

            if let fixes = report.potentialFixes, !fixes.isEmpty {
                DisclosureGroup("Potential fixes", isExpanded: $showsFixes) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(fixes, id: \.self) { fix in
                            Label(fix, systemImage: "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 7)
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(color.opacity(0.25)) }
    }
}

private struct VerificationMetric: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RunRecordRow: View {
    let record: RunRecord
    let onDelete: (() -> Void)?

    init(record: RunRecord, onDelete: (() -> Void)? = nil) {
        self.record = record
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.state.symbol).foregroundStyle(record.state.color).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(record.jobName).fontWeight(.medium); if record.dryRun { Text("PREVIEW").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2).background(.blue.opacity(0.12), in: Capsule()).foregroundStyle(.blue) } }
                Text(record.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let summary = record.transferSummary, let detail = summary.compactDescription {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Last run")
                        .foregroundStyle(.secondary)
                    Text(record.endedAt, style: .relative)
                }
                .font(.caption)
                HStack(spacing: 4) {
                    Text("Run time")
                    Text(record.duration.formattedDuration)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete history entry and log")
                .accessibilityLabel("Delete history entry")
            }
        }
        .padding(.vertical, 5)
    }
}

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JobStore
    let record: RunRecord
    @State private var preview: LogPreview?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.jobName).font(.headline)
                    HStack(spacing: 7) {
                        Text(record.startedAt.formatted())
                        if let preview, preview.isTruncated {
                            Text("•")
                            Text("Showing the last \(preview.loadedBytes.formatted(.byteCount(style: .file))) of \(preview.totalBytes.formatted(.byteCount(style: .file)))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if !record.logPath.isEmpty {
                    Button("Reveal Full Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.logPath)])
                    }
                }
                Button("Delete", role: .destructive) {
                    store.deleteHistoryRecord(record.id)
                    dismiss()
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
            Divider()
            if let verification = record.verification {
                VerificationResultCard(report: verification)
                    .padding()
                Divider()
            }
            if let preview {
                ReadOnlyLogTextView(text: preview.text)
            } else {
                ProgressView("Loading log preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task(id: record.id) {
            preview = await LogPreviewLoader.load(path: record.logPath, fallback: record.message)
        }
    }
}

struct LiveSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JobStore
    let session: ActiveSyncSession
    @State private var preview: LogPreview?
    @State private var now = Date()

    private var isRunning: Bool { store.runningJobIDs.contains(session.jobID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.jobName).font(.headline)
                    HStack(spacing: 6) {
                        Text(session.dryRun ? "Live preview" : "Live sync")
                        Text("•")
                        Text(now.timeIntervalSince(session.startedAt).formattedDuration)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.logPath)])
                }
                if isRunning {
                    Button("Stop", role: .destructive) { store.cancel(session.jobID) }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(
                        isRunning ? "Transfer in progress" : "Transfer finished",
                        systemImage: isRunning ? "arrow.triangle.2.circlepath" : "checkmark.circle"
                    )
                    .font(.callout.weight(.medium))
                    Spacer()
                    if let percentage = latestPercentage, isRunning {
                        Text("Current file: \(percentage)%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let percentage = latestPercentage, isRunning {
                    ProgressView(value: Double(percentage), total: 100)
                        .progressViewStyle(.linear)
                } else if isRunning {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)

            Divider()
            if let preview {
                ReadOnlyLogTextView(
                    text: preview.text.replacingOccurrences(of: "\r", with: "\n"),
                    followTail: isRunning
                )
            } else {
                ProgressView("Waiting for transfer output…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: session.id) {
            while !Task.isCancelled {
                preview = await LogPreviewLoader.load(
                    path: session.logPath,
                    fallback: "Waiting for transfer output…"
                )
                now = Date()
                if !store.runningJobIDs.contains(session.jobID) { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var latestPercentage: Int? {
        guard let text = preview?.text,
              let expression = try? NSRegularExpression(pattern: #"(\d{1,3})%"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.matches(in: text, range: range).last,
              let percentRange = Range(match.range(at: 1), in: text),
              let value = Int(text[percentRange]), (0...100).contains(value) else { return nil }
        return value
    }
}

extension JobState {
    var color: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        }
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        if self < 1 { return "<1 sec" }
        if self < 60 { return "\(Int(self)) sec" }
        return "\(Int(self / 60)) min \(Int(self.truncatingRemainder(dividingBy: 60))) sec"
    }
}

private extension RunRecord {
    func matchesHistorySearch(_ searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return jobName.localizedCaseInsensitiveContains(query)
            || message.localizedCaseInsensitiveContains(query)
            || state.label.localizedCaseInsensitiveContains(query)
    }
}

private extension TransferSummary {
    var compactDescription: String? {
        var components: [String] = []
        if let filesTransferred { components.append("\(filesTransferred) transferred") }
        if let filesChanged { components.append("\(filesChanged) changed") }
        if let filesDeleted, filesDeleted > 0 { components.append("\(filesDeleted) deleted") }
        if let transferredBytes { components.append(transferredBytes.formatted(.byteCount(style: .file))) }
        if let bytesPerSecond, bytesPerSecond > 0 {
            components.append("\(Int64(bytesPerSecond).formatted(.byteCount(style: .file)))/s")
        }
        return components.isEmpty ? nil : components.joined(separator: " • ")
    }
}
