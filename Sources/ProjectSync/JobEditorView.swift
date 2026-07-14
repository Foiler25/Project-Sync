import AppKit
import SwiftUI

struct JobEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var job: SyncJob
    let isNew: Bool
    let onSave: (SyncJob) -> Void

    init(job: SyncJob, isNew: Bool, onSave: @escaping (SyncJob) -> Void) {
        _job = State(initialValue: job)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var canSave: Bool {
        !job.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        endpointIsComplete(job.source) && endpointIsComplete(job.destination) &&
        job.source != job.destination
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isNew ? "New Sync Job" : "Edit Sync Job").font(.title2.bold())
                    Text("A job always copies in one direction—from source to destination.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    FormSection(title: "Name", subtitle: "A short label shown in the menu bar and run history.") {
                        TextField("For example, Desktop to NAS", text: $job.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .top, spacing: 18) {
                        EndpointEditor(title: "SOURCE", endpoint: $job.source)
                        Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary).padding(.top, 96)
                        EndpointEditor(title: "DESTINATION", endpoint: $job.destination)
                    }

                    FormSection(title: "Transfer mode", subtitle: job.mode.detail) {
                        Picker("Transfer mode", selection: $job.mode) {
                            ForEach(TransferMode.allCases) { mode in
                                Label(mode.rawValue, systemImage: mode == .backup ? "archivebox" : "rectangle.2.swap").tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        if job.mode == .mirror {
                            Label("Files removed from the source will also be removed from the destination.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }

                    FormSection(title: "Schedule", subtitle: "Schedules run while Project Sync is open. Enable launch at login in Settings for unattended jobs.") {
                        ScheduleEditor(schedule: $job.schedule)
                    }

                    FormSection(title: "Options", subtitle: "Patterns use rsync exclude syntax, one per line.") {
                        Toggle("Preserve macOS extended attributes", isOn: $job.preserveExtendedAttributes)
                        TextEditor(text: Binding(
                            get: { job.exclusions.joined(separator: "\n") },
                            set: { job.exclusions = $0.components(separatedBy: .newlines) }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 90)
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Text(canSave ? "" : "Complete both endpoints to continue.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Sync" : "Save Changes") {
                    job.name = job.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    job.source.path = NSString(string: job.source.path).expandingTildeInPath
                    job.destination.path = NSString(string: job.destination.path).expandingTildeInPath
                    onSave(job)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 680, idealHeight: 760)
    }

    private func endpointIsComplete(_ endpoint: SyncEndpoint) -> Bool {
        !endpoint.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (endpoint.kind != .remote || !endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private struct FormSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

private struct EndpointEditor: View {
    let title: String
    @Binding var endpoint: SyncEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Picker("Location type", selection: $endpoint.kind) {
                ForEach(EndpointKind.allCases) { kind in Label(kind.rawValue, systemImage: kind.symbol).tag(kind) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if endpoint.kind == .remote {
                HStack {
                    TextField("Username", text: $endpoint.username)
                    Text("@").foregroundStyle(.secondary)
                    TextField("Host or IP", text: $endpoint.host)
                }
                HStack {
                    TextField("Remote folder, e.g. /volume1/Backup", text: $endpoint.path)
                    TextField("Port", value: $endpoint.port, format: .number)
                        .frame(width: 65)
                }
                Text("Uses your existing SSH keys; password prompts are not shown for scheduled runs.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField(endpoint.kind == .network ? "/Volumes/My NAS/Backup" : "/Users/me/Documents", text: $endpoint.path)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseFolder)
                }
                if endpoint.kind == .network {
                    Text("Mount the share in Finder first; it will usually appear under /Volumes.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .top)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(title.capitalized) Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !endpoint.path.isEmpty { panel.directoryURL = URL(fileURLWithPath: endpoint.path) }
        if panel.runModal() == .OK, let url = panel.url { endpoint.path = url.path }
    }
}

private struct ScheduleEditor: View {
    @Binding var schedule: JobSchedule

    var body: some View {
        HStack {
            Picker("Frequency", selection: $schedule.kind) {
                ForEach(ScheduleKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 150)

            if schedule.kind == .weekly {
                Picker("Day", selection: $schedule.weekday) {
                    ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index + 1)
                    }
                }
                .frame(width: 150)
            }

            if schedule.kind == .hourly {
                Text("at")
                Picker("Minute", selection: $schedule.minute) {
                    ForEach([0, 15, 30, 45], id: \.self) { Text(":\(String(format: "%02d", $0))").tag($0) }
                }
                .labelsHidden().frame(width: 80)
            } else if schedule.kind == .daily || schedule.kind == .weekly {
                DatePicker("at", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .frame(width: 160)
            }
            Spacer()
        }
    }

    private var timeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? Date()
        } set: { value in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
            schedule.hour = parts.hour ?? 2
            schedule.minute = parts.minute ?? 0
        }
    }
}
