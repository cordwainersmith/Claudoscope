import Foundation

enum CanonInstallError: Error, CustomStringConvertible {
    case io(String)

    var description: String {
        switch self {
        case .io(let detail): return "Filesystem error: \(detail)"
        }
    }
}

struct CanonInstallResult: Sendable {
    let installedAt: Date
    /// Backup of a pre-existing `rules/canon.md` that was replaced, if any.
    let backupPath: URL?
    /// True when `canon.md` was seeded (did not exist before).
    let seededDataFile: Bool
}

/// Installs and removes the Canon artifacts inside a project's `.claude/`.
///
/// Genuinely new territory: this is the only installer that writes into a repo
/// working tree rather than `~/.claude/`. It takes the artifact text as
/// parameters (the app passes `CanonArtifacts`) so its file-writing logic is
/// testable without any bundle dependency. No FSEvents install-gate is needed —
/// the watcher only observes `~/.claude/`, never a project repo.
actor CanonInstaller {

    private let fm = FileManager.default

    /// Install the protocol rule (always) and seed the records file (only if
    /// absent — never clobbers existing records). A pre-existing, differing
    /// `rules/canon.md` is backed up before replacement.
    func install(into claudeDir: URL, ruleText: String, seedText: String) throws -> CanonInstallResult {
        let installedAt = Date()

        let rulesDir = claudeDir.appendingPathComponent("rules")
        try createDirectory(rulesDir)

        let ruleURL = claudeDir.appendingPathComponent(CanonArtifacts.ruleRelativePath)
        var backupPath: URL?
        if fm.fileExists(atPath: ruleURL.path) {
            let existing = (try? String(contentsOf: ruleURL, encoding: .utf8)) ?? ""
            if existing != ruleText {
                backupPath = try backupExisting(ruleURL, forProjectClaudeDir: claudeDir)
            }
        }
        try atomicWrite(text: ruleText, to: ruleURL)

        let dataURL = claudeDir.appendingPathComponent(CanonArtifacts.dataRelativePath)
        var seeded = false
        if !fm.fileExists(atPath: dataURL.path) {
            try atomicWrite(text: seedText, to: dataURL)
            seeded = true
        }

        return CanonInstallResult(installedAt: installedAt, backupPath: backupPath, seededDataFile: seeded)
    }

    /// Remove the installed protocol rule. The records file (`canon.md`) is
    /// intentionally preserved — it is the user's data, committed to their repo.
    func uninstall(from claudeDir: URL) throws {
        let ruleURL = claudeDir.appendingPathComponent(CanonArtifacts.ruleRelativePath)
        if fm.fileExists(atPath: ruleURL.path) {
            do {
                try fm.removeItem(at: ruleURL)
            } catch {
                throw CanonInstallError.io("failed to remove \(ruleURL.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Internal

    private func createDirectory(_ url: URL) throws {
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CanonInstallError.io("failed to create \(url.path): \(error.localizedDescription)")
        }
    }

    /// Copy a pre-existing rule file into a global, timestamped backup outside
    /// the repo (so we never add backup noise to the user's working tree).
    private func backupExisting(_ ruleURL: URL, forProjectClaudeDir claudeDir: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())

        let projectKey = claudeDir.path
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let backupDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".claudoscope-canon-backups")
            .appendingPathComponent(projectKey)
            .appendingPathComponent(stamp)
        try createDirectory(backupDir)

        let dst = backupDir.appendingPathComponent("canon.md")
        do {
            try fm.copyItem(at: ruleURL, to: dst)
        } catch {
            throw CanonInstallError.io("failed to back up \(ruleURL.path): \(error.localizedDescription)")
        }
        return dst
    }

    /// Stage to a sibling temp file then atomically replace/move into place, so
    /// a reader never observes a half-written file.
    private func atomicWrite(text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw CanonInstallError.io("UTF-8 encoding failed for \(url.lastPathComponent)")
        }
        try createDirectory(url.deletingLastPathComponent())

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: [.atomic])
        } catch {
            throw CanonInstallError.io("failed to stage \(tmp.path): \(error.localizedDescription)")
        }

        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } catch {
                try? fm.removeItem(at: tmp)
                throw CanonInstallError.io("failed to replace \(url.path): \(error.localizedDescription)")
            }
        } else {
            do {
                try fm.moveItem(at: tmp, to: url)
            } catch {
                try? fm.removeItem(at: tmp)
                throw CanonInstallError.io("failed to write \(url.path): \(error.localizedDescription)")
            }
        }
    }
}
