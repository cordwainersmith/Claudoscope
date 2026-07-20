import Foundation

/// Parse a markdown file with YAML-ish frontmatter (SKILL.md, agent/command .md),
/// extracting `name` / `description`, the remaining frontmatter as `metadata`, and
/// the body content. Shared by `ConfigService` (skills/agents loading) and the
/// Plugins rail drill-down so all render frontmatter identically.
///
/// Two shapes are supported:
///   1. Fenced: the file starts with a `---` line; frontmatter runs until the next
///      `---` (or EOF). This is the standard shape for every skill and agent file.
///   2. Fence-less: leading `key: value` lines with no fences, terminated by a
///      blank line or the first non-matching line. Kept for the Plugins drill-down,
///      which parses arbitrary component files.
func parseFrontmatter(_ content: String) -> (name: String?, description: String?, metadata: [String: String], body: String) {
    let lines = content.components(separatedBy: "\n")

    // A leading `---` (possibly after blank lines) means the file is fenced.
    var openerIndex: Int?
    for (i, line) in lines.enumerated() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        if t == "---" { openerIndex = i }
        break
    }

    if let opener = openerIndex {
        return parseFenced(lines, openerIndex: opener)
    }
    return parseFenceless(lines)
}

// MARK: - Fenced

private func parseFenced(_ lines: [String], openerIndex: Int) -> (name: String?, description: String?, metadata: [String: String], body: String) {
    var name: String?
    var description: String?
    var metadata: [String: String] = [:]
    var currentKey: String?
    var currentValue: String?
    var bodyStartIndex = lines.count   // no body until the closer is found
    var closed = false

    func flushCurrentKey() {
        if let key = currentKey, let value = currentValue {
            let folded = foldFrontmatterValue(value)
            switch key {
            case "name": name = folded
            case "description": description = folded
            default: metadata[key] = folded
            }
        }
        currentKey = nil
        currentValue = nil
    }

    var index = openerIndex + 1
    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Closing fence ends the frontmatter; body starts after it.
        if trimmed == "---" {
            flushCurrentKey()
            bodyStartIndex = index + 1
            closed = true
            break
        }

        // Blank line inside a fenced block does NOT terminate; keep it as part of
        // the current value (a paragraph break in a folded scalar).
        if trimmed.isEmpty {
            if currentKey != nil {
                currentValue = (currentValue ?? "") + "\n"
            }
            index += 1
            continue
        }

        // "key: value" at the start of a line begins a new key.
        if let colonRange = trimmed.range(of: ":"),
           colonRange.lowerBound != trimmed.startIndex {
            let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && key.range(of: "^[a-zA-Z_][a-zA-Z0-9_-]*$", options: .regularExpression) != nil {
                flushCurrentKey()
                currentKey = key
                currentValue = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                index += 1
                continue
            }
        }

        // Anything else is a continuation of the current value (multi-line lists,
        // folded scalars, nested `- name:` items that aren't simple keys).
        if currentKey != nil {
            currentValue = (currentValue ?? "") + "\n" + trimmed
        }
        index += 1
    }

    // Unterminated frontmatter: treat the whole remainder as frontmatter, no body.
    if !closed {
        flushCurrentKey()
        bodyStartIndex = lines.count
    }

    let body = bodyStartIndex < lines.count
        ? lines[bodyStartIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        : ""
    return (name, description, metadata, body)
}

// MARK: - Fence-less (legacy shape, unchanged behavior)

private func parseFenceless(_ lines: [String]) -> (name: String?, description: String?, metadata: [String: String], body: String) {
    var name: String?
    var description: String?
    var metadata: [String: String] = [:]
    var bodyStartIndex = 0
    var inFrontmatter = true
    var currentKey: String?
    var currentValue: String?

    func flushCurrentKey() {
        if let key = currentKey, let value = currentValue {
            let folded = foldFrontmatterValue(value)
            switch key {
            case "name": name = folded
            case "description": description = folded
            default: metadata[key] = folded
            }
        }
        currentKey = nil
        currentValue = nil
    }

    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard inFrontmatter else { break }

        // A `---` terminator ends frontmatter (e.g. content whose opening fence
        // was already stripped by a caller, leaving a trailing closing fence).
        if trimmed == "---" {
            flushCurrentKey()
            bodyStartIndex = index + 1
            inFrontmatter = false
            continue
        }

        // Empty line ends frontmatter
        if trimmed.isEmpty {
            flushCurrentKey()
            bodyStartIndex = index + 1
            inFrontmatter = false
            continue
        }

        // "key: value" pattern
        if let colonRange = trimmed.range(of: ":"),
           colonRange.lowerBound != trimmed.startIndex {
            let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && key.range(of: "^[a-zA-Z_][a-zA-Z0-9_-]*$", options: .regularExpression) != nil {
                flushCurrentKey()
                let value = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                currentKey = key
                currentValue = value
                bodyStartIndex = index + 1
                continue
            }
        }

        // Indented continuation of previous value
        if currentKey != nil && (line.hasPrefix("  ") || line.hasPrefix("\t")) {
            currentValue = (currentValue ?? "") + "\n" + trimmed
            bodyStartIndex = index + 1
            continue
        }

        // Line doesn't match frontmatter pattern, start body here
        flushCurrentKey()
        inFrontmatter = false
        bodyStartIndex = index
    }

    flushCurrentKey()

    let bodyLines = Array(lines[bodyStartIndex...])
    let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (name, description, metadata, body)
}

// MARK: - Block scalar folding

/// Collapse a YAML block-scalar value (`>`, `|`, and their `-`/`+` chomping
/// variants) into a display string: folded (`>`) joins continuation lines with
/// spaces, literal (`|`) with newlines, and the sigil is stripped. Non-sigil
/// values (inline strings, `- item` lists) are returned trimmed and unchanged so
/// downstream `parseToolList` still sees the raw list form.
private func foldFrontmatterValue(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.components(separatedBy: "\n")
    guard let first = parts.first?.trimmingCharacters(in: .whitespaces) else { return trimmed }

    let literalSigils: Set<String> = ["|", "|-", "|+"]
    let foldedSigils: Set<String> = [">", ">-", ">+"]
    guard literalSigils.contains(first) || foldedSigils.contains(first) else { return trimmed }

    let rest = parts.dropFirst()
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let separator = foldedSigils.contains(first) ? " " : "\n"
    return rest.joined(separator: separator)
}
