import Foundation

// MARK: - Public Types

struct RoutingInstallOptions: Sendable {
    let coreAgents: Bool
    let securityAgents: Bool
    let policyBlock: Bool
    let settingsFallbackModel: Bool

    init(
        coreAgents: Bool = true,
        securityAgents: Bool = true,
        policyBlock: Bool = true,
        settingsFallbackModel: Bool = true
    ) {
        self.coreAgents = coreAgents
        self.securityAgents = securityAgents
        self.policyBlock = policyBlock
        self.settingsFallbackModel = settingsFallbackModel
    }
}

enum RoutingInstallError: Error, CustomStringConvertible {
    case payloadUnavailable(String)
    case malformedSettingsJson
    case noMarkerForRevert
    case io(String)

    var description: String {
        switch self {
        case .payloadUnavailable(let detail):
            return "Bundled routing stack resources are unavailable: \(detail)"
        case .malformedSettingsJson:
            return "~/.claude/settings.json is not valid JSON or has the wrong shape; aborting to preserve user data."
        case .noMarkerForRevert:
            return "No install marker found at ~/.claude/.claudoscope-routing-installed. Use Uninstall to surgically remove instead."
        case .io(let detail):
            return "Filesystem error: \(detail)"
        }
    }
}

enum RoutingFileStatus: Sendable, Equatable {
    case new
    case upToDate
    case willOverwriteDiffering
}

struct RoutingPreflightItem: Sendable, Equatable, Identifiable {
    let fileName: String
    let group: RoutingStackPayload.Group
    let status: RoutingFileStatus
    var id: String { fileName }
}

struct RoutingPreflight: Sendable {
    let agentItems: [RoutingPreflightItem]
    let policyBlockPresent: Bool
    let fallbackModelAlreadySet: Bool
    let hasFallbackModelPayload: Bool
}

struct RoutingInstallResult: Sendable {
    let installedAt: Date
    let backupPath: URL
    let componentsApplied: [String]
    let overwrittenAgentFiles: [String]
    let warnings: [String]
}

struct RoutingUninstallReport: Sendable {
    let removedFiles: [String]
    let keptUserEditedFiles: [String]
    let policyBlockRemoved: Bool
    let fallbackModelRemoved: Bool
}

// MARK: - RoutingStackInstaller

