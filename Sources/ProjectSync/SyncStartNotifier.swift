import AppKit
import SwiftUI

extension Notification.Name {
    static let projectSyncDidStart = Notification.Name("ProjectSync.syncDidStart")
}

@MainActor
final class SyncStartNotifier: NSObject {
    static let shared = SyncStartNotifier()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var isListening = false

    func start() {
        guard !isListening else { return }
        isListening = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(syncDidStart(_:)),
            name: .projectSyncDidStart,
            object: nil
        )
    }

    @objc private func syncDidStart(_ notification: Notification) {
        guard let jobName = notification.userInfo?["jobName"] as? String else { return }
        let dryRun = notification.userInfo?["dryRun"] as? Bool ?? false
        show(jobName: jobName, dryRun: dryRun)
    }

    private func show(jobName: String, dryRun: Bool) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let size = NSSize(width: 350, height: 68)
        let toast = SyncStartToast(jobName: jobName, dryRun: dryRun)
        let hostingView = NSHostingView(rootView: toast)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let target = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 12
        )
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y + 14))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(target)
        }

        dismissTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled, let self, let panel, self.panel === panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                panel.animator().setFrameOrigin(NSPoint(x: target.x, y: target.y + 8))
            }
            guard !Task.isCancelled, self.panel === panel else { return }
            panel.orderOut(nil)
            self.panel = nil
        }
    }
}

private struct SyncStartToast: View {
    let jobName: String
    let dryRun: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: dryRun ? "doc.text.magnifyingglass" : "arrow.triangle.2.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(dryRun ? "Preview started" : "Sync started")
                    .font(.headline)
                Text(jobName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 350, height: 68)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.7))
        }
    }
}
