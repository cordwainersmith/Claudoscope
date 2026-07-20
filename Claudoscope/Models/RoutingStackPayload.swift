import Foundation

/// In-memory representation of the agent routing stack bundle: the seven role
/// agent files, the two policy fragments, and the optional settings fragment.
/// Kept as a value type (rather than reading `Bundle.main` directly from the
/// installer/linter) so tests can construct one from inline strings without
/// any bundle dependency.
struct RoutingStackPayload: Sendable {
    enum Group: String, Sendable {
        case core
        case security
    }

    struct AgentFile: Sendable {
        let fileName: String
        let group: Group
        let content: String
    }

    let agentFiles: [AgentFile]
    let policyCoreFragment: String
    let policySecurityFragment: String
    /// `nil` disables the settings payload entirely (checkbox hidden, RTG005 skipped).
    let fallbackModel: [String]?

    var coreFiles: [AgentFile] { agentFiles.filter { $0.group == .core } }
    var securityFiles: [AgentFile] { agentFiles.filter { $0.group == .security } }

    /// Core fragment always; security fragment appended iff `includeSecurity`.
    func policyBody(includeSecurity: Bool) -> String {
        let core = policyCoreFragment.trimmingCharacters(in: .newlines)
        guard includeSecurity else { return core }
        let security = policySecurityFragment.trimmingCharacters(in: .newlines)
        return core + "\n\n" + security
    }

    /// Runtime hash of a payload agent file's content, replacing checksum sidecars.
    func contentHash(forAgent fileName: String) -> String? {
        guard let file = agentFiles.first(where: { $0.fileName == fileName }) else { return nil }
        return InstallerFileOps.sha256(of: file.content)
    }
}

enum RoutingStackPayloadError: Error {
    case resourceMissing(String)
}

enum RoutingStackPayloadLoader {
    static let coreAgentFileNames = ["recon.md", "Explore.md", "routine.md", "builder.md", "checker.md"]
    static let securityAgentFileNames = ["security-review.md", "security-build.md"]

    /// Reads `Bundle.main`. Under `swift test`/`swift run`, `Bundle.main` is the
    /// test/SPM runner binary, so this throws `resourceMissing`; callers treat
    /// that as "payload unavailable" and skip drift-dependent work.
    static func loadFromBundle(subdirectory: String = "RoutingStack") throws -> RoutingStackPayload {
        var agentFiles: [RoutingStackPayload.AgentFile] = []
        let agentsSubdir = "\(subdirectory)/agents"

        for name in coreAgentFileNames {
            let content = try loadText(fileName: name, subdirectory: agentsSubdir)
            agentFiles.append(RoutingStackPayload.AgentFile(fileName: name, group: .core, content: content))
        }
        for name in securityAgentFileNames {
            let content = try loadText(fileName: name, subdirectory: agentsSubdir)
            agentFiles.append(RoutingStackPayload.AgentFile(fileName: name, group: .security, content: content))
        }

        let policyCore = try loadText(fileName: "policy-core.md", subdirectory: subdirectory)
        let policySecurity = try loadText(fileName: "policy-security.md", subdirectory: subdirectory)
        let fallbackModel = loadFallbackModel(subdirectory: subdirectory)

        return RoutingStackPayload(
            agentFiles: agentFiles,
            policyCoreFragment: policyCore,
            policySecurityFragment: policySecurity,
            fallbackModel: fallbackModel
        )
    }

    private static func loadText(fileName: String, subdirectory: String) throws -> String {
        let ns = fileName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: subdirectory) else {
            throw RoutingStackPayloadError.resourceMissing("\(subdirectory)/\(fileName)")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw RoutingStackPayloadError.resourceMissing("\(subdirectory)/\(fileName)")
        }
    }

    /// The settings fragment is optional by design: absence (or a malformed
    /// fragment) simply disables the fallbackModel payload, it never throws.
    private static func loadFallbackModel(subdirectory: String) -> [String]? {
        guard let url = Bundle.main.url(forResource: "settings-fragment", withExtension: "json", subdirectory: subdirectory),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fallback = obj["fallbackModel"] as? [String] else {
            return nil
        }
        return fallback
    }
}
