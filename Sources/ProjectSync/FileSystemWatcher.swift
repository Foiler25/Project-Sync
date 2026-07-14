import CoreServices
import Foundation

/// A recursive macOS file-system watcher backed by FSEvents.
final class FileSystemWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable () -> Void

        init(handler: @escaping @Sendable () -> Void) {
            self.handler = handler
        }
    }

    private let queue: DispatchQueue
    private let callbackBox: CallbackBox
    private var callbackPointer: UnsafeMutableRawPointer?
    private var stream: FSEventStreamRef?

    init(path: String, handler: @escaping @Sendable () -> Void) {
        queue = DispatchQueue(label: "com.projectsync.file-watcher.\(UUID().uuidString)")
        callbackBox = CallbackBox(handler: handler)

        let pointer = Unmanaged.passRetained(callbackBox).toOpaque()
        callbackPointer = pointer
        var context = FSEventStreamContext(
            version: 0,
            info: pointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        guard let stream else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        return FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil

            // Let any callback already submitted to the watcher queue finish before
            // releasing the retained callback context.
            queue.sync {}
        }
        if let callbackPointer {
            Unmanaged<CallbackBox>.fromOpaque(callbackPointer).release()
            self.callbackPointer = nil
        }
    }

    private static let eventCallback: FSEventStreamCallback = {
        _, context, eventCount, _, _, _ in
        guard eventCount > 0, let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        box.handler()
    }
}
