import Foundation
import CryptoKit

enum InstallerFileOpsError: Error {
    case malformedSettingsJson
    case io(String)
}

/// Shared filesystem primitives for the Hardening and Routing installers.
/// Pure static functions, no actor state, fully unit-testable.
enum InstallerFileOps {

    // MARK: - Atomic writes

    /// Stages to `<final>.tmp-<uuid>`, fsyncs, then `replaceItemAt(...)` so
    /// FSEvents observers only ever see the final, complete file.
    static func atomicWrite(data: Data, to url: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmpName = "\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        let tmpURL = url.deletingLastPathComponent().appendingPathComponent(tmpName)

        do {
            try data.write(to: tmpURL, options: [.atomic])
        } catch {
            throw InstallerFileOpsError.io("failed to write staging file \(tmpURL.path): \(error.localizedDescription)")
        }

        // Best-effort fsync; Data.write(.atomic) already covers durability most of the time.
        if let handle = try? FileHandle(forUpdating: tmpURL) {
            try? handle.synchronize()
            try? handle.close()
        }

        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw InstallerFileOpsError.io("failed to replace \(url.path): \(error.localizedDescription)")
            }
        } else {
            do {
                try fm.moveItem(at: tmpURL, to: url)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw InstallerFileOpsError.io("failed to install \(url.path): \(error.localizedDescription)")
            }
        }
    }

    static func atomicWriteJSON(dict: [String: Any], to url: URL) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw InstallerFileOpsError.io("JSON serialization failed: \(error.localizedDescription)")
        }
        try atomicWrite(data: data, to: url)
    }

    /// Replace a file by copying source contents over. Used by revert.
    static func replaceFile(at dst: URL, withContentsOf src: URL) throws {
        let data = try Data(contentsOf: src)
        try atomicWrite(data: data, to: dst)
    }

    static func moveOrReplace(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            do {
                _ = try fm.replaceItemAt(dst, withItemAt: src)
            } catch {
                throw InstallerFileOpsError.io("failed to replace \(dst.path): \(error.localizedDescription)")
            }
        } else {
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                throw InstallerFileOpsError.io("failed to install \(dst.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - settings.json

    /// Read settings.json. Returns an empty dict if the file doesn't exist
    /// (fresh install). Throws `malformedSettingsJson` on parse failure rather
    /// than silently overwriting the user's hand-edited file.
    static func readSettingsJSON(at url: URL) throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return [:] }
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallerFileOpsError.malformedSettingsJson
            }
            return dict
        } catch let e as InstallerFileOpsError {
            throw e
        } catch {
            throw InstallerFileOpsError.malformedSettingsJson
        }
    }

    // MARK: - Hashing

    static func sha256(file url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256(ofData: data)
    }

    static func sha256(of string: String) -> String {
        sha256(ofData: Data(string.utf8))
    }

    private static func sha256(ofData data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Parse a `shasum -a 256` sidecar: lines of the form
    /// `<hex>  <filename>` (two spaces). Tolerates blank lines and CRLF.
    static func parseChecksumSidecar(content: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let hex = String(parts[0])
            var name = String(parts[1...].joined(separator: " "))
            if name.hasPrefix("*") { name.removeFirst() }
            if name.hasPrefix("./") { name = String(name.dropFirst(2)) }
            let basename = (name as NSString).lastPathComponent
            out[basename] = hex
        }
        return out
    }

    // MARK: - Dict helpers

    static func unionStringArray(existing: [String], additions: [String]) -> [String] {
        var seen = Set(existing)
        var result = existing
        for a in additions where !seen.contains(a) {
            result.append(a)
            seen.insert(a)
        }
        return result
    }

    /// Recursive equality on [String: Any] dicts via sorted-key JSON comparison.
    /// Cheap, deterministic, tolerant of numeric/boolean type variation.
    static func dictsEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard let dataA = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let dataB = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else {
            return false
        }
        return dataA == dataB
    }

    // MARK: - Marker JSON

    static func readMarkerJSON(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerFileOpsError.io("marker file is not a JSON object: \(url.path)")
        }
        return dict
    }

    // MARK: - Marker-delimited text blocks (e.g. CLAUDE.md governance/policy sections)

    /// Remove the marker-wrapped block from a text body, including the markers
    /// themselves and the leading blank line(s) inserted when it was appended.
    static func stripMarkerBlock(from text: String, begin: String, end: String) -> String {
        guard let beginRange = text.range(of: begin),
              let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) else {
            return text
        }

        var start = beginRange.lowerBound
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev] == "\n" { start = prev } else { break }
        }
        var stop = endRange.upperBound
        if stop < text.endIndex, text[stop] == "\n" {
            stop = text.index(after: stop)
        }

        var result = text
        result.removeSubrange(start..<stop)
        return result
    }

    /// Idempotent append: strip any existing block, then append the fresh body
    /// after trimming trailing newlines and inserting one blank line.
    static func appendMarkerBlock(to text: String, body: String, begin: String, end: String) -> String {
        let stripped = stripMarkerBlock(from: text, begin: begin, end: end)
        let trimmed = stripped.trimmingCharacters(in: .newlines)
        let block = "\n\n\(begin)\n\(body)\n\(end)\n"
        return trimmed + block
    }

    // MARK: - Timestamps

    static func utcTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    static func isoNow() -> String {
        isoString(from: Date())
    }

    static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    static func isoDate(from string: String) -> Date? {
        isoFormatter.date(from: string)
    }

    private static var isoFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    // MARK: - Backup

    /// Creates `<claudeDir>/<prefix><UTC yyyyMMdd-HHmmss>/` and copies each
    /// existing source into it under `relativeName` (files or directories).
    /// Missing sources are silently skipped, matching hardening's precedent.
    @discardableResult
    static func createBackup(
        claudeDir: URL,
        prefix: String,
        files: [(source: URL, relativeName: String)]
    ) throws -> URL {
        let backupDir = claudeDir.appendingPathComponent("\(prefix)\(utcTimestamp())")
        let fm = FileManager.default
        do {
            // Owner-only: backups can hold settings.json, which may carry env API keys.
            try fm.createDirectory(
                at: backupDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            throw InstallerFileOpsError.io("failed to create backup dir \(backupDir.path): \(error.localizedDescription)")
        }

        for file in files where fm.fileExists(atPath: file.source.path) {
            let dst = backupDir.appendingPathComponent(file.relativeName)
            // Already captured in this same-timestamp backup dir (e.g. a same-second
            // reinstall reusing the dir): keep the first copy, don't overwrite it.
            // This preserves the first-install-wins pristine backup that revert relies on.
            if fm.fileExists(atPath: dst.path) { continue }
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file.source, to: dst)
            } catch {
                throw InstallerFileOpsError.io("failed to back up \(file.source.path) -> \(dst.path): \(error.localizedDescription)")
            }
        }

        return backupDir
    }

    // MARK: - Backup listing

    static func backupDirectories(in claudeDir: URL, prefix: String) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func sizeOf(directory: URL) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    static func deleteAllBackupDirectories(claudeDir: URL, prefix: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: entry)
        }
    }
}
