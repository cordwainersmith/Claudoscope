import XCTest
@testable import Claudoscope

/// Context-window sizing and the per-turn occupancy series behind the Context tab.
final class ContextWindowTests: XCTestCase {

    // MARK: - Window sizing

    func testLegacyModelsGetTheStandardWindow() {
        for model in [
            "claude-3-opus-20240229", "claude-3-5-haiku-20241022",
            "claude-opus-4-1", "claude-opus-4-5-20251101",
            "claude-sonnet-4-5", "claude-haiku-4-5-20251001",
        ] {
            XCTAssertEqual(ContextWindow.tokens(for: model), ContextWindow.standard, model)
        }
    }

    func testCurrentModelsGetTheExtendedWindow() {
        for model in [
            "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
            "claude-opus-5", "claude-opus-5[1m]",
            "claude-sonnet-4-6", "claude-sonnet-5",
            "claude-fable-5", "claude-mythos-5",
        ] {
            XCTAssertEqual(ContextWindow.tokens(for: model), ContextWindow.extended, model)
        }
    }

    /// Every model since Claude 4.6 has a 1M window, so an unrecognized id is far
    /// more likely to be 1M. Guessing 200K would draw healthy sessions as overflowing.
    func testUnrecognizedModelGetsTheExtendedWindow() {
        XCTAssertEqual(ContextWindow.tokens(for: "claude-zzz-9"), ContextWindow.extended)
        XCTAssertEqual(ContextWindow.tokens(for: nil), ContextWindow.extended)
    }

    // MARK: - Occupancy series

    private func assistant(
        uuid: String, msgId: String, ts: String,
        input: Int = 1000, cacheRead: Int = 0, cacheCreate: Int = 0,
        stopReason: String? = "end_turn",
        model: String = "claude-opus-5"
    ) -> String {
        let stop = stopReason.map { "\"\($0)\"" } ?? "null"
        return "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"sessionId\":\"s\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"id\":\"\(msgId)\",\"stop_reason\":\(stop),\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"cache_read_input_tokens\":\(cacheRead),\"cache_creation_input_tokens\":\(cacheCreate),\"output_tokens\":10,\"service_tier\":\"standard\"}}}"
    }

    private func records(_ lines: [String]) throws -> [ParsedRecordRaw] {
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = DecodeMode.full
        return try lines.map { try decoder.decode(ParsedRecordRaw.self, from: Data($0.utf8)) }
    }

    /// Context is the whole prompt the model read: fresh input plus everything
    /// served from or written to cache. Output is what it produced afterwards and
    /// is not occupying the window when the turn starts.
    func testContextSumsInputAndBothCacheKinds() throws {
        let series = ContextPressurePoint.series(for: try records([
            assistant(uuid: "u1", msgId: "m1", ts: "2026-08-05T12:00:00.000Z",
                      input: 1000, cacheRead: 50_000, cacheCreate: 4_000)
        ]))
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].contextTokens, 55_000)
        XCTAssertEqual(series[0].windowTokens, ContextWindow.extended)
        XCTAssertEqual(series[0].utilization, 0.055, accuracy: 1e-9)
    }

    /// Streaming intermediates carry partial cumulative usage; including them would
    /// saw-tooth the curve between the partial and the final value for one turn.
    func testStreamingIntermediatesAreExcluded() throws {
        let series = ContextPressurePoint.series(for: try records([
            assistant(uuid: "u1", msgId: "m1", ts: "2026-08-05T12:00:00.000Z", input: 400, stopReason: nil),
            assistant(uuid: "u2", msgId: "m1", ts: "2026-08-05T12:00:01.000Z", input: 1000),
        ]))
        XCTAssertEqual(series.map(\.contextTokens), [1000])
    }

    /// A resumed or continued file replays message ids; a duplicate would draw a
    /// flat spur where no new turn happened.
    func testDuplicateMessageIdsCountOnce() throws {
        let series = ContextPressurePoint.series(for: try records([
            assistant(uuid: "u1", msgId: "m1", ts: "2026-08-05T12:00:00.000Z", input: 1000),
            assistant(uuid: "u2", msgId: "m1", ts: "2026-08-05T12:00:05.000Z", input: 1000),
            assistant(uuid: "u3", msgId: "m2", ts: "2026-08-05T12:00:10.000Z", input: 2000),
        ]))
        XCTAssertEqual(series.map(\.contextTokens), [1000, 2000])
    }

    func testWindowFollowsTheTurnsOwnModel() throws {
        let series = ContextPressurePoint.series(for: try records([
            assistant(uuid: "u1", msgId: "m1", ts: "2026-08-05T12:00:00.000Z", model: "claude-sonnet-4-5"),
            assistant(uuid: "u2", msgId: "m2", ts: "2026-08-05T12:01:00.000Z", model: "claude-opus-5"),
        ]))
        XCTAssertEqual(series.map(\.windowTokens), [ContextWindow.standard, ContextWindow.extended])
    }

    func testSessionWithNoBilledTurnsProducesNoSeries() throws {
        let series = ContextPressurePoint.series(for: try records([
            assistant(uuid: "u1", msgId: "m1", ts: "2026-08-05T12:00:00.000Z", stopReason: nil)
        ]))
        XCTAssertTrue(series.isEmpty)
    }
}
