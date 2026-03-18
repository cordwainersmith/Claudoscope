import Foundation

struct ChangelogEntry {
    let version: String
    let notes: String

    var releaseURL: URL? {
        URL(string: "https://github.com/cordwainersmith/Claudoscope/releases/tag/v\(version)")
    }
}

enum ChangelogParser {
    private static let rawURL = URL(string:
        "https://raw.githubusercontent.com/cordwainersmith/Claudoscope/master/CHANGELOG.md"
    )!

    /// Fetch CHANGELOG.md from GitHub and parse all entries.
    static func fetchEntries() async -> [ChangelogEntry] {
        do {
            let (data, response) = try await URLSession.shared.data(from: rawURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else {
                return []
            }
            return allEntries(in: text)
        } catch {
            return []
        }
    }

    /// Parse all version entries from changelog text.
    static func allEntries(in text: String) -> [ChangelogEntry] {
        let lines = text.components(separatedBy: .newlines)
        var entries: [ChangelogEntry] = []
        var currentVersion: String?
        var currentLines: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if let version = currentVersion {
                    let notes = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !notes.isEmpty {
                        entries.append(ChangelogEntry(version: version, notes: notes))
                    }
                }
                let header = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                currentVersion = header.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                currentLines = []
            } else if currentVersion != nil {
                currentLines.append(line)
            }
        }

        if let version = currentVersion {
            let notes = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty {
                entries.append(ChangelogEntry(version: version, notes: notes))
            }
        }

        return entries
    }
}
