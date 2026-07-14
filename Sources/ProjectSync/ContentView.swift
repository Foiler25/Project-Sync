import AppKit
import SwiftUI

private struct EditorPresentation: Identifiable {
    let id = UUID()
    let job: SyncJob
    let isNew: Bool
}

struct ContentView: View {
    @EnvironmentObject private var store: JobStore
    @State private var selection: UUID?
    @State private var editor: EditorPresentation?
    @State private var pendingDelete: SyncJob?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 330)
        } detail: {
            if let job = store.job(withID: selection) {
                JobDetailView(job: job) {
                    editor = EditorPresentation(job: job, isNew: false)
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
                Button { store.runAll() } label: { Label("Run All", systemImage: "play.fill") }
                    .disabled(store.jobs.isEmpty)
                SettingsLink { Label("Settings", systemImage: "gear") }
            }
        }
        .sheet(item: $editor) { presentation in
            JobEditorView(job: presentation.job, isNew: presentation.isNew) { saved in
                store.upsert(saved)
                selection = saved.id
            }
        }
        .alert("Delete \(pendingDelete?.name ?? "sync")?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.id { store.delete(id) }
                selection = nil
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
                    .tag(nil as UUID?)
            }
            Section("Sync Jobs") {
                ForEach(store.jobs) { job in
                    JobSidebarRow(job: job, running: store.runningJobIDs.contains(job.id))
                        .tag(job.id as UUID?)
                        .contextMenu {
                            Button("Run Now") { store.run(job.id) }
                            Button("Preview Changes") { store.run(job.id, dryRun: true) }
                            Divider()
                            Button("Edit…") { editor = EditorPresentation(job: job, isNew: false) }
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: running ? "arrow.triangle.2.circlepath" : job.lastState.symbol)
                .foregroundStyle(running ? Color.accentColor : job.lastState.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                Text(job.schedule.summary)
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
                        Text("Recent activity").font(.title2.bold())
                        if store.history.isEmpty {
                            Text("Runs will appear here after your first sync.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 30)
                        } else {
                            ForEach(store.history.prefix(8)) { record in
                                RunRecordRow(record: record).contentShape(Rectangle()).onTapGesture { selectedRecord = record }
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
    let onDelete: () -> Void
    @State private var selectedRecord: RunRecord?
    private let centerGutterWidth: CGFloat = 34

    private var running: Bool { store.runningJobIDs.contains(job.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(job.name).font(.largeTitle.bold())
                        Label(running ? "Syncing now" : job.lastState.label, systemImage: running ? "arrow.triangle.2.circlepath" : job.lastState.symbol)
                            .foregroundStyle(running ? Color.accentColor : job.lastState.color)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(
                        get: { job.enabled },
                        set: { store.setEnabled($0, for: job.id) }
                    )).toggleStyle(.switch)
                }

                HStack(spacing: 12) {
                    Button {
                        running ? store.cancel(job.id) : store.run(job.id)
                    } label: {
                        Label(running ? "Stop" : "Run Now", systemImage: running ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button { store.run(job.id, dryRun: true) } label: { Label("Preview Changes", systemImage: "doc.text.magnifyingglass") }
                        .controlSize(.large).disabled(running)
                    Button("Edit…", action: onEdit).controlSize(.large)
                    Spacer()
                    Menu { Button("Delete Job", role: .destructive, action: onDelete) } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
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

                if let message = job.lastMessage {
                    Label(message, systemImage: job.lastState.symbol)
                        .font(.callout)
                        .foregroundStyle(job.lastState.color)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(job.lastState.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Run history").font(.title2.bold())
                    let records = store.history.filter { $0.jobID == job.id }.prefix(12)
                    if records.isEmpty {
                        Text("No runs yet. Preview the job to verify what will change.")
                            .foregroundStyle(.secondary).padding(.vertical, 18)
                    } else {
                        ForEach(records) { record in
                            RunRecordRow(record: record).contentShape(Rectangle()).onTapGesture { selectedRecord = record }
                            Divider()
                        }
                    }
                }
            }
            .padding(32)
        }
        .sheet(item: $selectedRecord) { LogView(record: $0) }
    }

    private var scheduleDetail: String {
        if job.schedule.kind == .realtime {
            if !job.enabled { return "Watcher paused" }
            return store.isWatching(job)
                ? "Watching the source; changes sync after a 2-second pause"
                : "Source unavailable; watcher will retry"
        }
        return store.nextRun(for: job).map {
            "Next: \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "Runs only when you start it"
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

struct RunRecordRow: View {
    let record: RunRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.state.symbol).foregroundStyle(record.state.color).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(record.jobName).fontWeight(.medium); if record.dryRun { Text("PREVIEW").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2).background(.blue.opacity(0.12), in: Capsule()).foregroundStyle(.blue) } }
                Text(record.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.endedAt, style: .relative).font(.caption)
                Text(record.duration.formattedDuration).font(.caption2).foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
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
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
            Divider()
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
