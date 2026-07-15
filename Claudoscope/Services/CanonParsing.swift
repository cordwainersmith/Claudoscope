import Foundation

/// Pure parsing of a project's `.claude/canon.md` into structured records, plus
/// the derived checks the Canon rail banner and the CAN lint family both use.
/// No I/O here — callers read the file and pass the text in — so it is trivially
/// unit-testable and shared by the loader (ConfigService+Canon) and the linter
/// (ConfigLinterService+Canon).
enum CanonParsing {

    /// Split the data file into `## Title` records. Everything before the first
    /// record heading (the `# Canon` title + intro) is ignored. Fenced code
    /// blocks are tracked so a `##` line inside a body fence never starts a
    /// spurious record.
    static func parseCanonRecords(_ markdown: String) -> [CanonRecord] {
        let lines = markdown.components(separatedBy: "\n")
        var records: [CanonRecord] = []

        var inFence = false
        var currentTitle: String?
        var currentLines: [String] = []
        var index = 0

        func flush() {
            guard let title = currentTitle else { return }
            records.append(makeRecord(index: index, title: title, contentLines: currentLines))
            index += 1
            currentTitle = nil
            currentLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                if currentTitle != nil { currentLines.append(line) }
                continue
            }

            if !inFence && line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if currentTitle != nil {
                currentLines.append(line)
            }
        }
        flush()

        return records
    }

    private static func makeRecord(index: Int, title: String, contentLines: [String]) -> CanonRecord {
        // The metadata line is the first non-blank content line. The protocol
        // places it immediately after the heading; we tolerate blank lines.
        var metaIndex: Int?
        for (i, line) in contentLines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            metaIndex = i
            break
        }

        let metaLine = metaIndex.map { contentLines[$0] } ?? ""
        let looksLikeMeta = metaLine.contains("kind:") || metaLine.contains("status:")

        var kind: CanonKind?
        var dateString: String?
        var status: CanonStatus = .unknown("")
        var rawStatus: String?
        var hasMetadataLine = false

        if looksLikeMeta, let mi = metaIndex {
            hasMetadataLine = true
            let parsed = parseMetadataLine(contentLines[mi])
            kind = parsed.kind
            dateString = parsed.date
            status = parsed.status
            rawStatus = parsed.rawStatus
        }

        let bodyStart = hasMetadataLine ? (metaIndex! + 1) : 0
        let bodyLines = bodyStart < contentLines.count ? Array(contentLines[bodyStart...]) : []
        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CanonRecord(
            id: "\(index)-\(title)",
            title: title,
            kind: kind,
            dateString: dateString,
            status: status,
            body: body,
            hasMetadataLine: hasMetadataLine,
            rawStatusString: rawStatus
        )
    }

    private static func parseMetadataLine(
        _ line: String
    ) -> (kind: CanonKind?, date: String?, status: CanonStatus, rawStatus: String?) {
        var kind: CanonKind?
        var date: String?
        var statusRaw: String?

        for segment in line.components(separatedBy: " | ") {
            guard let colon = segment.firstIndex(of: ":") else { continue }
            let key = segment[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = segment[segment.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "kind":   kind = CanonKind(rawValue: value.lowercased())
            case "date":   date = value.isEmpty ? nil : value
            case "status": statusRaw = value
            default:       break
            }
        }

        return (kind, date, parseStatus(statusRaw), statusRaw)
    }

    private static func parseStatus(_ raw: String?) -> CanonStatus {
        guard let raw, !raw.isEmpty else { return .unknown("") }
        let lower = raw.lowercased()
        if lower == "canon" { return .canon }
        if let r = lower.range(of: "superseded by:") {
            // Recompute the target from the original-case string at the same offset.
            let offset = lower.distance(from: lower.startIndex, to: r.upperBound)
            let target = String(raw.dropFirst(offset))
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
            return target.isEmpty ? .nonCanonNoPointer : .superseded(by: target)
        }
        if lower.hasPrefix("non-canon") { return .nonCanonNoPointer }
        return .unknown(raw)
    }

    /// Records missing a metadata line, or with an unrecognized kind/status.
    /// Drives CAN003.
    static func malformedRecords(_ records: [CanonRecord]) -> [CanonRecord] {
        records.filter { rec in
            if !rec.hasMetadataLine { return true }
            if rec.kind == nil { return true }
            if case .unknown = rec.status { return true }
            return false
        }
    }

    /// Supersede pointers that don't resolve. `missingTitle` is the unresolved
    /// target for a `superseded by:` that names a nonexistent record, or nil for
    /// a `non-canon` record with no pointer at all. Drives CAN005.
    static func danglingSupersedes(_ records: [CanonRecord]) -> [(record: CanonRecord, missingTitle: String?)] {
        let titles = Set(records.map(\.title))
        var out: [(record: CanonRecord, missingTitle: String?)] = []
        for rec in records {
            switch rec.status {
            case .superseded(let target):
                if !titles.contains(target) { out.append((rec, target)) }
            case .nonCanonNoPointer:
                out.append((rec, nil))
            default:
                break
            }
        }
        return out
    }

    /// Read the version from the installed protocol's marker
    /// (`<!-- claudoscope-canon: vN -->`). nil when absent or unmarked.
    static func parseProtocolVersion(_ ruleText: String) -> Int? {
        guard let r = ruleText.range(of: "claudoscope-canon: v") else { return nil }
        let digits = ruleText[r.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits)
    }
}

/// Thin wrapper over `git check-ignore` used to answer "will the canon records
/// actually get committed?" for CAN002. Fails open (returns nil) when the
/// project isn't a git repo or git can't be run, so the check never produces a
/// false warning.
enum CanonGit {
    static func isPathGitignored(projectRoot: String, path: String) -> Bool? {
        let gitDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "-C", projectRoot, "check-ignore", "-q", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        switch proc.terminationStatus {
        case 0:  return true
        case 1:  return false
        default: return nil
        }
    }
}
