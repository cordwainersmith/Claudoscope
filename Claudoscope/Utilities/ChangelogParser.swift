import Foundation

enum ChangelogParser {
    /// Parse notes for a specific version from changelog text.
    static func notes(for version: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var capturing = false
        var result: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if capturing {
                    break
                }
                let header = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let bracketed = header
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if bracketed == version {
                    capturing = true
                }
                continue
            }
            if capturing {
                result.append(line)
            }
        }

        let trimmed = result
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Read notes from the bundled CHANGELOG.md for a given version.
    static func bundledNotes(for version: String) -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return notes(for: version, in: text)
    }
}
