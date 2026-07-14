import AppKit
import SwiftUI

enum ExclusionPresets {
    static let javascript = [
        "node_modules/", "bower_components/", ".npm/", ".pnpm-store/", ".yarn/cache/",
        ".next/", ".nuxt/", ".svelte-kit/", ".turbo/", ".parcel-cache/", "coverage/", "dist/"
    ]
    static let swiftAndXcode = [".build/", "DerivedData/", "xcuserdata/", "*.xcuserstate"]
    static let python = [
        "__pycache__/", "*.py[cod]", ".pytest_cache/", ".mypy_cache/", ".ruff_cache/",
        ".tox/", ".nox/", ".venv/", "venv/"
    ]
    static let rust = ["target/"]
    static let embeddedAndPlatformIO = [".pio/"]
    static let javaAndKotlin = [".gradle/", "build/", "out/"]
    static let dotNet = ["bin/", "obj/", ".vs/", "TestResults/"]
    static let nativeBuilds = ["CMakeFiles/", "CMakeCache.txt", "cmake-build-*/"]
    static let ruby = [".bundle/", "vendor/bundle/"]
    static let dartAndFlutter = [".dart_tool/", ".flutter-plugins", ".flutter-plugins-dependencies"]
    static let generalCaches = [".cache/", "tmp/", "temp/", "*.tmp"]
    static let macOSClutter = [".DS_Store", ".Trash/", ".Spotlight-V100/", ".fseventsd/"]
    static let localSecrets = [".env", ".env.local", ".env.*.local"]
    static let sourceControlMetadata = [".git/", ".hg/", ".svn/"]

    static let developerProjects = combined([
        javascript, swiftAndXcode, python, rust, embeddedAndPlatformIO, javaAndKotlin, dotNet,
        nativeBuilds, ruby, dartAndFlutter, generalCaches
    ])

