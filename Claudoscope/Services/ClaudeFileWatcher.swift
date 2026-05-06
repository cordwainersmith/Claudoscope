import Foundation
import Combine

enum FileChange: Sendable {
    case sessionUpdated(URL)
    case sessionCreated(URL)
    case configChanged(URL)
    case mustRescan
}

/// Watches ~/.claude/projects/ for file changes using FSEvents.
/// Port of server/services/file-watcher.ts
final class ClaudeFileWatcher: @unchecked Sendable {
    private let claudeDir: URL
    private var stream: FSEventStreamRef?
    private let subject = PassthroughSubject<FileChange, Never>()
    private var debounceTimers: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "com.claudoscope.filewatcher")

    /// Install gate. When true, configChanged events are suppressed at the
    /// source so subscribers (lint, config reload) don't fire against a
    /// partially-written settings.json or CLAUDE.md while HardeningInstaller
    /// is mid-mutation. Lock-protected because the FSEvents callback runs off
    /// the main thread.
    private let gateLock = NSLock()
    private var _installInProgress: Bool = false
    func setInstallInProgress(_ value: Bool) {
        gateLock.lock()
        _installInProgress = value
        gateLock.unlock()
    }
    private var installInProgressLocked: Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        return _installInProgress
    }

    /// Weak-reference box passed to FSEvents callback to avoid use-after-free.
    /// The stored property keeps it alive; the callback checks watcher != nil.
    private final class StreamBox {
        weak var watcher: ClaudeFileWatcher?
        init(_ watcher: ClaudeFileWatcher) { self.watcher = watcher }
    }
    private var streamBox: StreamBox?

    private static let debounceMS: Int = 300

    var changes: AnyPublisher<FileChange, Never> {
        subject.eraseToAnyPublisher()
    }

    init(claudeDir: URL) {
        self.claudeDir = claudeDir
    }

    @discardableResult
    func start() -> Bool {
        // Watch the whole ~/.claude tree so we catch settings.json edits at the
        // root and plugin manifest changes under plugins/cache/, not just session
        // .jsonl files under projects/. The handleFileEvent filters narrow it back
        // down to the file shapes we care about.
        let watchRoot = claudeDir.path

        let box = StreamBox(self)
        self.streamBox = box

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(box).toOpaque()

        let paths = [watchRoot] as CFArray
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

                    // Handle event overflow: OS dropped events, full rescan needed
                    let mustRescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                        | UInt32(kFSEventStreamEventFlagKernelDropped)
                        | UInt32(kFSEventStreamEventFlagUserDropped)
                    if flags & mustRescanFlags != 0 {
                        watcher.subject.send(.mustRescan)
                        continue
                    }

                    // Skip directory events
                    if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { continue }

                    watcher.handleFileEvent(path: path, flags: flags)
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // latency in seconds
            flags
        ) else {
            NSLog("[ClaudeFileWatcher] FSEventStreamCreate returned nil for %@", watchRoot)
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
        // Stream is invalidated above, which drains pending callbacks; only now
        // is it safe to release the StreamBox the FSEvents context points at.
        streamBox = nil
        queue.async { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            for item in self.debounceTimers.values { item.cancel() }
            self.debounceTimers.removeAll()
        }
    }

    private func handleFileEvent(path: String, flags: UInt32) {
        let url = URL(fileURLWithPath: path)

        let isCreated = flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
        let isModified = flags & UInt32(kFSEventStreamEventFlagItemModified) != 0
        // Editor-style atomic saves swap files in via rename, so the .jsonl
        // surface event is ItemRenamed (sometimes paired with ItemInodeMetaMod).
        let isRenamed = flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        let isInodeMeta = flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0

        // Session .jsonl files only live under ~/.claude/projects/. Now that the
        // watch root is the whole ~/.claude/ tree, gate on the path component to
        // ignore unrelated .jsonl files (e.g. ~/.claude/history.jsonl).
        if path.hasSuffix(".jsonl") && path.contains("/projects/") {
            guard isCreated || isModified || isRenamed || isInodeMeta else { return }
            debounceEmit(key: path) {
                if isCreated {
                    return .sessionCreated(url)
                } else {
                    return .sessionUpdated(url)
                }
            }
        } else if path.hasSuffix("settings.json") ||
                  path.hasSuffix("settings.local.json") ||
                  path.hasSuffix("mcp.json") ||
                  path.hasSuffix(".mcp.json") ||
                  path.hasSuffix("plugin.json") ||
                  path.hasSuffix("hooks.json") ||
                  path.contains("/commands/") ||
                  path.contains("/skills/") ||
                  path.contains("/themes/") {
            guard isCreated || isModified else { return }
            // Skip config events while HardeningInstaller is mid-write.
            // Otherwise the debounced lint pipeline races a half-written
            // settings.json or CLAUDE.md and produces spurious results.
            if installInProgressLocked { return }
            debounceEmit(key: path) {
                return .configChanged(url)
            }
        }
    }

    private func debounceEmit(key: String, event: @escaping () -> FileChange) {
        dispatchPrecondition(condition: .onQueue(queue))
        debounceTimers[key]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.debounceTimers.removeValue(forKey: key)
            self.subject.send(event())
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
