import XCTest
@testable import Claudoscope

final class ClaudeCliLocatorTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-locator-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeExecutable(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testPicksFirstExecutableCandidate() throws {
        let first = try makeExecutable("claude-first")
        let second = try makeExecutable("claude-second")
        let located = ClaudeCliLocator.locate(candidates: [
            dir.appendingPathComponent("missing"),
            first,
            second,
        ])
        XCTAssertEqual(located, first)
    }

    func testSkipsNonExecutableFiles() throws {
        let plain = dir.appendingPathComponent("claude-plain")
        try Data("not executable".utf8).write(to: plain)
        let real = try makeExecutable("claude-real")
        let located = ClaudeCliLocator.locate(candidates: [plain, real])
        XCTAssertEqual(located, real)
    }
}

final class McpServerConfigTests: XCTestCase {
    func testDecodesEmptyObjectToDefaults() throws {
        let decoded = try JSONDecoder().decode(McpServerConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .default)
        XCTAssertFalse(decoded.enabled)
    }

    func testDecodeIgnoresUnknownKeysForwardCompatibly() throws {
        let json = "{\"enabled\":true,\"futureKnob\":\"x\"}"
        let decoded = try JSONDecoder().decode(McpServerConfig.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.enabled)
    }

    func testRoundTrip() throws {
        let config = McpServerConfig(enabled: true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(McpServerConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }
}
