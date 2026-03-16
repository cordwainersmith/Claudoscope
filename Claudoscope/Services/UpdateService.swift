import Foundation
import AppKit
import Security

@Observable
final class UpdateService {
    var updateAvailable: UpdateInfo?
    var isChecking = false
    var isDownloading = false
    var downloadProgress: Double = 0
    var error: String?

    var onUpdateFound: ((UpdateInfo) -> Void)?

    private var checkTimer: Timer?
    private var downloadTask: URLSessionDownloadTask?

    private static let repoOwner = "cordwainersmith"
    private static let repoName = "Claudoscope"
    private static let teamID = "DN8M2CQ4D2"
    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let autoCheckKey = "autoCheckForUpdates"
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

    init() {
        // Default to auto-check enabled
        if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.autoCheckKey)
        }
    }

    func startPeriodicChecks() {
        guard autoCheckEnabled else { return }

        // Check after a short delay on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            Task { await self.checkForUpdates() }
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

        defer {
            isChecking = false
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        }

        let urlString = "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            error = "Invalid API URL"
            return
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                error = "GitHub API returned an error"
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                error = "Unexpected response format"
                return
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard isNewerVersion(remoteVersion, than: currentVersion) else {
                updateAvailable = nil
                return
            }

            // Build download URL through the Worker for tracking
            let downloadURL = URL(string: "https://dl.claudoscope.com/v\(remoteVersion)/Claudoscope.dmg?type=update")!

            let releaseNotes = json["body"] as? String

            let info = UpdateInfo(
                version: remoteVersion,
                downloadURL: downloadURL,
                releaseNotes: releaseNotes
            )
            updateAvailable = info
            onUpdateFound?(info)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    func downloadAndInstall() async {
        guard let update = updateAvailable else { return }
        guard !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        error = nil

        do {
            // Download DMG to temp directory
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudoscopeUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let dmgPath = tempDir.appendingPathComponent("Claudoscope.dmg")
            try await downloadFile(from: update.downloadURL, to: dmgPath)

            // Mount DMG
            let mountPoint = tempDir.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

            let mountResult = try runProcess(
                "/usr/bin/hdiutil",
                arguments: ["attach", dmgPath.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
            )
            guard mountResult.exitCode == 0 else {
                throw UpdateError.mountFailed(mountResult.output)
            }

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
            relaunch(at: currentAppURL)
        } catch {
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
        let notes = ChangelogParser.bundledNotes(for: version)
        UserDefaults.standard.removeObject(forKey: Self.justUpdatedVersionKey)
        // Clean up legacy key from older versions
        UserDefaults.standard.removeObject(forKey: "justUpdatedReleaseNotes")
        return JustUpdatedInfo(version: version, releaseNotes: notes)
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
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
