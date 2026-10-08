import Foundation

/// Builds the `claude --resume` invocation for a transcript. Pure helpers; the
/// terminal side lives in `TerminalFocuser.run`.
enum SessionResumer {

    /// Rejects anything that is not a plain session id, as defense in depth
    /// before the id reaches a shell line.
    static func isValidSessionId(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    static func command(forSessionId id: String) -> String {
        "claude --resume \(id)"
    }

    /// First non-nil `cwd` across the records (a full-mode field). Correct for
    /// worktree sessions, whose project id decodes to the main checkout.
    static func workingDirectory(from session: ParsedSession) -> String? {
        session.records.lazy.compactMap(\.cwd).first { !$0.isEmpty }
    }
}
