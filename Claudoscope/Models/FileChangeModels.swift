import Foundation

// MARK: - File Change Models
// Data for the session-detail Files tab: every file Claude edited or wrote in a
// session, reconstructed from `toolUseResult.structuredPatch` payloads in the
// JSONL (extracted by FileChangesService, not by SessionParser).
// Naming note: `ChangedFile`, not `FileChange` (that name is the file-watcher
// event enum) and not `FileChangeSummary` (the snapshot index in FileHistoryService).

enum FileEditKind: Sendable {
    case edit
    case writeCreate
    case writeUpdate
    case notebookEdit
}

/// One unified-diff hunk, verbatim from the CLI's structuredPatch (JS diff
/// format). `lines` keep their " " / "-" / "+" prefixes.
struct PatchHunk: Sendable, Hashable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]
}

/// One successful Edit/Write/NotebookEdit call.
struct FileEditEvent: Identifiable, Sendable {
    /// tool_use block id: stable, unique, and the dedup key for context-fork replays.
    let id: String
    let kind: FileEditKind
    /// uuid of the assistant record carrying the tool_use (in the file it was found in).
    let recordUuid: String?
    /// Scroll anchor in the VIEWED transcript: recordUuid for main-file events,
    /// the spawning Agent/Task call's assistant uuid for subagent events,
    /// nil when unresolvable (jump button disabled).
    let jumpTargetUuid: String?
    /// nil = main agent; else badge text (subagent_type or truncated file stem).
    let agentLabel: String?
    let timestamp: String?
    let hunks: [PatchHunk]
    let additions: Int
    let deletions: Int
    let replaceAll: Bool
    let userModified: Bool
    /// True when the diff was synthesized (NotebookEdit new_source shown as all-added).
    let isFallbackRendering: Bool
}

/// All changes to one file within a session (main agent + subagents merged).
struct ChangedFile: Identifiable, Sendable {
    var id: String { path }
    /// Absolute path from toolUseResult.filePath (input file_path as fallback).
    let path: String
    /// cwd-relativized when the path lives under the event record's cwd, else absolute.
    let displayPath: String
    let isNewFile: Bool
    /// Chronological.
    let events: [FileEditEvent]
    let additions: Int
    let deletions: Int
    /// SHA256 hex of the file content after the last change, when reconstructable.
    /// nil (for example a NotebookEdit last touch) renders no disk-state badge.
    let finalContentSHA256: String?
    let lastTimestamp: String?
}

struct FileChangeSet: Sendable {
    /// Composite key from FileChangesService.fileChangesLocator; the view trusts
    /// store.fileChangeSet only when this matches its own locator key.
    let sessionKey: String
    let files: [ChangedFile]
    let totalAdditions: Int
    let totalDeletions: Int
    let totalEvents: Int
}

enum FileDiskState: Sendable {
    case clean
    case modified
    case missing
    case unknown
}
