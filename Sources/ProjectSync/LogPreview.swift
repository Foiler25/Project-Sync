import AppKit
import Foundation
import SwiftUI

struct LogPreview: Equatable {
    let text: String
    let isTruncated: Bool
    let loadedBytes: Int64
    let totalBytes: Int64
}

enum LogPreviewLoader {
    static let defaultLimit = 256 * 1_024

    static func load(path: String, fallback: String, limit: Int = defaultLimit) async -> LogPreview {
        guard !path.isEmpty else {
            return LogPreview(text: fallback, isTruncated: false, loadedBytes: Int64(fallback.utf8.count), totalBytes: Int64(fallback.utf8.count))
        }

        return await Task.detached(priority: .utility) {
            do {
                let url = URL(fileURLWithPath: path)
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                let total = Int64(values.fileSize ?? 0)
                let requested = max(1, limit)
                let truncated = total > Int64(requested)
                let data: Data

                if truncated {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(total - Int64(requested)))
                    data = try handle.read(upToCount: requested) ?? Data()
                } else {
                    data = try Data(contentsOf: url, options: .mappedIfSafe)
                }

                var text = String(decoding: data, as: UTF8.self)
                if truncated {
                    if let firstNewline = text.firstIndex(of: "\n") {
                        text = String(text[text.index(after: firstNewline)...])
                    }
                    text = "… Earlier output omitted from this preview. Use Reveal Full Log to inspect it. …\n\n" + text
                }

                return LogPreview(text: text, isTruncated: truncated, loadedBytes: Int64(data.count), totalBytes: total)
            } catch {
                let message = "Could not load this log.\n\n\(error.localizedDescription)\n\n\(fallback)"
                return LogPreview(text: message, isTruncated: false, loadedBytes: Int64(message.utf8.count), totalBytes: 0)
            }
        }.value
    }
}

struct ReadOnlyLogTextView: NSViewRepresentable {
    let text: String
    let followTail: Bool

    init(text: String, followTail: Bool = false) {
        self.text = text
        self.followTail = followTail
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        if followTail {
            textView.scrollToEndOfDocument(nil)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
    }
}
