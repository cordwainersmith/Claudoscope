import XCTest
@testable import Claudoscope

final class ParsedRecordToolUseResultTests: XCTestCase {

    private func decode(_ json: String, _ mode: DecodeMode) throws -> ParsedRecordRaw {
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = mode
        return try decoder.decode(ParsedRecordRaw.self, from: Data(json.utf8))
    }

    private let denialLine = """
    {"type":"user","uuid":"u1","timestamp":"2026-09-23T12:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"The user doesn't want to proceed","is_error":true}]},"toolUseResult":"Error: The user doesn't want to proceed with this tool use. The tool use was rejected."}
    """

    func testBareStringToolUseResultDecodesInBothModes() throws {
        for mode in [DecodeMode.lite, DecodeMode.full] {
            let raw = try decode(denialLine, mode)
            XCTAssertEqual(raw.type, .user)
            XCTAssertEqual(raw.toolUseResult?.isBareString, true)
            XCTAssertEqual(raw.toolUseResult?.content,
                           "Error: The user doesn't want to proceed with this tool use. The tool use was rejected.")
            XCTAssertNil(raw.toolUseResult?.filePath)
            XCTAssertEqual(raw.toolUseResult?.hasStructuredPatch, false)
        }
    }

    func testObjectShapeReadsFilePathAndStructuredPatch() throws {
        let json = """
        {"type":"user","uuid":"u2","timestamp":"2026-09-23T12:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]},"toolUseResult":{"filePath":"/x/a.swift","oldString":"a","newString":"b","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-a","+b"]}]}}
        """
        for mode in [DecodeMode.lite, DecodeMode.full] {
            let result = try decode(json, mode).toolUseResult
            XCTAssertEqual(result?.isBareString, false)
            XCTAssertEqual(result?.filePath, "/x/a.swift")
            XCTAssertEqual(result?.hasStructuredPatch, true)
        }
    }

    func testAgentResultWithBlockContentKeepsSpawnEdge() throws {
        let json = """
        {"type":"user","uuid":"u3","timestamp":"2026-09-23T12:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"done"}]},"toolUseResult":{"status":"completed","agentId":"abc123","content":[{"type":"text","text":"done"}]}}
        """
        let result = try decode(json, .lite).toolUseResult
        XCTAssertEqual(result?.childAgentId, "abc123")
        XCTAssertNil(result?.content)
    }

    func testArrayShapeDecodesAsEmptyResult() throws {
        let json = """
        {"type":"user","uuid":"u4","timestamp":"2026-09-23T12:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t4","content":"x"}]},"toolUseResult":[{"type":"text","text":"x"}]}
        """
        let result = try decode(json, .lite).toolUseResult
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.isBareString, false)
        XCTAssertNil(result?.childAgentId)
    }
}
