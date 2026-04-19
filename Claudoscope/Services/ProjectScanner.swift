import Foundation

/// Scans ~/.claude/projects/ directories to discover projects and session files.
/// Port of server/services/project-scanner.ts
struct ProjectScanner {
    let claudeDir: URL
    let parser: SessionParser
    let pricingTable: [String: ModelPricing]

    /// Maximum number of files parsed concurrently to avoid CPU saturation.
    /// Heavy Claude Code users can accumulate thousands of session files;
    /// unbounded concurrency pegs the CPU and starves the UI run loop.
    private static let maxConcurrentParses = 8

    /// Scan all projects and collect session metadata.
    /// The optional `onProgress` callback fires on MainActor with (processed, total) counts.
    func scan(onProgress: (@Sendable @MainActor (Int, Int) -> Void)? = nil) async -> (projects: [Project], sessionsByProject: [String: [SessionSummary]]) {

        let projectsDir = claudeDir.appendingPathComponent("projects")
        var projects: [Project] = []
        var sessionsByProject: [String: [SessionSummary]] = [:]

        let fm = FileManager.default
        guard let dirNames = try? fm.contentsOfDirectory(atPath: projectsDir.path) else {
            return (projects, sessionsByProject)
        }

        let projectDirs = dirNames.filter { name in
            var isDir: ObjCBool = false
            let fullPath = projectsDir.appendingPathComponent(name).path
            return fm.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }

        // Collect all JSONL entries across all projects first, then parse with throttled concurrency
        var allEntries: [(dirName: String, url: URL, sessionId: String)] = []

        for dirName in projectDirs {
            let dirURL = projectsDir.appendingPathComponent(dirName)
            guard let topFiles = try? fm.contentsOfDirectory(atPath: dirURL.path) else {
                continue
            }

            for name in topFiles {
                if name.hasSuffix(".jsonl") {
                    let sid = String(name.dropLast(6))
                    allEntries.append((dirName, dirURL.appendingPathComponent(name), sid))
                }
                // Check for subagent files inside session subdirectories
                let subagentsDir = dirURL.appendingPathComponent(name).appendingPathComponent("subagents")
                if let subFiles = try? fm.contentsOfDirectory(atPath: subagentsDir.path) {
                    for subFile in subFiles where subFile.hasSuffix(".jsonl") {
                        let subId = String(subFile.dropLast(6))
                        allEntries.append((dirName, subagentsDir.appendingPathComponent(subFile), subId))
                    }
                }
            }
        }

        // Sort entries by file modification date (newest first) so the UI populates
        // with recent sessions quickly while older ones load in the background.
        // Pre-fetch dates to avoid O(n log n) filesystem calls inside the comparator.
        var datedEntries = allEntries.map { entry in
            let date = (try? fm.attributesOfItem(atPath: entry.url.path)[.modificationDate] as? Date) ?? .distantPast
            return (entry: entry, modDate: date)
        }
        datedEntries.sort { $0.modDate > $1.modDate }
        allEntries = datedEntries.map(\.entry)

        // Parse with bounded concurrency to avoid CPU saturation
        var resultsByProject: [String: [SessionSummary]] = [:]
        let projectDirSet = Set(projectDirs)
        let totalEntries = allEntries.count
        var processed = 0

        // Report total count immediately
        await onProgress?(0, totalEntries)

        await withTaskGroup(of: (String, SessionSummary)?.self) { group in
            var inflight = 0

            for entry in allEntries {
                if Task.isCancelled { break }
                if inflight >= Self.maxConcurrentParses {
                    if let result = await group.next() {
                        if let (dirName, summary) = result {
                            resultsByProject[dirName, default: []].append(summary)
                        }
                        processed += 1
                        // Report progress every 50 files to avoid UI churn
                        if processed % 50 == 0 {
                            await onProgress?(processed, totalEntries)
                        }
                    }
                    inflight -= 1
                }

                let capturedEntry = entry
                group.addTask {
                    do {
                        let summary = try await parser.parseMetadata(
                            url: capturedEntry.url,
                            sessionId: capturedEntry.sessionId,
                            pricingTable: pricingTable
                        )
                        return (capturedEntry.dirName, summary)
                    } catch {
                        NSLog("[Claudoscope] Scanner: failed to parse %@: %@",
                              capturedEntry.url.path, error.localizedDescription)
                        return nil
                    }
                }
                inflight += 1
            }

            for await result in group {
                if let (dirName, summary) = result {
                    resultsByProject[dirName, default: []].append(summary)
                }
                processed += 1
                if processed % 50 == 0 {
                    await onProgress?(processed, totalEntries)
                }
            }
        }

        await onProgress?(totalEntries, totalEntries)

        for dirName in projectDirSet {
            var sessions = resultsByProject[dirName] ?? []
            if sessions.isEmpty { continue }

            sessions.sort { a, b in
                if a.lastTimestamp.isEmpty && b.lastTimestamp.isEmpty { return false }
                if a.lastTimestamp.isEmpty { return false }
                if b.lastTimestamp.isEmpty { return true }
                return a.lastTimestamp > b.lastTimestamp
            }

            let project = Project(
                id: dirName,
                name: decodeProjectName(dirName),
                path: projectsDir.appendingPathComponent(dirName).path,
                sessionCount: sessions.count
            )

            projects.append(project)
            sessionsByProject[dirName] = sessions
        }

        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (projects, sessionsByProject)
    }
}

/// Decode an encoded project directory name into a human-readable project name.
/// Example: `-Users-liranb-projects-agent-hive` -> `agent-hive`
func decodeProjectName(_ encodedName: String) -> String {
    let segments = encodedName.split(separator: "-", omittingEmptySubsequences: true).map(String.init)

    var startIndex = 0

    // Look for "projects" keyword and take everything after it
    if let projectsIndex = segments.lastIndex(of: "projects"),
       projectsIndex + 1 < segments.count {
        startIndex = projectsIndex + 1
    } else if segments.count > 2,
              segments[0].lowercased() == "users" || segments[0].lowercased() == "home" {
        startIndex = 2
    }

    let meaningful = Array(segments[startIndex...])
    return meaningful.isEmpty ? encodedName : meaningful.joined(separator: "-")
}
