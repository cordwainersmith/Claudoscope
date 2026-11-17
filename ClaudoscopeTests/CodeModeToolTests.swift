import XCTest
@testable import Claudoscope

final class CodeModeToolTests: XCTestCase {

    private func liteToolTarget(_ json: String) throws -> String? {
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = DecodeMode.lite
        let raw = try decoder.decode(ParsedRecordRaw.self, from: Data(json.utf8))
        guard case .blocks(let blocks) = raw.message?.content else {
            XCTFail("expected blocks content")
            return nil
        }
        return blocks.first { $0.type == "tool_use" }?.toolTarget
    }

    func testReplIsAnExecTool() {
        XCTAssertEqual(toolCategory(for: "REPL"), .exec)
    }

    func testReplIconAndPrimaryArgumentUseFirstCodeLine() {
        XCTAssertEqual(toolIcon(for: "REPL"), "curlybraces")
        let input: [String: AnyCodableValue] = ["code": .string("  const files = await glob('*.swift')\nreturn files.length")]
        XCTAssertEqual(primaryArgument(from: input, toolName: "REPL"), "const files = await glob('*.swift')")
    }

    func testReplPrimaryArgumentSkipsLeadingBlankLines() {
        let input: [String: AnyCodableValue] = ["code": .string("\n   \n\tlet x = 1\nlet y = 2")]
        XCTAssertEqual(primaryArgument(from: input, toolName: "REPL"), "let x = 1")
    }

    func testLiteDecodeTakesCodeAsToolTarget() throws {
        let json = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"REPL","input":{"code":"print(1)\\nprint(2)"}}]}}
        """
        XCTAssertEqual(try liteToolTarget(json), "print(1)\nprint(2)")
    }

    func testCodeKeyDoesNotOverrideEarlierTargetKeys() throws {
        let json = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"REPL","input":{"code":"print(1)","command":"ls -la"}}]}}
        """
        XCTAssertEqual(try liteToolTarget(json), "ls -la")
    }
}
