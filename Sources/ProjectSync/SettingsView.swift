import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var updates: UpdateManager
    @State private var launchAtLogin = false
    @State private var errorMessage: String?
    @State private var confirmingClearHistory = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Project Sync at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        do {
                            try store.setLaunchAtLogin(value)
                            launchAtLogin = store.launchesAtLogin
                        } catch {
                            errorMessage = error.localizedDescription
                            launchAtLogin = store.launchesAtLogin
                        }
                    }
                ))
                Text("Keep the app running so scheduled jobs can start automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sync Behavior") {
                Picker("Maximum simultaneous jobs", selection: Binding(
                    get: { store.maximumConcurrentRuns },
                    set: { store.setMaximumConcurrentRuns($0) }
                )) {
                    ForEach(JobStore.concurrencyOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                Picker("Retry unavailable destinations", selection: Binding(
                    get: { store.retryLimit },
                    set: { store.setRetryLimit($0) }
                )) {
                    ForEach(JobStore.retryLimitOptions, id: \.self) { count in
                        Text(count == 0 ? "Never" : "\(count) time\(count == 1 ? "" : "s")").tag(count)
                    }
                }
                Picker("Retry backoff starts at", selection: Binding(
                    get: { store.retryBaseDelaySeconds },
                    set: { store.setRetryBaseDelaySeconds($0) }
                )) {
                    ForEach(JobStore.retryDelayOptions, id: \.self) { seconds in
                        Text(retryDelayLabel(seconds)).tag(seconds)
                    }
                }
                .disabled(store.retryLimit == 0)
                Picker("Last-success reminder", selection: Binding(
                    get: { store.staleReminderDays },
                    set: { store.setStaleReminderDays($0) }
                )) {
                    ForEach(JobStore.staleReminderOptions, id: \.self) { days in
                        Text(days == 0 ? "Off" : "After \(days) day\(days == 1 ? "" : "s")").tag(days)
                    }
                }
                Text("Retries use a short backoff. Reminders flag enabled jobs that have not completed successfully within the selected period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            NotificationSettingsSection()
            Section("Data") {
                LabeledContent("Configuration") { Text(store.applicationSupportURL.path).font(.caption).textSelection(.enabled) }
                Button("Show Project Sync Data") { store.reveal(store.applicationSupportURL.path) }
                Button("Export Diagnostic Report…") { store.exportDiagnosticReport() }
            }
            Section("Run History") {
                Picker("Keep recent runs", selection: Binding(
                    get: { store.historyLimit },
                    set: { store.setHistoryLimit($0) }
                )) {
                    ForEach(JobStore.historyLimitOptions, id: \.self) { limit in
                        Text("\(limit) entries").tag(limit)
                    }
                }
                LabeledContent("Currently stored", value: "\(store.history.count) entries")
                Text("The limit applies across all jobs. Reducing it removes the oldest records and their saved log files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear All History…", role: .destructive) {
                    confirmingClearHistory = true
                }
                .disabled(store.history.isEmpty)
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.setAutomaticallyChecksForUpdates($0) }
                ))
                Toggle("Automatically download updates", isOn: Binding(
                    get: { updates.automaticallyDownloadsUpdates },
                    set: { updates.setAutomaticallyDownloadsUpdates($0) }
                ))
                .disabled(!updates.automaticallyChecksForUpdates)
                HStack {
                    Text(updates.versionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }
            Section("Transfer engine") {
                LabeledContent("Local and NAS", value: "macOS rsync")
                LabeledContent("Remote", value: "rsync over SSH")
                Text("Project Sync never sends telemetry or file metadata to a cloud service.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 10)
        .onAppear { launchAtLogin = store.launchesAtLogin }
        .alert("Could Not Change Login Setting", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .alert("Clear All Run History?", isPresented: $confirmingClearHistory) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { store.clearHistory() }
        } message: {
            Text("This permanently removes all run records and their saved log files. Sync jobs and files are not affected.")
        }
    }

    private func retryDelayLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minute\(seconds == 60 ? "" : "s")"
    }
}

private struct NotificationSettingsSection: View {
    @ObservedObject private var notifications = SystemNotificationManager.shared

    var body: some View {
        Section("Notifications") {
            Toggle("When a sync starts", isOn: $notifications.notifyOnStart)
            Toggle("When a sync succeeds", isOn: $notifications.notifyOnSuccess)
            Toggle("When a sync fails", isOn: $notifications.notifyOnFailure)
            Toggle("Destination unavailable or retry scheduled", isOn: $notifications.notifyOnRetryOrWaiting)
            Toggle("Backup may be out of date", isOn: $notifications.notifyOnStaleBackup)
            Text("macOS may ask for permission the first time Project Sync needs to show an enabled notification.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
