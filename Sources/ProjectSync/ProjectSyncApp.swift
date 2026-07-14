import AppKit
import SwiftUI

@main
struct ProjectSyncApp: App {
    @StateObject private var store: JobStore
    @StateObject private var updates: UpdateManager

    init() {
        SyncStartNotifier.shared.start()
        _store = StateObject(wrappedValue: JobStore())
        _updates = StateObject(wrappedValue: UpdateManager())
    }

    var body: some Scene {
        WindowGroup("Project Sync") {
            ContentView()
                .environmentObject(store)
                .environmentObject(updates)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(updates)
        } label: {
            Label(
                "Project Sync",
                systemImage: (store.activeCount > 0 || !store.queuedJobIDs.isEmpty)
                    ? "arrow.triangle.2.circlepath"
                    : "point.3.connected.trianglepath.dotted"
            )
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updates)
                .frame(width: 440)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var updates: UpdateManager

    var body: some View {
        if store.jobs.isEmpty {
            Text("No sync jobs yet")
        } else {
            ForEach(store.jobs) { job in
                Button {
                    isBusy(job) ? store.cancel(job.id) : store.run(job.id)
                } label: {
                    Label(
                        menuTitle(for: job),
                        systemImage: menuSymbol(for: job)
                    )
                }
                .disabled(!job.enabled && !isBusy(job))
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
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Project Sync") { NSApp.terminate(nil) }
    }

    private func isBusy(_ job: SyncJob) -> Bool {
        store.runningJobIDs.contains(job.id) ||
            store.verifyingJobIDs.contains(job.id) ||
            store.queuedJobIDs.contains(job.id)
    }

    private func menuTitle(for job: SyncJob) -> String {
        if store.queuedJobIDs.contains(job.id) { return "Remove \(job.name) from Queue" }
        if store.verifyingJobIDs.contains(job.id) { return "Stop Verifying \(job.name)" }
        if store.runningJobIDs.contains(job.id) { return "Stop \(job.name)" }
        return "Run \(job.name)"
    }

    private func menuSymbol(for job: SyncJob) -> String {
        if store.queuedJobIDs.contains(job.id) { return "hourglass" }
        if store.runningJobIDs.contains(job.id) || store.verifyingJobIDs.contains(job.id) {
            return "stop.fill"
        }
        return job.lastState.symbol
    }
}
