import Foundation
import Combine

enum CoworkChange: Sendable {
    case directoryChanged
}

/// Watches ~/Library/Application Support/Claude/ for Cowork artifacts: the
/// discovery file (cowork-enabled-cli-ops.json) and the per-session JSON +
/// audit.jsonl pairs under local-agent-mode-sessions/{ownerId}/{projectId}/.
///
/// Mirrors ClaudeFileWatcher's StreamBox weak-reference pattern. Two teardown
/// invariants from the 0.6.1 history that must be preserved:
///   1. set streamBox.watcher = nil first so any in-flight callback short-circuits
///   2. invalidate the FSEvents stream BEFORE releasing the box, to drain pending callbacks
final class CoworkFileWatcher: @unchecked Sendable {
    private let supportDir: URL
    private var stream: FSEventStreamRef?
    private let subject = PassthroughSubject<CoworkChange, Never>()
    private var debounceTimers: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "com.claudoscope.coworkwatcher")

    private final class StreamBox {
        weak var watcher: CoworkFileWatcher?
        init(_ watcher: CoworkFileWatcher) { self.watcher = watcher }
    }
    private var streamBox: StreamBox?

    private static let debounceMS: Int = 300

    var changes: AnyPublisher<CoworkChange, Never> {
        subject.eraseToAnyPublisher()
    }

    init(supportDir: URL) {
        self.supportDir = supportDir
    }

    @discardableResult
    func start() -> Bool {
        guard FileManager.default.fileExists(atPath: supportDir.path) else {
            // Cowork (Claude desktop app) may not be installed. Not an error;
            // the rail will simply never appear.
            return false
        }

        let box = StreamBox(self)
        self.streamBox = box

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(box).toOpaque()

        let paths = [supportDir.path] as CFArray
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
                guard let watcher = box.watcher else { return }
                let paths = unsafeBitCast(eventPaths, to: NSArray.self)

                for i in 0..<numEvents {
                    guard let path = paths[i] as? String else { continue }
                    let flags = eventFlags[i]

                    let mustRescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                        | UInt32(kFSEventStreamEventFlagKernelDropped)
                        | UInt32(kFSEventStreamEventFlagUserDropped)
                    if flags & mustRescanFlags != 0 {
                        watcher.debounceEmit(key: "__rescan__")
                        continue
                    }

                    if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { continue }

                    watcher.handleFileEvent(path: path, flags: flags)
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            NSLog("[CoworkFileWatcher] FSEventStreamCreate returned nil for %@", supportDir.path)
            self.streamBox = nil
            return false
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        return true
    }

    func stop() {
        streamBox?.watcher = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        streamBox = nil
        queue.async { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            for item in self.debounceTimers.values { item.cancel() }
            self.debounceTimers.removeAll()
        }
    }

    private func handleFileEvent(path: String, flags: UInt32) {
        let isCreated = flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
        let isModified = flags & UInt32(kFSEventStreamEventFlagItemModified) != 0
        let isRenamed = flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        let isRemoved = flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
        let isInodeMeta = flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0
        guard isCreated || isModified || isRenamed || isRemoved || isInodeMeta else { return }

        if path.hasSuffix("/cowork-enabled-cli-ops.json") {
            debounceEmit(key: path)
            return
        }

        // Per-session metadata: .../local-agent-mode-sessions/{owner}/{project}/local_*.json
        if path.contains("/local-agent-mode-sessions/")
            && (path.range(of: #"/local_[^/]+\.json$"#, options: .regularExpression) != nil) {
            debounceEmit(key: path)
            return
        }

        // Per-session transcript: .../local-agent-mode-sessions/{owner}/{project}/local_*/audit.jsonl
        if path.contains("/local-agent-mode-sessions/") && path.hasSuffix("/audit.jsonl") {
            debounceEmit(key: path)
            return
        }
    }

    private func debounceEmit(key: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        debounceTimers[key]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.debounceTimers.removeValue(forKey: key)
            self.subject.send(.directoryChanged)
        }

        debounceTimers[key] = workItem
        queue.asyncAfter(
            deadline: .now() + .milliseconds(Self.debounceMS),
            execute: workItem
        )
    }

    deinit {
        stop()
    }
}
