import AppKit
import SwiftUI

@main
struct ProjectSyncApp: App {
    @StateObject private var store = JobStore()

    var body: some Scene {
        WindowGroup("Project Sync") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
        } label: {
            Label("Project Sync", systemImage: store.activeCount > 0 ? "arrow.triangle.2.circlepath" : "point.3.connected.trianglepath.dotted")
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(width: 440)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var store: JobStore

    var body: some View {
        if store.jobs.isEmpty {
            Text("No sync jobs yet")
        } else {
            ForEach(store.jobs) { job in
                Button {
                    store.runningJobIDs.contains(job.id) ? store.cancel(job.id) : store.run(job.id)
                } label: {
                    Label(
                        store.runningJobIDs.contains(job.id) ? "Stop \(job.name)" : "Run \(job.name)",
                        systemImage: store.runningJobIDs.contains(job.id) ? "stop.fill" : job.lastState.symbol
                    )
                }
                .disabled(!job.enabled && !store.runningJobIDs.contains(job.id))
            }
            Divider()
            Button("Run All") { store.runAll() }
                .disabled(store.jobs.isEmpty)
        }
        Divider()
        Button("Open Project Sync") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Project Sync") { NSApp.terminate(nil) }
    }
}
