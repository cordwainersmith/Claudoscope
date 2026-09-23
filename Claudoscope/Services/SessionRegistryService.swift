import Foundation

/// Reads Claude Code's live session registry (`~/.claude/sessions/<pid>.json`).
/// Read-only. Files are not reliably removed when a process exits, so an entry
/// counts only while its pid is alive. Only `<digits>.json` files are opened:
/// the `<pid>.<sha>.key` siblings hold per-process secrets.
actor SessionRegistryService {
    private let sessionsDir: URL

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.sessionsDir = claudeDir.appendingPathComponent("sessions")
    }

    func loadEntries() -> [RegistryEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return [] }
        let decoder = JSONDecoder()
        var entries: [RegistryEntry] = []
        for name in names where Self.isRegistryFileName(name) {
            let url = sessionsDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(RegistryEntry.self, from: data) else { continue }
            guard Self.isAlive(pid: entry.pid) else { continue }
            entries.append(entry)
        }
        return entries.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    }

    /// `<digits>.json` only. Rejects `<pid>.<sha>.key` and anything else.
    nonisolated static func isRegistryFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        return !stem.isEmpty && stem.allSatisfy(\.isNumber)
    }

    /// Signal 0 probes existence without delivering anything. EPERM means the
    /// process exists but belongs to another user, which still counts as alive.
    nonisolated static func isAlive(pid: Int) -> Bool {
        guard pid > 0, let p = pid_t(exactly: pid) else { return false }
        if kill(p, 0) == 0 { return true }
        return errno == EPERM
    }
}
