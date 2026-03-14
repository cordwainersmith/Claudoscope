import Foundation

/// Scans ~/.claude/plans/ for markdown plan files and reads their content.
actor PlansService {
    private let plansDir: URL

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.plansDir = claudeDir.appendingPathComponent("plans")
    }

    /// Load all plan summaries, sorted by creation date descending.
    func loadPlans() async -> [PlanSummary] {
        let fm = FileManager.default

        guard let fileNames = try? fm.contentsOfDirectory(atPath: plansDir.path) else {
            return []
        }

        let mdFiles = fileNames.filter { $0.hasSuffix(".md") }
        var plans: [PlanSummary] = []

        for fileName in mdFiles {
            let fileURL = plansDir.appendingPathComponent(fileName)

            // Read file attributes
            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
            let createdAt = attrs?[.creationDate] as? Date
            let sizeBytes = (attrs?[.size] as? Int) ?? 0

            // Extract title from first # heading
            let title = extractTitle(from: fileURL) ?? fileName

            // Extract project hint from title pattern "projectname — ..."
            let projectHint = extractProjectHint(from: title)

            plans.append(PlanSummary(
                filename: fileName,
                title: title,
                projectHint: projectHint,
                createdAt: createdAt,
                sizeBytes: sizeBytes
            ))
        }

        // Sort by creation date descending (newest first), nil dates go last
        plans.sort { a, b in
            switch (a.createdAt, b.createdAt) {
            case let (dateA?, dateB?):
                return dateA > dateB
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.filename < b.filename
            }
        }

        return plans
    }

    /// Load the full content of a specific plan file.
    func loadPlanDetail(filename: String) async -> PlanDetail? {
        // Prevent path traversal
        guard !filename.contains("/"), !filename.contains("..") else {
            return nil
        }

        let fileURL = plansDir.appendingPathComponent(filename)

        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let title = extractTitleFromContent(content) ?? filename

        return PlanDetail(
            filename: filename,
            title: title,
            content: content
        )
    }

    // MARK: - Private Helpers

    /// Read just enough of a file to find the first # heading.
    private func extractTitle(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        return extractTitleFromContent(content)
    }

    /// Extract the first `# ` heading from markdown content.
    private func extractTitleFromContent(_ content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    return title
                }
            }
        }
        return nil
    }

    /// Extract a project hint from a title that follows the pattern "projectname — rest".
    /// Also handles " - " as a separator.
    private func extractProjectHint(from title: String) -> String? {
        // Try em-dash separator first
        if let range = title.range(of: " \u{2014} ") {
            let project = String(title[title.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !project.isEmpty { return project }
        }

        // Try en-dash separator
        if let range = title.range(of: " \u{2013} ") {
            let project = String(title[title.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !project.isEmpty { return project }
        }

        return nil
    }
}
