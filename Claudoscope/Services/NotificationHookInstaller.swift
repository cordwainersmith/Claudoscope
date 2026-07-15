import Foundation

enum NotificationHookInstallError: Error, CustomStringConvertible {
    case malformedSettingsJson
    case io(String)

    var description: String {
        switch self {
        case .malformedSettingsJson:
            return "~/.claude/settings.json is not valid JSON or has the wrong shape; aborting to preserve user data."
        case .io(let detail):
            return "Filesystem error: \(detail)"
        }
    }
}

/// Installs and removes the Claude Code `Notification` hook that bridges session
/// lifecycle events into Claudoscope's spool directory. Mirrors
/// `HardeningInstaller`'s atomic settings IO + backup + marker patterns, but is
/// self-contained: the hook script is generated inline (no `Bundle` dependency),
/// so the happy path is unit-testable under `swift test`.
///
/// On install it detects and strips the user's hand-rolled `session-notify.sh`
/// hook (recording it in the marker) so there are no double banners; uninstall
/// restores it (falling back to the settings.json backup if the marker is gone).
actor NotificationHookInstaller {

    private let claudeDir: URL
    private let setInstallInProgress: @Sendable @MainActor (Bool) -> Void

    static let hookScriptName = "claudoscope-notify.sh"
    static let sessionNotifyScriptName = "session-notify.sh"
    static let spoolDirName = ".claudoscope-events"
    static let markerFileName = ".claudoscope-notify-installed"
    static let backupPrefix = ".claudoscope-notify-backup-"

    init(claudeDir: URL, setInstallInProgress: @escaping @Sendable @MainActor (Bool) -> Void) {
        self.claudeDir = claudeDir
        self.setInstallInProgress = setInstallInProgress
    }

    // MARK: - Paths

    private var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }
    private var hooksDir: URL { claudeDir.appendingPathComponent("hooks") }
    private var hookScriptURL: URL { hooksDir.appendingPathComponent(Self.hookScriptName) }
    var spoolDir: URL { claudeDir.appendingPathComponent(Self.spoolDirName) }
    private var markerURL: URL { claudeDir.appendingPathComponent(Self.markerFileName) }

    // MARK: - Public API

    /// True when any hook entry in settings.json points at `session-notify.sh`.
    func detectExistingSessionNotify() -> Bool {
        guard let settings = try? readSettingsJSON(at: settingsURL) else { return false }
        return !Self.collectHookTriples(basename: Self.sessionNotifyScriptName, in: settings).isEmpty
    }

    /// Install the Notification hook. Backs up settings.json, strips any
    /// `session-notify.sh` registrations (recording them), writes the inline
    /// hook script, and registers it under `Notification`. Wrapped in the
    /// install gate so the watcher's config pipeline doesn't fire mid-write.
    func install() async throws {
        await gate(true)
        defer { Task { await gate(false) } }

        let backupDir = try createBackup()
        var settings = try readSettingsJSON(at: settingsURL)   // throws malformed BEFORE side effects

        try ensureSpoolDir()
        try writeHookScript()

        let removed = Self.stripHooks(basename: Self.sessionNotifyScriptName, from: &settings)
        Self.addCommandHook(event: "Notification", matcher: "", command: hookScriptURL.path, into: &settings)
        Self.addCommandHook(event: "Stop", matcher: "", command: hookScriptURL.path, into: &settings)
        try atomicWriteJSON(dict: settings, to: settingsURL)

        try writeMarkerIfAbsent(removedSessionNotify: removed, backupPath: backupDir)
    }

    /// Remove our hook and restore the user's `session-notify.sh` registrations
    /// from the marker, falling back to the settings.json backup if the marker
    /// is missing or corrupt. Deletes our script + marker.
    func uninstall() async throws {
        await gate(true)
        defer { Task { await gate(false) } }

        // Only touch settings.json if it exists; uninstalling on a system with no
        // settings file must not create an empty one.
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            var settings = (try? readSettingsJSON(at: settingsURL)) ?? [:]
            _ = Self.stripHooks(basename: Self.hookScriptName, from: &settings)

            let removed = markerRemovedEntries()
            if !removed.isEmpty {
                restore(removed, into: &settings)
            } else if let backup = latestBackupSettings() {
                restore(Self.collectHookTriples(basename: Self.sessionNotifyScriptName, in: backup), into: &settings)
            }

            try? atomicWriteJSON(dict: settings, to: settingsURL)
        }
        try? FileManager.default.removeItem(at: hookScriptURL)
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Idempotently ensure both hooks (Notification + Stop) and the bridge script
    /// are present when the feature is enabled. Called on launch so an app update
    /// that adds the Stop hook takes effect without a manual toggle. Only adds
    /// what is missing (no backup, no strip) and writes settings.json only if
    /// something changed.
    func ensureHooks() async {
        await gate(true)
        defer { Task { await gate(false) } }

        if !FileManager.default.fileExists(atPath: hookScriptURL.path) {
            try? ensureSpoolDir()
            try? writeHookScript()
        }
        guard var settings = try? readSettingsJSON(at: settingsURL) else { return }
        let events = Set(Self.collectHookTriples(basename: Self.hookScriptName, in: settings)
            .compactMap { $0["event"] })
        var changed = false
        if !events.contains("Notification") {
            Self.addCommandHook(event: "Notification", matcher: "", command: hookScriptURL.path, into: &settings)
            changed = true
        }
        if !events.contains("Stop") {
            Self.addCommandHook(event: "Stop", matcher: "", command: hookScriptURL.path, into: &settings)
            changed = true
        }
        if changed { try? atomicWriteJSON(dict: settings, to: settingsURL) }
    }

    // MARK: - Install gate

    private func gate(_ value: Bool) async {
        let cb = setInstallInProgress
        await MainActor.run { cb(value) }
    }

    // MARK: - Hook script

    /// Dumb, jq-free bridge: forwards the hook JSON (stdin) to the spool as a
    /// single atomically-renamed file. Permissive so it can never break a
    /// session; self-heals the spool dir with `mkdir -p`.
    static func hookScript(spoolDirPath: String) -> String {
        """
        #!/usr/bin/env bash
        # Claudoscope notification bridge (managed by Claudoscope; do not edit).
        # Forwards the Claude Code Notification hook payload to the app spool.
        dir="\(spoolDirPath)"
        mkdir -p "$dir" 2>/dev/null
        f="$dir/$(date +%s)-$$-$RANDOM"
        cat > "$f.json.tmp" 2>/dev/null
        mv -f "$f.json.tmp" "$f.json" 2>/dev/null
        exit 0
        """
    }

    private func ensureSpoolDir() throws {
        try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
    }

    private func writeHookScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let script = Self.hookScript(spoolDirPath: spoolDir.path)
        guard let data = script.data(using: .utf8) else {
            throw NotificationHookInstallError.io("failed to encode hook script")
        }
        try atomicWrite(data: data, to: hookScriptURL)
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: hookScriptURL.path)
    }

    // MARK: - Hooks-object manipulation (static, pure, testable)

    /// Every `[event, matcher, command]` triple in settings.json whose command
    /// basename matches.
    static func collectHookTriples(basename: String, in settings: [String: Any]) -> [[String: String]] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var out: [[String: String]] = []
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                let matcher = entry["matcher"] as? String ?? ""
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                for h in inner {
                    let cmd = h["command"] as? String ?? ""
                    if (cmd as NSString).lastPathComponent == basename {
                        out.append(["event": event, "matcher": matcher, "command": cmd])
                    }
                }
            }
        }
        return out
    }

    /// Remove inner hooks whose command basename matches; drop entries that
    /// become empty as a result, but preserve entries that were already empty.
    /// Returns the removed `[event, matcher, command]` triples.
    @discardableResult
    static func stripHooks(basename: String, from settings: inout [String: Any]) -> [[String: String]] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return [] }
        var removed: [[String: String]] = []
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            var rebuilt: [[String: Any]] = []
            for entry in entries {
                let matcher = entry["matcher"] as? String ?? ""
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                var kept: [[String: Any]] = []
                for h in inner {
                    let cmd = h["command"] as? String ?? ""
                    if (cmd as NSString).lastPathComponent == basename {
                        removed.append(["event": event, "matcher": matcher, "command": cmd])
                    } else {
                        kept.append(h)
                    }
                }
                if !kept.isEmpty {
                    var newEntry = entry
                    newEntry["hooks"] = kept
                    rebuilt.append(newEntry)
                } else if inner.isEmpty {
                    rebuilt.append(entry)   // preserve a pre-existing empty entry
                }
                // else: entry emptied by our strip -> drop it
            }
            hooks[event] = rebuilt
        }
        settings["hooks"] = hooks
        return removed
    }

    /// Add a single-command hook under `event`, deduped by (matcher, command).
    static func addCommandHook(event: String, matcher: String, command: String, into settings: inout [String: Any]) {
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var entries = (hooks[event] as? [[String: Any]]) ?? []
        for entry in entries {
            let m = entry["matcher"] as? String ?? ""
            let inner = (entry["hooks"] as? [[String: Any]]) ?? []
            if m == matcher, inner.contains(where: { ($0["command"] as? String) == command }) {
                return
            }
        }
        entries.append([
            "matcher": matcher,
            "hooks": [["type": "command", "command": command]],
        ])
        hooks[event] = entries
        settings["hooks"] = hooks
    }

    private func restore(_ triples: [[String: String]], into settings: inout [String: Any]) {
        for t in triples {
            guard let event = t["event"], let command = t["command"] else { continue }
            Self.addCommandHook(event: event, matcher: t["matcher"] ?? "", command: command, into: &settings)
        }
    }

    // MARK: - Marker

    private func writeMarkerIfAbsent(removedSessionNotify: [[String: String]], backupPath: URL) throws {
        var effectiveRemoved = removedSessionNotify
        var effectiveInstalledAt = Self.isoNow()
        if let existing = try? readMarker() {
            // First-install-wins: never clobber the original record.
            if existing["removedSessionNotify"] != nil {
                effectiveRemoved = markerRemovedEntries(from: existing)
            }
            if let prior = existing["installedAt"] as? String { effectiveInstalledAt = prior }
        }
        let marker: [String: Any] = [
            "version": "1",
            "installedAt": effectiveInstalledAt,
            "backupPath": backupPath.path,
            "removedSessionNotify": effectiveRemoved,
        ]
        try atomicWriteJSON(dict: marker, to: markerURL)
    }

    private func readMarker() throws -> [String: Any] {
        let data = try Data(contentsOf: markerURL)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotificationHookInstallError.io("marker is not a JSON object")
        }
        return dict
    }

    private func markerRemovedEntries() -> [[String: String]] {
        guard let marker = try? readMarker() else { return [] }
        return markerRemovedEntries(from: marker)
    }

    private func markerRemovedEntries(from marker: [String: Any]) -> [[String: String]] {
        let raw = (marker["removedSessionNotify"] as? [[String: Any]]) ?? []
        return raw.map { dict in
            var out: [String: String] = [:]
            for (k, v) in dict { if let s = v as? String { out[k] = s } }
            return out
        }
    }

    // MARK: - Backup

    @discardableResult
    private func createBackup() throws -> URL {
        let backupDir = claudeDir.appendingPathComponent("\(Self.backupPrefix)\(Self.timestamp())")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            throw NotificationHookInstallError.io("failed to create backup dir: \(error.localizedDescription)")
        }
        if fm.fileExists(atPath: settingsURL.path) {
            try? fm.copyItem(at: settingsURL, to: backupDir.appendingPathComponent("settings.json"))
        }
        return backupDir
    }

    private func latestBackupSettings() -> [String: Any]? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        // Timestamp suffix sorts lexically == chronologically.
        let backups = entries
            .filter { $0.lastPathComponent.hasPrefix(Self.backupPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let latest = backups.last else { return nil }
        return try? readSettingsJSON(at: latest.appendingPathComponent("settings.json"))
    }

    // MARK: - Settings IO (lite copies of HardeningInstaller's helpers)

    private func readSettingsJSON(at url: URL) throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return [:] }
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NotificationHookInstallError.malformedSettingsJson
            }
            return dict
        } catch let e as NotificationHookInstallError {
            throw e
        } catch {
            throw NotificationHookInstallError.malformedSettingsJson
        }
    }

    private func atomicWriteJSON(dict: [String: Any], to url: URL) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw NotificationHookInstallError.io("JSON serialization failed: \(error.localizedDescription)")
        }
        try atomicWrite(data: data, to: url)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmpURL, options: [.atomic])
        } catch {
            throw NotificationHookInstallError.io("failed to write staging file: \(error.localizedDescription)")
        }
        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw NotificationHookInstallError.io("failed to replace \(url.path): \(error.localizedDescription)")
            }
        } else {
            do {
                try fm.moveItem(at: tmpURL, to: url)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw NotificationHookInstallError.io("failed to install \(url.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