    private static func combined(_ groups: [[String]]) -> [String] {
        var seen = Set<String>()
        return groups.flatMap { $0 }.filter { seen.insert($0).inserted }
    }
}

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
        saveIssue == nil
    }

    private var saveIssue: String? {
        if job.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give this sync a name to continue."
        }
        if !endpointIsComplete(job.source) || !endpointIsComplete(job.destination) {
            return "Complete both endpoints to continue."
        }
        if job.source == job.destination {
            return "Source and destination must be different."
        }
        if RsyncCommand.localPathsOverlap(job) {
            return "Source and destination folders cannot contain one another."
        }
        return nil
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

                    FormSection(title: "Notes", subtitle: "Optional context about what this sync protects or how it should be used.") {
                        TextEditor(text: optionalStringBinding(\.notes))
                            .frame(height: 72)
                            .scrollContentBackground(.hidden)
                            .padding(7)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
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
                        ScheduleEditor(schedule: $job.schedule, sourceKind: job.source.kind)
                        if job.source.kind == .remote {
                            Text("Real-time watching is available for Mac folders and mounted network drives. Remote SSH sources still support timed schedules.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    FormSection(title: "Options", subtitle: "Patterns use rsync exclude syntax, one per line.") {
                        Toggle("Preserve macOS extended attributes", isOn: $job.preserveExtendedAttributes)
                        Toggle("Verify after every successful sync", isOn: optionalBoolBinding(\.verifyAfterSync))
                        Toggle("Ignore permission differences during verification", isOn: Binding(
                            get: { !job.verifiesPermissions },
                            set: { job.verifyPermissions = !$0 }
                        ))
                        Text(job.verifiesPermissions
                             ? "File contents and POSIX permissions must both match."
                             : "File contents are always checksum-verified. Only permission differences are reported separately and ignored.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Toggle("Run when a source or destination volume mounts", isOn: optionalBoolBinding(\.runWhenVolumeMounts))
                            .disabled(!volumeMountRunAvailable)
                        if !volumeMountRunAvailable {
                            Text("Volume-mount runs require at least one Mac folder or mounted network drive endpoint.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Keep versioned copies of replaced and deleted files", isOn: optionalBoolBinding(\.archiveReplacedFiles))
                                .disabled(job.destination.kind == .remote)
                            if job.destination.kind == .remote {
                                Text("Versioned archives require a Mac folder or mounted network drive as the destination.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if job.keepsVersionedArchive {
                                Picker("Keep archive versions", selection: optionalIntBinding(\.archiveRetentionCount, defaultValue: 5)) {
                                    ForEach([1, 3, 5, 10, 20], id: \.self) { count in
                                        Text("\(count) version\(count == 1 ? "" : "s")").tag(count)
                                    }
                                }
                                .frame(maxWidth: 260, alignment: .leading)
                            }
                        }

                        HStack {
                            Text("Exclude patterns")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Menu("Add Preset") {
                                Button("Developer projects (Recommended)") {
                                    addExclusions(ExclusionPresets.developerProjects)
                                }
                                Button("macOS clutter") {
                                    addExclusions(ExclusionPresets.macOSClutter)
                                }
                                Divider()
                                Menu("Language-specific") {
                                    Button("JavaScript & TypeScript") { addExclusions(ExclusionPresets.javascript) }
                                    Button("Swift & Xcode") { addExclusions(ExclusionPresets.swiftAndXcode) }
                                    Button("Python") { addExclusions(ExclusionPresets.python) }
                                    Button("Rust") { addExclusions(ExclusionPresets.rust) }
                                    Button("Embedded & PlatformIO") { addExclusions(ExclusionPresets.embeddedAndPlatformIO) }
                                    Button("Java & Kotlin") { addExclusions(ExclusionPresets.javaAndKotlin) }
                                    Button(".NET") { addExclusions(ExclusionPresets.dotNet) }
                                    Button("C & C++") { addExclusions(ExclusionPresets.nativeBuilds) }
                                    Button("Ruby") { addExclusions(ExclusionPresets.ruby) }
                                    Button("Dart & Flutter") { addExclusions(ExclusionPresets.dartAndFlutter) }
                                }
                                Menu("Optional exclusions") {
                                    Button("General caches & temporary files") { addExclusions(ExclusionPresets.generalCaches) }
                                    Button("Local environment secrets") { addExclusions(ExclusionPresets.localSecrets) }
                                    Button("Source-control metadata") { addExclusions(ExclusionPresets.sourceControlMetadata) }
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }
                        Text("Developer projects combines common dependency, cache, and build-output patterns for all supported ecosystems. It keeps source files, lockfiles, .git history, and local environment files unless you add those optional presets.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                Text(saveIssue ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Sync" : "Save Changes") {
                    job.name = job.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    job.notes = job.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if job.notes?.isEmpty == true { job.notes = nil }
                    job.exclusions = normalizedExclusions(job.exclusions)
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

    private var volumeMountRunAvailable: Bool {
        job.source.kind != .remote || job.destination.kind != .remote
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<SyncJob, String?>) -> Binding<String> {
        Binding(
            get: { job[keyPath: keyPath] ?? "" },
            set: { job[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func optionalBoolBinding(_ keyPath: WritableKeyPath<SyncJob, Bool?>) -> Binding<Bool> {
        Binding(
            get: { job[keyPath: keyPath] ?? false },
            set: { job[keyPath: keyPath] = $0 }
        )
    }

    private func optionalIntBinding(_ keyPath: WritableKeyPath<SyncJob, Int?>, defaultValue: Int) -> Binding<Int> {
        Binding(
            get: { job[keyPath: keyPath] ?? defaultValue },
            set: { job[keyPath: keyPath] = $0 }
        )
    }

    private func addExclusions(_ patterns: [String]) {
        job.exclusions = normalizedExclusions(job.exclusions + patterns)
    }

    private func normalizedExclusions(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        return patterns.compactMap { pattern in
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
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
    let sourceKind: EndpointKind

    var body: some View {
        HStack {
            Picker("Frequency", selection: $schedule.kind) {
                ForEach(ScheduleKind.allCases) { kind in
                    Text(kind.rawValue)
                        .tag(kind)
                        .disabled(kind == .realtime && sourceKind == .remote)
                }
            }
            .frame(width: 235)

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
        .onChange(of: sourceKind) { _, newKind in
            if newKind == .remote && schedule.kind == .realtime {
                schedule.kind = .manual
            }
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
