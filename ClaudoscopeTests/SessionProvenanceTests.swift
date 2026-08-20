import XCTest
@testable import Claudoscope

/// Claude Code writes four top-level provenance records the parser used to skip:
/// `ai-title` (its own generated session name), `worktree-state` and `relocated`
/// (where the session's checkout lives), and `pr-link` (the PR or GitLab MR it
/// opened). They are metadata about the session, not conversation, so they decode
/// in lite mode and land on SessionSummary.
final class SessionProvenanceTests: XCTestCase {

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-provenance-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func parse(_ lines: [String]) async throws -> SessionSummary {
        let url = try writeTempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await SessionParser().parseMetadata(
            url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic
        )
    }

    private let assistant = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-08-05T12:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":100,\"output_tokens\":200,\"service_tier\":\"standard\"}}}"

    private let worktreeState = "{\"type\":\"worktree-state\",\"worktreeSession\":{\"originalCwd\":\"/Users/x/proj\",\"worktreePath\":\"/Users/x/proj/.claude/worktrees/fix-login\",\"worktreeName\":\"fix-login\",\"worktreeBranch\":\"worktree-fix-login\",\"originalBranch\":\"master\",\"sessionId\":\"sess-1\"}}"

    private let prLink = "{\"type\":\"pr-link\",\"sessionId\":\"sess-1\",\"prNumber\":42,\"prUrl\":\"https://github.com/o/r/pull/42\",\"prRepository\":\"o/r\",\"timestamp\":\"2026-08-05T13:00:00.000Z\"}"

    private let aiTitle = "{\"type\":\"ai-title\",\"aiTitle\":\"fix-login-button\",\"sessionId\":\"sess-1\"}"

    // MARK: - Worktree

    func testWorktreeStateLandsOnSummary() async throws {
        let s = try await parse([assistant, worktreeState])
        XCTAssertEqual(s.worktreeName, "fix-login")
        XCTAssertEqual(s.worktreeBranch, "worktree-fix-login")
    }

    func testOrdinarySessionHasNoWorktree() async throws {
        let s = try await parse([assistant])
        XCTAssertNil(s.worktreeName)
        XCTAssertNil(s.worktreeBranch)
    }

    // MARK: - PR link

    func testPrLinkLandsOnSummary() async throws {
        let s = try await parse([assistant, prLink])
        XCTAssertEqual(s.prNumber, 42)
        XCTAssertEqual(s.prUrl, "https://github.com/o/r/pull/42")
    }

    /// A re-pushed branch restamps the link, so the last record wins.
    func testLastPrLinkWins() async throws {
        let second = prLink
            .replacingOccurrences(of: "\"prNumber\":42", with: "\"prNumber\":43")
            .replacingOccurrences(of: "pull/42", with: "pull/43")
        let s = try await parse([assistant, prLink, second])
        XCTAssertEqual(s.prNumber, 43)
        XCTAssertEqual(s.prUrl, "https://github.com/o/r/pull/43")
    }

    // MARK: - Title precedence

    func testAiTitleBeatsSlug() async throws {
        let withSlug = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"slug\":\"stale-slug\",\"timestamp\":\"2026-08-05T12:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":100,\"output_tokens\":200,\"service_tier\":\"standard\"}}}"
        let s = try await parse([withSlug, aiTitle])
        XCTAssertEqual(s.title, "fix-login-button")
    }

    /// A /rename is the user's explicit choice and outranks the generated name,
    /// whichever order the records appear in.
    func testCustomTitleBeatsAiTitle() async throws {
        let renamed = "{\"type\":\"custom-title\",\"customTitle\":\"my name for it\",\"sessionId\":\"sess-1\"}"
        let s = try await parse([assistant, aiTitle, renamed])
        XCTAssertEqual(s.title, "my name for it")
    }

    func testAiTitleUsedWhenNothingElseIsSet() async throws {
        let s = try await parse([assistant, aiTitle])
        XCTAssertEqual(s.title, "fix-login-button")
    }

    // MARK: - Regression

    /// Provenance records carry no usage, so they must not shift billing or counts.
    func testProvenanceRecordsDoNotAffectBilling() async throws {
        let plain = try await parse([assistant])
        let stamped = try await parse([assistant, worktreeState, prLink, aiTitle])
        XCTAssertEqual(stamped.estimatedCost, plain.estimatedCost, accuracy: 1e-12)
        XCTAssertEqual(stamped.totalInputTokens, plain.totalInputTokens)
        XCTAssertEqual(stamped.totalOutputTokens, plain.totalOutputTokens)
    }
}
