import Foundation

/// A single canon record kind. Matches the four kinds the protocol defines.
enum CanonKind: String, Sendable, CaseIterable, Equatable {
    case choice
    case constraint
    case convention
    case gotcha

    var label: String {
        switch self {
        case .choice:     return "Choice"
        case .constraint: return "Constraint"
        case .convention: return "Convention"
        case .gotcha:     return "Gotcha"
        }
    }
}

/// The `status:` field of a record. `superseded(by:)` carries the target title;
/// `nonCanonNoPointer` is a non-canon record with no `superseded by:` target;
/// `unknown` is an unparseable status string (drives the malformed check).
enum CanonStatus: Sendable, Equatable {
    case canon
    case superseded(by: String)
    case nonCanonNoPointer
    case unknown(String)

    var isCanon: Bool {
        if case .canon = self { return true }
        return false
    }
}

/// One parsed `## Title` record from a project's `.claude/canon.md`.
struct CanonRecord: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let kind: CanonKind?
    let dateString: String?
    let status: CanonStatus
    let body: String
    /// False when no `kind: … | date: … | status: …` metadata line followed the
    /// heading. Drives the CAN003 malformed check together with `kind`/`status`.
    let hasMetadataLine: Bool
    let rawStatusString: String?
}

/// Everything the Canon rail and lint need for one project, loaded off disk.
struct CanonData: Sendable, Equatable {
    let projectId: String?
    let records: [CanonRecord]
    /// `.claude/canon.md` exists on disk (records file, committable).
    let rawExists: Bool
    /// `.claude/rules/canon.md` exists on disk (the protocol rule).
    let protocolInstalled: Bool
    /// Version parsed from the installed protocol marker, nil if absent/unmarked.
    let protocolVersion: Int?
    /// nil when the project is not a git repo or the check could not run.
    let recordsGitignored: Bool?
    let dataPath: String?
    let rulePath: String?

    static let empty = CanonData(
        projectId: nil, records: [], rawExists: false, protocolInstalled: false,
        protocolVersion: nil, recordsGitignored: nil, dataPath: nil, rulePath: nil
    )
}

/// Outcome of a bulk enable/disable across many projects.
struct CanonBulkResult: Sendable, Equatable {
    var succeeded: Int = 0
    /// Projects whose real repo path could not be resolved on disk (skipped).
    var skipped: Int = 0
    /// Projects skipped because they are containers of other projects or repo
    /// subdirs — installing canon there would cascade or duplicate.
    var skippedIneligible: Int = 0
    var failed: Int = 0
    var failedNames: [String] = []
}

/// Per-machine Canon opt-in state, persisted as JSON in UserDefaults, mirroring
/// `NotificationConfig`. Opt-in is intentionally local (not disk-derived): a
/// project is "canon-enabled" for this user only once installed from this app.
struct CanonConfig: Codable, Sendable, Equatable {
    var optedInProjectIds: Set<String>

    static let `default` = CanonConfig(optedInProjectIds: [])
}

extension CanonConfig {
    private enum CodingKeys: String, CodingKey {
        case optedInProjectIds
    }

    // Forward-compatible: a missing set decodes to empty rather than throwing,
    // so adding fields later never resets a saved blob.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        optedInProjectIds = try c.decodeIfPresent(Set<String>.self, forKey: .optedInProjectIds) ?? []
    }
}

/// The artifacts Claudoscope installs into a project's `.claude/`. Shipped as
/// source constants (single source of truth) rather than bundle resources: the
/// files are inert markdown, so this works identically under swift run,
/// xcodebuild, and tests with no Bundle.main / SPM resource split to manage.
///
/// When the protocol text changes, bump BOTH `protocolVersion` and the marker
/// on the first line of `ruleFileText`.
enum CanonArtifacts {
    static let protocolVersion = 1

    static let ruleRelativePath = "rules/canon.md"
    static let dataRelativePath = "canon.md"

    static let ruleFileText = """
<!-- claudoscope-canon: v1 -->
# Project Canon

This repository keeps a canon at `.claude/canon.md`: the settled engineering
decisions that define how and why the code is the way it is. Choices between real
alternatives, constraints, conventions, and hard-won gotchas that are not
recoverable from the code itself. Unlike your per-machine memory, the canon
travels with the repo and is shared by everyone (and every agent) working on it.

## Record format

One `## <Title>` section per record, appended at the end, with a metadata line and
a short body (1-4 sentences, always including the why):

    ## Streaming parser keeps one record type across decode modes
    kind: constraint | date: 2026-07-15 | status: canon
    Lite and full decode share a single raw record type that branches internally.
    Because: the two-type version drifted once and caused silent billing gaps.

- `kind` is one of: `choice`, `constraint`, `convention`, `gotcha`
- `status` is `canon` or `non-canon, superseded by: <newer record title>`

## Reading protocol

1. Before planning, refactoring, reviewing, or answering "why is it like this" or
   "should we" questions: search the canon for terms from the task (subsystem
   names, file names, feature names). If the file is under ~150 lines, read it
   whole. Ignore non-canon records except as history.
2. Records reflect the moment they were written. Verify against the current code
   before relying on one. When code and canon disagree, the code is the truth and
   the record is a candidate for retirement.
3. If the user's request contradicts a canon record, stop and say so, naming the
   record. Let the user decide: follow the canon, or retire the record.
4. When a record shapes your plan, edit, or answer, cite its title.
5. If `.claude/canon.md` does not exist, proceed normally. The canon is opt-in
   per repository.

## Writing protocol

6. When a session settles something that will matter in FUTURE sessions (a choice
   between real alternatives, a new constraint, a non-obvious lesson), offer to
   add it to the canon. Append only after the user agrees. The user can also ask
   directly: "make this canon."
7. Not canon material: task-level choices, TODOs, status updates, anything already
   covered by CLAUDE.md, or anything derivable from the code or git history.
8. Never rewrite or delete existing records. To change one, append a new record
   and flip the old one's status to `non-canon, superseded by: <new title>`.
   History stays intact.

"""

    static let seedFileText = """
# Canon

Settled engineering decisions for this repository. The protocol lives in
`.claude/rules/canon.md`. Append new records at the end; supersede, never
rewrite. Managed with Claudoscope, safe to edit by hand.

"""
}
