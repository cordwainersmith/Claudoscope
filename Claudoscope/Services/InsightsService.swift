import Foundation

/// Reads the facet and session-meta JSON that Claude Code's /insights writes
/// under ~/.claude/usage-data/. Coverage is typically sparse (a batch exists
/// only after the user runs /insights), so empty dirs are the normal case.
actor InsightsService {
    private let facetsDir: URL
    private let metaDir: URL

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        let usageData = claudeDir.appendingPathComponent("usage-data")
        self.facetsDir = usageData.appendingPathComponent("facets")
        self.metaDir = usageData.appendingPathComponent("session-meta")
    }

    /// All decodable facet files with their mtime (for the coverage banner).
    func loadFacets() async -> [(facet: SessionFacet, fileDate: Date?)] {
        let fm = FileManager.default
        guard let fileNames = try? fm.contentsOfDirectory(atPath: facetsDir.path) else {
            return []
        }

        let decoder = JSONDecoder()
        var facets: [(facet: SessionFacet, fileDate: Date?)] = []
        for fileName in fileNames where fileName.hasSuffix(".json") {
            let url = facetsDir.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let facet = try? decoder.decode(SessionFacet.self, from: data) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            facets.append((facet, attrs?[.modificationDate] as? Date))
        }
        return facets
    }

    /// Session-meta files for the given ids only (ids come from loadFacets,
    /// so this stays bounded by the facet count).
    func loadMeta(sessionIds: Set<String>) async -> [String: SessionMetaFacet] {
        let decoder = JSONDecoder()
        var meta: [String: SessionMetaFacet] = [:]
        for id in sessionIds {
            guard !id.contains("/"), !id.contains("..") else { continue }
            let url = metaDir.appendingPathComponent(id + ".json")
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? decoder.decode(SessionMetaFacet.self, from: data) else { continue }
            meta[id] = decoded
        }
        return meta
    }
}
