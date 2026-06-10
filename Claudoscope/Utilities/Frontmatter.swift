import Foundation

/// Parse a markdown file with YAML-ish frontmatter (SKILL.md, agent/command .md),
/// extracting `name` / `description`, the remaining frontmatter as `metadata`, and
/// the body content. Shared by `ConfigService` (skills loading) and the Plugins
/// rail drill-down so both render frontmatter identically.
func parseFrontmatter(_ content: String) -> (name: String?, description: String?, metadata: [String: String], body: String) {
    let lines = content.components(separatedBy: "\n")
    var name: String?
    var description: String?
    var metadata: [String: String] = [:]
    var bodyStartIndex = 0
    var inFrontmatter = true
    var currentKey: String?
    var currentValue: String?

    func flushCurrentKey() {
        if let key = currentKey, let value = currentValue {
            let trimmedValue = value.trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": name = trimmedValue
            case "description": description = trimmedValue
            default: metadata[key] = trimmedValue
            }
        }
        currentKey = nil
        currentValue = nil
    }

    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard inFrontmatter else { break }

        // End-of-frontmatter marker
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

        // Check for "key: value" pattern (key must start at column 0 or be a simple word)
        if let colonRange = trimmed.range(of: ":"),
           colonRange.lowerBound != trimmed.startIndex {
            let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            // Only treat as frontmatter if key is a simple identifier (no spaces, no markdown)
            if !key.isEmpty && key.range(of: "^[a-zA-Z_][a-zA-Z0-9_-]*$", options: .regularExpression) != nil {
                flushCurrentKey()
                let value = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                currentKey = key
                currentValue = value
                bodyStartIndex = index + 1
                continue
            }
        }

        // Indented continuation of previous value (for multi-line args, etc.)
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
