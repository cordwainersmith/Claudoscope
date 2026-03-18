import Foundation
import AppKit
import Security
import os

@Observable
final class UpdateService {
    var updateAvailable: UpdateInfo?
    var whatsNewInfo: JustUpdatedInfo?
    var isChecking = false
    var isDownloading = false
    var downloadProgress: Double = 0
    var error: String?

    var onUpdateFound: ((UpdateInfo) -> Void)?
    var onOpenWhatsNew: (() -> Void)?

    private let logger = Logger(subsystem: "com.cordwainersmith.Claudoscope", category: "Update")
    private var checkTimer: Timer?
    private var downloadingTask: Task<Void, Never>?

    private static let repoOwner = "cordwainersmith"
    private static let repoName = "Claudoscope"
    private static let teamID = "DN8M2CQ4D2"
    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let autoCheckKey = "autoCheckForUpdates"
    private static let skippedVersionKey = "skippedUpdateVersion"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let justUpdatedVersionKey = "justUpdatedToVersion"

    struct UpdateInfo {
        let version: String
        let downloadURL: URL
        let releaseNotes: String?
    }

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoCheckKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey)
            if newValue {
                schedulePeriodicCheck()
            } else {
                checkTimer?.invalidate()
                checkTimer = nil
            }
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var skippedVersion: String? {
        UserDefaults.standard.string(forKey: Self.skippedVersionKey)
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: Self.skippedVersionKey)
    }

    func clearSkippedVersion() {
        UserDefaults.standard.removeObject(forKey: Self.skippedVersionKey)
    }

    init() {
        // Default to auto-check enabled
        if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.autoCheckKey)
        }
    }

    func startPeriodicChecks() {
        guard autoCheckEnabled else { return }

        // Skip the launch check if we checked less than 1 hour ago
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let sinceLastCheck = Date().timeIntervalSince1970 - lastCheck
        if lastCheck == 0 || sinceLastCheck > 3600 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                Task { await self.checkForUpdates() }
            }
        }

        schedulePeriodicCheck()
    }

    private func schedulePeriodicCheck() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.checkForUpdates() }
        }
    }

    @MainActor
    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        error = nil
        logger.info("Checking for updates, current version: \(self.currentVersion)")

        defer {
            isChecking = false
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        }

        let urlString = "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid API URL: \(urlString)")
            error = "Invalid API URL"
            return
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("GitHub API error, status code: \(statusCode)")
                error = "GitHub API returned an error"
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                logger.error("Unexpected response format from GitHub API")
                error = "Unexpected response format"
                return
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard isNewerVersion(remoteVersion, than: currentVersion) else {
                logger.info("Already up to date (remote: \(remoteVersion), current: \(self.currentVersion))")
                updateAvailable = nil
                return
            }

            logger.info("Update available: \(remoteVersion) (current: \(self.currentVersion))")

            // Build download URL through the Worker for tracking
            let downloadURL = URL(string: "https://dl.claudoscope.com/v\(remoteVersion)/Claudoscope.dmg?type=update")!

            let releaseNotes = json["body"] as? String

            let info = UpdateInfo(
                version: remoteVersion,
                downloadURL: downloadURL,
                releaseNotes: releaseNotes
            )
            updateAvailable = info

            if remoteVersion == skippedVersion {
                // Skipped version: set updateAvailable (for badge/settings) but no popup
            } else {
                // New version (or newer than skipped): clear any old skip and show popup
                if skippedVersion != nil {
                    clearSkippedVersion()
                }
                onUpdateFound?(info)
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    @MainActor
    func downloadAndInstall() {
        guard let update = updateAvailable else { return }
        guard !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        error = nil

        downloadingTask = Task { @MainActor in
            await _performDownloadAndInstall(update: update)
        }
    }

    @MainActor
    private func _performDownloadAndInstall(update: UpdateInfo) async {
        do {
            // Download DMG to temp directory
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudoscopeUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let dmgPath = tempDir.appendingPathComponent("Claudoscope.dmg")
            logger.info("Downloading update from \(update.downloadURL.absoluteString)")
            try await downloadFile(from: update.downloadURL, to: dmgPath)

            // Mount DMG
            let mountPoint = tempDir.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

            let mountResult = try runProcess(
                "/usr/bin/hdiutil",
                arguments: ["attach", dmgPath.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
            )
            guard mountResult.exitCode == 0 else {
                logger.error("DMG mount failed: \(mountResult.output)")
                throw UpdateError.mountFailed(mountResult.output)
            }
            logger.info("DMG mounted at \(mountPoint.path)")

            defer {
                // Always try to unmount
                _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"])
                // Clean up temp directory
                try? FileManager.default.removeItem(at: tempDir)
            }

            // Find .app in mounted volume
            let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            guard let newAppURL = contents.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.noAppInDMG
            }

            // Verify code signature
            try verifyCodeSignature(at: newAppURL)
            logger.info("Code signature verified for \(newAppURL.lastPathComponent)")

            // Replace current app
            guard let currentAppURL = Bundle.main.bundleURL as URL? else {
                throw UpdateError.cannotLocateCurrentApp
            }

            let appParent = currentAppURL.deletingLastPathComponent()
            let appName = currentAppURL.lastPathComponent
            let backupURL = appParent.appendingPathComponent(appName + ".bak")

            // Remove old backup if it exists
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }

            // Move current app to backup
            try FileManager.default.moveItem(at: currentAppURL, to: backupURL)

            do {
                // Copy new app
                try FileManager.default.copyItem(at: newAppURL, to: currentAppURL)
            } catch {
                // Restore from backup on failure
                try? FileManager.default.moveItem(at: backupURL, to: currentAppURL)
                throw UpdateError.replaceFailed(error.localizedDescription)
            }

            // Remove backup
            try? FileManager.default.removeItem(at: backupURL)

            // Store version for the "What's New" popup after relaunch
            // (notes come from bundled CHANGELOG.md, no need to persist them)
            UserDefaults.standard.set(update.version, forKey: Self.justUpdatedVersionKey)
            UserDefaults.standard.synchronize()

            // Relaunch
            logger.info("App replaced successfully, relaunching to v\(update.version)")
            relaunch(at: currentAppURL)
        } catch {
            logger.error("Download/install failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
            isDownloading = false
        }
    }

    struct JustUpdatedInfo {
        let version: String
        let releaseNotes: String?
    }

    func consumeJustUpdatedInfo() -> JustUpdatedInfo? {
        guard let version = UserDefaults.standard.string(forKey: Self.justUpdatedVersionKey) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: Self.justUpdatedVersionKey)
        // Clean up legacy key from older versions
        UserDefaults.standard.removeObject(forKey: "justUpdatedReleaseNotes")
        return JustUpdatedInfo(version: version, releaseNotes: nil)
    }

    func cancelDownload() {
        downloadingTask?.cancel()
        downloadingTask = nil
        isDownloading = false
        downloadProgress = 0
    }

    // MARK: - Private Helpers

    private func downloadFile(from url: URL, to destination: URL) async throws {
        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, response) = try await session.download(from: url)
        session.finishTasksAndInvalidate()

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func verifyCodeSignature(at appURL: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw UpdateError.signatureInvalid("Failed to create static code object")
        }

        // Validate the signature
        let validateStatus = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        guard validateStatus == errSecSuccess else {
            throw UpdateError.signatureInvalid("Code signature validation failed")
        }

        // Extract signing info and verify Team ID
        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard infoStatus == errSecSuccess, let info = information as? [String: Any] else {
            throw UpdateError.signatureInvalid("Failed to read signing information")
        }

        guard let teamID = info["teamid"] as? String, teamID == Self.teamID else {
            throw UpdateError.signatureInvalid("Team ID mismatch: expected \(Self.teamID)")
        }
    }

    private func runProcess(_ path: String, arguments: [String]) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return (process.terminationStatus, output)
    }

    private func relaunch(at appURL: URL) {
        // Wait for the current process to fully exit before launching the
        // new app. Running both simultaneously (createsNewApplicationInstance)
        // corrupts the Dock icon state for LSUIElement apps.
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = appURL.path
        logger.info("Relaunching: pid=\(pid), path=\(path)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, localParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case downloadFailed
    case mountFailed(String)
    case noAppInDMG
    case cannotLocateCurrentApp
    case signatureInvalid(String)
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Failed to download update"
        case .mountFailed(let detail): return "Failed to mount DMG: \(detail)"
        case .noAppInDMG: return "No application found in downloaded DMG"
        case .cannotLocateCurrentApp: return "Cannot locate current application bundle"
        case .signatureInvalid(let detail): return "Code signature verification failed: \(detail)"
        case .replaceFailed(let detail): return "Failed to replace application: \(detail)"
        }
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async download call
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }
}
