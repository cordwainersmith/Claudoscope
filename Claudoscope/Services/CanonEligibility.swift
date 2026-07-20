import Foundation

/// Where a project directory sits relative to canon installation.
///
/// Canon writes a `.claude/rules/canon.md`, and Claude Code loads
/// `.claude/rules/*.md` hierarchically (cwd up to home). So a rule installed at an
/// ancestor directory reappears inside every descendant project as a duplicate.
/// This classification is what keeps a bulk enable from polluting nested projects.
enum CanonTargetKind: Sendable, Equatable {
    /// Install canon here: a git repo root, or a standalone non-git leaf folder.
    case installable(root: String)
    /// Skip: this directory contains other tracked project roots, so canon here
    /// would cascade into all of them. `nested` lists the offending roots.
    case container(nested: [String])
    /// Skip: this directory is inside a git repo; canon belongs at `root` (the
    /// repo toplevel), not this subdirectory.
    case foldedInto(root: String)
    /// The directory could not be resolved on disk.
    case directoryMissing
}

/// Pure, filesystem-injected logic for deciding where canon may be installed.
///
/// `fileExists` is a parameter (not a hardcoded `FileManager` call) so the rules
/// are unit-testable over synthetic path sets without touching the real disk.
/// Git is used only to identify a repo's root, never to exclude non-git projects:
/// standalone non-git folders remain installable.
enum CanonEligibility {

    /// Lexically normalized path (resolves `.`/`..`, strips trailing slash). Does
    /// not resolve symlinks — inputs all originate from the same decoder, so
    /// lexical normalization is enough to compare them.
    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// True when `path` is strictly below `ancestor`. The trailing "/" guard keeps
    /// `/a/projects` from matching `/a/projects-foo`.
    static func isStrictDescendant(_ path: String, of ancestor: String) -> Bool {
        let a = standardized(ancestor)
        let p = standardized(path)
        return p != a && p.hasPrefix(a + "/")
    }

    /// Nearest ancestor of `dir` (inclusive) that contains a `.git` entry, else nil.
    static func gitRepoRoot(for dir: String, fileExists: (String) -> Bool) -> String? {
        var cur = URL(fileURLWithPath: standardized(dir), isDirectory: true)
        while true {
            if fileExists(cur.appendingPathComponent(".git").path) {
                return cur.path
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { return nil }  // reached "/"
            cur = parent
        }
    }

    /// The directory canon should live in for `dir`: the enclosing git repo root
    /// if any, otherwise `dir` itself (a standalone non-git project).
    static func canonicalRoot(for dir: String, fileExists: (String) -> Bool) -> String {
        gitRepoRoot(for: dir, fileExists: fileExists) ?? standardized(dir)
    }

    /// Classify one project directory against the full set of tracked directories.
    static func classify(dir: String, allDirs: [String], fileExists: (String) -> Bool) -> CanonTargetKind {
        let d = standardized(dir)
        let root = canonicalRoot(for: d, fileExists: fileExists)

        // Inside a git repo but not at its root -> canon belongs at the root.
        if root != d { return .foldedInto(root: root) }

        // A root is a container when another project's canonical root nests under
        // it. A stray session-subdir of this same repo folds back to `root`, so it
        // is not strictly below `root` and never makes the repo look like a container.
        let nested = allDirs
            .map { standardized($0) }
            .filter { $0 != d }
            .map { canonicalRoot(for: $0, fileExists: fileExists) }
            .filter { isStrictDescendant($0, of: root) }

        if !nested.isEmpty {
            return .container(nested: Array(Set(nested)).sorted())
        }
        return .installable(root: root)
    }
}
