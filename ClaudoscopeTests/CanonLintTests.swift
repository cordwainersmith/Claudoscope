import XCTest
@testable import Claudoscope

final class CanonLintTests: XCTestCase {
    var tempDir: URL!
    var linter: ConfigLinterService!

    let validRecords = """
    # Canon

    ## A decision
    kind: choice | date: 2026-07-15 | status: canon
    Body. Because: reasons.
    """

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CanonLintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        linter = ConfigLinterService()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func write(_ text: String, to relativePath: String) throws {
        let url = tempDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func ids(_ results: [LintResult]) -> Set<LintCheckId> {
        Set(results.map(\.checkId))
    }

    func testMissingProtocolFiresCAN001() async throws {
        try write(validRecords, to: ".claude/canon.md")
        let results = await linter.lintCanon(projectRoot: tempDir.path, bundledProtocolVersion: 1)
        XCTAssertTrue(ids(results).contains(.CAN001))
        XCTAssertEqual(results.first { $0.checkId == .CAN001 }?.severity, .error)
    }

    func testCurrentInstallIsClean() async throws {
        try write("<!-- claudoscope-canon: v1 -->\n# Project Canon\n", to: ".claude/rules/canon.md")
        try write(validRecords, to: ".claude/canon.md")
        let results = await linter.lintCanon(projectRoot: tempDir.path, bundledProtocolVersion: 1)
        // Non-git temp dir => CAN002 fails open; everything else passes.
        XCTAssertTrue(results.isEmpty, "expected no findings, got \(ids(results))")
    }

    func testOutdatedProtocolFiresCAN004() async throws {
        try write("# Project Canon\n(no version marker)\n", to: ".claude/rules/canon.md")
        try write(validRecords, to: ".claude/canon.md")
        let results = await linter.lintCanon(projectRoot: tempDir.path, bundledProtocolVersion: 1)
        XCTAssertTrue(ids(results).contains(.CAN004))
        XCTAssertFalse(ids(results).contains(.CAN001))
        XCTAssertEqual(results.first { $0.checkId == .CAN004 }?.severity, .info)
    }

    func testMalformedRecordFiresCAN003() async throws {
        try write("<!-- claudoscope-canon: v1 -->\n", to: ".claude/rules/canon.md")
        let bad = """
        # Canon

        ## Broken
        this record has no metadata line
        """
        try write(bad, to: ".claude/canon.md")
        let results = await linter.lintCanon(projectRoot: tempDir.path, bundledProtocolVersion: 1)
        XCTAssertTrue(ids(results).contains(.CAN003))
        XCTAssertEqual(results.first { $0.checkId == .CAN003 }?.severity, .warning)
    }

    func testDanglingSupersedeFiresCAN005() async throws {
        try write("<!-- claudoscope-canon: v1 -->\n", to: ".claude/rules/canon.md")
        let dangling = """
        # Canon

        ## Retired
        kind: choice | date: 2026-07-01 | status: non-canon, superseded by: Ghost record
        gone
        """
        try write(dangling, to: ".claude/canon.md")
        let results = await linter.lintCanon(projectRoot: tempDir.path, bundledProtocolVersion: 1)
        XCTAssertTrue(ids(results).contains(.CAN005))
        XCTAssertEqual(results.first { $0.checkId == .CAN005 }?.severity, .info)
    }

    func testGitignoredRecordsFiresCAN002() async throws {
        // A real git repo whose .gitignore hides .claude/.
        guard runGit(["init"]) else {
            throw XCTSkip("git not available")
        }
        try write(".claude/\n", to: ".gitignore")
        try write("<!-- claudoscope-canon: v1 -->\n", to: ".claude/rules/canon.md")
        try write(validRecords, to: ".claude/canon.md")

        let results = await linter.lintCanon(projectRoot: tempDir.path, bundledProtocolVersion: 1)
        XCTAssertTrue(ids(results).contains(.CAN002))
        XCTAssertEqual(results.first { $0.checkId == .CAN002 }?.severity, .warning)
    }

    @discardableResult
    private func runGit(_ args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "-C", tempDir.path] + args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
