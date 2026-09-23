import XCTest
@testable import Claudoscope

/// Claude Code stamps `permissionMode` on type:"permission-mode" records and on
/// human user records (which also carry `gitBranch`). Both change mid-session,
/// so the summary keeps last-wins values plus a sticky ever-bypassed flag that
/// marks a session for its whole life.
final class SessionPermissionModeTests: XCTestCase {

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-permmode-\(UUID().uuidString).jsonl")
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

    private func permissionMode(_ mode: String) -> String {
        "{\"type\":\"permission-mode\",\"permissionMode\":\"\(mode)\",\"sessionId\":\"sess-1\"}"
    }

    private func humanPrompt(uuid: String, ts: String, mode: String, branch: String) -> String {
        "{\"type\":\"user\",\"uuid\":\"\(uuid)\",\"sessionId\":\"sess-1\",\"timestamp\":\"\(ts)\",\"permissionMode\":\"\(mode)\",\"gitBranch\":\"\(branch)\",\"cwd\":\"/Users/x/proj\",\"version\":\"2.1.280\",\"entrypoint\":\"cli\",\"userType\":\"external\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    }

    private let assistant = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-09-23T12:00:01.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"service_tier\":\"standard\"}}}"

    func testBypassThenPlanKeepsStickyFlagAndLastMode() async throws {
        let summary = try await parse([
            permissionMode("bypassPermissions"),
            humanPrompt(uuid: "u1", ts: "2026-09-23T12:00:00.000Z", mode: "bypassPermissions", branch: "master"),
            assistant,
            permissionMode("plan"),
            humanPrompt(uuid: "u2", ts: "2026-09-23T12:05:00.000Z", mode: "plan", branch: "feature/fleet"),
        ])
        XCTAssertEqual(summary.everBypassedPermissions, true)
        XCTAssertEqual(summary.lastPermissionMode, "plan")
        XCTAssertEqual(summary.gitBranch, "feature/fleet")
    }

    func testDefaultModeOnlyIsNotBypass() async throws {
        let summary = try await parse([
            permissionMode("default"),
            humanPrompt(uuid: "u1", ts: "2026-09-23T12:00:00.000Z", mode: "default", branch: "master"),
            assistant,
        ])
        XCTAssertEqual(summary.everBypassedPermissions, false)
        XCTAssertEqual(summary.lastPermissionMode, "default")
        XCTAssertEqual(summary.gitBranch, "master")
    }

    func testNoPermissionRecordsLeavesModeNilButFlagFalse() async throws {
        let summary = try await parse([assistant])
        XCTAssertEqual(summary.everBypassedPermissions, false)
        XCTAssertNil(summary.lastPermissionMode)
        XCTAssertNil(summary.gitBranch)
    }

    func testFullModeDecodesPermissionModeToo() throws {
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = DecodeMode.full
        let raw = try decoder.decode(ParsedRecordRaw.self, from: Data(permissionMode("acceptEdits").utf8))
        XCTAssertEqual(raw.permissionMode, "acceptEdits")
    }
}