/// Orchestrates installation, revert, and uninstall of the Claudoscope agent
/// routing stack against `~/.claude/`. Mirrors `HardeningInstaller`'s atomic
/// staged writes, timestamped backups, and first-install-wins marker pattern,
/// but takes its payload and install-in-progress gate as injected closures
/// (the `NotificationHookInstaller` pattern) so the full happy path is
/// unit-testable under `swift test` without any `Bundle.main` dependency.
actor RoutingStackInstaller {

    static let markerFileName = ".claudoscope-routing-installed"
    static let backupPrefix = ".claudoscope-routing-backup-"
    static let policyBeginMarker = "<!-- BEGIN: claudoscope-agent-routing -->"
    static let policyEndMarker = "<!-- END: claudoscope-agent-routing -->"

    private let claudeDir: URL
    private let payloadProvider: @Sendable () throws -> RoutingStackPayload
    private let setInstallInProgress: @Sendable @MainActor (Bool) -> Void

    init(
        claudeDir: URL,
        payloadProvider: @escaping @Sendable () throws -> RoutingStackPayload,
        setInstallInProgress: @escaping @Sendable @MainActor (Bool) -> Void
    ) {
        self.claudeDir = claudeDir
        self.payloadProvider = payloadProvider
        self.setInstallInProgress = setInstallInProgress
    }

    // MARK: Paths

    private var agentsDir: URL { claudeDir.appendingPathComponent("agents") }
    private var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }
    private var claudeMdURL: URL { claudeDir.appendingPathComponent("CLAUDE.md") }
    private var markerURL: URL { claudeDir.appendingPathComponent(Self.markerFileName) }

    // MARK: - Public API

    /// Per-agent-file install status against the live `~/.claude/agents/`
    /// directory, for the install sheet's review phase. Read-only, no gate.
    func preflight() throws -> RoutingPreflight {
        let payload = try loadPayload()
        let fm = FileManager.default

        var items: [RoutingPreflightItem] = []
        for file in payload.agentFiles {
            let liveURL = agentsDir.appendingPathComponent(file.fileName)
            let status: RoutingFileStatus
            if !fm.fileExists(atPath: liveURL.path) {
                status = .new
            } else if let existing = try? String(contentsOf: liveURL, encoding: .utf8), existing == file.content {
                status = .upToDate
            } else {
                status = .willOverwriteDiffering
            }
            items.append(RoutingPreflightItem(fileName: file.fileName, group: file.group, status: status))
        }

        let settings = (try? InstallerFileOps.readSettingsJSON(at: settingsURL)) ?? [:]
        let fallbackAlreadySet = settings["fallbackModel"] != nil

        var policyPresent = false
        if let data = try? Data(contentsOf: claudeMdURL), let text = String(data: data, encoding: .utf8) {
            policyPresent = text.contains(Self.policyBeginMarker)
        }

        return RoutingPreflight(
            agentItems: items,
            policyBlockPresent: policyPresent,
            fallbackModelAlreadySet: fallbackAlreadySet,
            hasFallbackModelPayload: payload.fallbackModel != nil
        )
    }

    /// Install the selected components. Backs up every file about to be
    /// touched before any write; refuses on malformed settings.json before
    /// any agent/CLAUDE.md write happens. Never touches `settings["model"]`.
    func install(options: RoutingInstallOptions) async throws -> RoutingInstallResult {
        await gate(true)
        defer { Task { await gate(false) } }

        let payload = try loadPayload()
        let fm = FileManager.default

        var filesToWrite: [RoutingStackPayload.AgentFile] = []
        if options.coreAgents { filesToWrite.append(contentsOf: payload.coreFiles) }
        if options.securityAgents { filesToWrite.append(contentsOf: payload.securityFiles) }

        // 1. Backup every file we might touch, before touching any of them.
        var backupFiles: [(source: URL, relativeName: String)] = [
            (settingsURL, "settings.json"),
            (claudeMdURL, "CLAUDE.md"),
        ]
        var overwrittenAgentFiles: [String] = []
        for file in filesToWrite {
            let liveURL = agentsDir.appendingPathComponent(file.fileName)
            guard fm.fileExists(atPath: liveURL.path) else { continue }
            backupFiles.append((liveURL, "agents/\(file.fileName)"))
            if let existing = try? String(contentsOf: liveURL, encoding: .utf8), existing != file.content {
                overwrittenAgentFiles.append(file.fileName)
            }
        }
        let backupDir = try mapped {
            try InstallerFileOps.createBackup(claudeDir: claudeDir, prefix: Self.backupPrefix, files: backupFiles)
        }

        // 2. Read settings.json — throws malformedSettingsJson BEFORE any agent/CLAUDE.md write.
        var settings = try mapped { try InstallerFileOps.readSettingsJSON(at: settingsURL) }

        let existingMarker = try? InstallerFileOps.readMarkerJSON(at: markerURL)

        // 3. Write agent files for the selected groups.
        var componentsApplied: [String] = []
        for file in filesToWrite {
            let liveURL = agentsDir.appendingPathComponent(file.fileName)
            try mapped { try InstallerFileOps.atomicWrite(data: Data(file.content.utf8), to: liveURL) }
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: liveURL.path)
        }
        if options.coreAgents { componentsApplied.append("core-agents (+\(payload.coreFiles.count) files)") }
        if options.securityAgents { componentsApplied.append("security-agents (+\(payload.securityFiles.count) files)") }

        // 4. Group flags OR-merge with whatever the marker already recorded.
        let priorCore = (existingMarker?["coreInstalled"] as? Bool) ?? false
        let priorSecurity = (existingMarker?["securityInstalled"] as? Bool) ?? false
        let priorPolicy = (existingMarker?["policyInstalled"] as? Bool) ?? false
        let effectiveCore = priorCore || options.coreAgents
        let effectiveSecurity = priorSecurity || options.securityAgents
        var effectivePolicy = priorPolicy

        // 5. Policy block: union of installed groups, so a core-only reinstall
        // on top of an earlier full install can't orphan security roles.
        if options.policyBlock {
            let body = assemblePolicy(payload: payload, includeSecurity: effectiveSecurity)
            var existingText = ""
            if let data = try? Data(contentsOf: claudeMdURL), let text = String(data: data, encoding: .utf8) {
                existingText = text
            }
            let final = InstallerFileOps.appendMarkerBlock(
                to: existingText, body: body, begin: Self.policyBeginMarker, end: Self.policyEndMarker
            )
            if let data = final.data(using: .utf8) {
                try mapped { try InstallerFileOps.atomicWrite(data: data, to: claudeMdURL) }
            }
            effectivePolicy = true
            componentsApplied.append("policy-block")
        }

        // 6. fallbackModel: set only if absent, first-set-wins recorded in the marker.
        var fallbackModelSet = (existingMarker?["fallbackModelSet"] as? Bool) ?? false
        var fallbackModelValue = existingMarker?["fallbackModelValue"] as? [String]
        var settingsChanged = false
        if !fallbackModelSet, options.settingsFallbackModel, let want = payload.fallbackModel {
            if settings["fallbackModel"] == nil {
                settings["fallbackModel"] = want
                fallbackModelSet = true
                fallbackModelValue = want
                settingsChanged = true
                componentsApplied.append("fallback-model")
            }
        }
        if settingsChanged {
            try mapped { try InstallerFileOps.atomicWriteJSON(dict: settings, to: settingsURL) }
        }

        // 7. agentHashes union-merge: latest write wins per file, prior entries kept.
        var agentHashes = Self.markerAgentHashes(in: existingMarker ?? [:])
        for file in filesToWrite {
            if let hash = payload.contentHash(forAgent: file.fileName) {
                agentHashes[file.fileName] = hash
            }
        }

        // 8. Marker: installedAt/backupPath first-install-wins.
        let installStart = Date()
        try writeMarker(
            installedAt: installStart,
            backupPath: backupDir,
            coreInstalled: effectiveCore,
            securityInstalled: effectiveSecurity,
            policyInstalled: effectivePolicy,
            fallbackModelSet: fallbackModelSet,
            fallbackModelValue: fallbackModelValue,
            agentHashes: agentHashes,
            existingMarker: existingMarker
        )

        return RoutingInstallResult(
            installedAt: installStart,
            backupPath: backupDir,
            componentsApplied: componentsApplied,
            overwrittenAgentFiles: overwrittenAgentFiles,
            warnings: []
        )
    }

    /// Restore the pre-first-install state from this install's backup.
    /// Requires the marker file; if missing, throws `noMarkerForRevert`
    /// pointing at Uninstall instead. Never destroys an agent file the user
    /// edited after we installed it.
    func revert() async throws {
        await gate(true)
        defer { Task { await gate(false) } }

        guard let marker = try? InstallerFileOps.readMarkerJSON(at: markerURL) else {
            throw RoutingInstallError.noMarkerForRevert
        }

        let backupPathString = marker["backupPath"] as? String ?? ""
        let backupDir = URL(fileURLWithPath: backupPathString)
        let fm = FileManager.default

        let backedSettings = backupDir.appendingPathComponent("settings.json")
        if fm.fileExists(atPath: backedSettings.path) {
            try? InstallerFileOps.replaceFile(at: settingsURL, withContentsOf: backedSettings)
        }

        let backedClaudeMd = backupDir.appendingPathComponent("CLAUDE.md")
        if fm.fileExists(atPath: backedClaudeMd.path) {
            try? InstallerFileOps.replaceFile(at: claudeMdURL, withContentsOf: backedClaudeMd)
        } else if fm.fileExists(atPath: claudeMdURL.path),
                  let data = try? Data(contentsOf: claudeMdURL),
                  let text = String(data: data, encoding: .utf8) {
            // No pre-install CLAUDE.md existed; just strip our block if present.
            let stripped = InstallerFileOps.stripMarkerBlock(from: text, begin: Self.policyBeginMarker, end: Self.policyEndMarker)
            if stripped != text, let out = stripped.data(using: .utf8) {
                try? InstallerFileOps.atomicWrite(data: out, to: claudeMdURL)
            }
        }

        let agentHashes = Self.markerAgentHashes(in: marker)
        let currentPayload = try? loadPayload()
        let backupAgentsDir = backupDir.appendingPathComponent("agents")

        for (name, markerHash) in agentHashes {
            let liveURL = agentsDir.appendingPathComponent(name)
            let backupURL = backupAgentsDir.appendingPathComponent(name)

            var isOurs = true
            if fm.fileExists(atPath: liveURL.path) {
                let liveHash = (try? InstallerFileOps.sha256(file: liveURL)) ?? ""
                let matchesMarker = liveHash == markerHash
                let matchesCurrentPayload = currentPayload?.contentHash(forAgent: name) == liveHash
                isOurs = matchesMarker || matchesCurrentPayload
            }
            guard isOurs else { continue }  // user-edited post-install: leave entirely alone

            if fm.fileExists(atPath: backupURL.path) {
                try? InstallerFileOps.replaceFile(at: liveURL, withContentsOf: backupURL)
            } else {
                try? fm.removeItem(at: liveURL)
            }
        }

        try? fm.removeItem(at: markerURL)
    }

    /// Surgically remove routing stack artifacts. Safe to run without a
    /// marker (a no-op for agent files in that case, since there is no
    /// record of which files are ours). Agent files the user edited after
    /// install are left in place and reported.
    func uninstall(deleteBackups: Bool) async throws -> RoutingUninstallReport {
        await gate(true)
        defer { Task { await gate(false) } }

        let fm = FileManager.default
        let marker = try? InstallerFileOps.readMarkerJSON(at: markerURL)
        let currentPayload = try? loadPayload()
        let agentHashes = Self.markerAgentHashes(in: marker ?? [:])

        // Back up every file this uninstall touches, before any strip/remove write.
        // Tolerant: a failed safety backup must not block the user's explicit uninstall.
        var backupFiles: [(source: URL, relativeName: String)] = [
            (settingsURL, "settings.json"),
            (claudeMdURL, "CLAUDE.md"),
        ]
        for name in agentHashes.keys {
            backupFiles.append((agentsDir.appendingPathComponent(name), "agents/\(name)"))
        }
        if backupFiles.contains(where: { fm.fileExists(atPath: $0.source.path) }) {
            _ = try? InstallerFileOps.createBackup(claudeDir: claudeDir, prefix: Self.backupPrefix, files: backupFiles)
        }

        var removedFiles: [String] = []
        var keptUserEditedFiles: [String] = []

        for (name, markerHash) in agentHashes {
            let liveURL = agentsDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: liveURL.path) else { continue }
            let liveHash = (try? InstallerFileOps.sha256(file: liveURL)) ?? ""
            let matchesMarker = liveHash == markerHash
            let matchesCurrentPayload = currentPayload?.contentHash(forAgent: name) == liveHash
            if matchesMarker || matchesCurrentPayload {
                try? fm.removeItem(at: liveURL)
                removedFiles.append(name)
            } else {
                keptUserEditedFiles.append(name)
            }
        }

        var policyBlockRemoved = false
        if fm.fileExists(atPath: claudeMdURL.path),
           let data = try? Data(contentsOf: claudeMdURL),
           let text = String(data: data, encoding: .utf8) {
            let cleaned = InstallerFileOps.stripMarkerBlock(from: text, begin: Self.policyBeginMarker, end: Self.policyEndMarker)
            if cleaned != text, let out = cleaned.data(using: .utf8) {
                try? InstallerFileOps.atomicWrite(data: out, to: claudeMdURL)
                policyBlockRemoved = true
            }
        }

        var fallbackModelRemoved = false
        if fm.fileExists(atPath: settingsURL.path),
           let markerSet = marker?["fallbackModelSet"] as? Bool, markerSet,
           let markerValue = marker?["fallbackModelValue"] as? [String] {
            var settings = (try? InstallerFileOps.readSettingsJSON(at: settingsURL)) ?? [:]
            if let live = settings["fallbackModel"] as? [String], live == markerValue {
                settings.removeValue(forKey: "fallbackModel")
                try? InstallerFileOps.atomicWriteJSON(dict: settings, to: settingsURL)
                fallbackModelRemoved = true
            }
        }

        if deleteBackups {
            InstallerFileOps.deleteAllBackupDirectories(claudeDir: claudeDir, prefix: Self.backupPrefix)
        }

        try? fm.removeItem(at: markerURL)

        return RoutingUninstallReport(
            removedFiles: removedFiles,
            keptUserEditedFiles: keptUserEditedFiles,
            policyBlockRemoved: policyBlockRemoved,
            fallbackModelRemoved: fallbackModelRemoved
        )
    }

    // MARK: - Internal: policy assembly (shared source of truth with RTG003)

    func assemblePolicy(payload: RoutingStackPayload, includeSecurity: Bool) -> String {
        payload.policyBody(includeSecurity: includeSecurity)
    }

    /// Extracts `agentHashes` from a marker dict with manual value coercion,
    /// tolerant of the `[String: Any]` shape JSONSerialization round-trips produce.
    static func markerAgentHashes(in marker: [String: Any]) -> [String: String] {
        guard let raw = marker["agentHashes"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in raw {
            if let s = value as? String { out[key] = s }
        }
        return out
    }

    // MARK: - Internal: gate

    private func gate(_ value: Bool) async {
        let cb = setInstallInProgress
        await MainActor.run { cb(value) }
    }

    // MARK: - Internal: payload

    private func loadPayload() throws -> RoutingStackPayload {
        do {
            return try payloadProvider()
        } catch {
            throw RoutingInstallError.payloadUnavailable(String(describing: error))
        }
    }

    // MARK: - Internal: marker

    private func writeMarker(
        installedAt: Date,
        backupPath: URL,
        coreInstalled: Bool,
        securityInstalled: Bool,
        policyInstalled: Bool,
        fallbackModelSet: Bool,
        fallbackModelValue: [String]?,
        agentHashes: [String: String],
        existingMarker: [String: Any]?
    ) throws {
        var effectiveInstalledAt = installedAt
        var effectiveBackupPath = backupPath

        if let existing = existingMarker {
            if let prior = existing["installedAt"] as? String,
               let parsed = InstallerFileOps.isoDate(from: prior) {
                effectiveInstalledAt = parsed
            }
            if let prior = existing["backupPath"] as? String {
                effectiveBackupPath = URL(fileURLWithPath: prior)
            }
        }

        var marker: [String: Any] = [
            "version": "1",
            "installedAt": InstallerFileOps.isoString(from: effectiveInstalledAt),
            "backupPath": effectiveBackupPath.path,
            "coreInstalled": coreInstalled,
            "securityInstalled": securityInstalled,
            "policyInstalled": policyInstalled,
            "fallbackModelSet": fallbackModelSet,
            "agentHashes": agentHashes,
        ]
        if let value = fallbackModelValue {
            marker["fallbackModelValue"] = value
        }

        try mapped { try InstallerFileOps.atomicWriteJSON(dict: marker, to: markerURL) }
    }

    // MARK: - Internal: error mapping

    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch InstallerFileOpsError.malformedSettingsJson {
            throw RoutingInstallError.malformedSettingsJson
        } catch InstallerFileOpsError.io(let detail) {
            throw RoutingInstallError.io(detail)
        }
    }
}
