import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: JobStore
    @State private var launchAtLogin = false
    @State private var errorMessage: String?

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
            Section("Data") {
                LabeledContent("Configuration") { Text(store.applicationSupportURL.path).font(.caption).textSelection(.enabled) }
                Button("Show Project Sync Data") { store.reveal(store.applicationSupportURL.path) }
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
    }
}
