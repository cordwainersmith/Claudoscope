import XCTest
@testable import Claudoscope

/// Extraction and merge behavior of FileChangesService: joining assistant
/// tool_use blocks to user-side toolUseResult payloads, failed-edit exclusion,
/// subagent merge with spawn anchoring, context-fork dedup, and cache
/// fingerprinting. Fixtures mirror real Claude Code JSONL shapes, including
/// the spawn-record quirks (bare agentId, null top-level tool_use_id).
final class FileChangesServiceTests: XCTestCase {

    // MARK: - Fixture builders

    private func makeFixtureDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-filechanges-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func writeMain(_ lines: [String], in base: URL, name: String = "main") throws -> URL {
        let url = base.appendingPathComponent("\(name).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeSubagent(_ lines: [String], in base: URL, mainName: String = "main", fileName: String) throws {
        let dir = base.appendingPathComponent(mainName).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Assistant record with a single Edit/Write/NotebookEdit tool_use block.
    private func toolUseLine(
        uuid: String, toolId: String, name: String, ts: String? = "2026-07-01T10:00:00.000Z",
        cwd: String = "/proj", inputJSON: String
    ) -> String {
        let tsField = ts.map { #""timestamp":"\#($0)","# } ?? ""
        return #"{"type":"assistant","uuid":"\#(uuid)",\#(tsField)"cwd":"\#(cwd)","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(toolId)","name":"\#(name)","input":\#(inputJSON)}]}}"#
    }

    /// User record joining `toolId` with a successful object toolUseResult.
    private func resultLine(toolId: String, resultJSON: String) -> String {
        #"{"type":"user","uuid":"u-\#(toolId)","timestamp":"2026-07-01T10:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(toolId)","content":"ok"}]},"toolUseResult":\#(resultJSON)}"#
    }

    private func editPair(
        toolId: String, uuid: String, path: String, ts: String = "2026-07-01T10:00:00.000Z",
        cwd: String = "/proj", old: String = "old line", new: String = "new line"
    ) -> [String] {
        [
            toolUseLine(uuid: uuid, toolId: toolId, name: "Edit", ts: ts, cwd: cwd,
                        inputJSON: #"{"file_path":"\#(path)","old_string":"\#(old)","new_string":"\#(new)"}"#),
            resultLine(toolId: toolId, resultJSON: #"{"filePath":"\#(path)","oldString":"\#(old)","newString":"\#(new)","originalFile":"ctx\n\#(old)\ntail","replaceAll":false,"userModified":false,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":3,"lines":[" ctx","-\#(old)","+\#(new)"," tail"]}]}"#),
        ]
    }

    private func load(_ mainURL: URL, key: String = "main") async throws -> FileChangeSet {
        try await FileChangesService().loadChangeSet(mainFileURL: mainURL, sessionKey: key)
    }

    // MARK: - Join and hunk fidelity

    func testEditJoinsToolUseWithResult() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let lines = [
            toolUseLine(uuid: "au1", toolId: "t1", name: "Edit",
                        inputJSON: #"{"file_path":"/proj/src/a.swift","old_string":"x","new_string":"y"}"#),
            resultLine(toolId: "t1", resultJSON: #"{"filePath":"/proj/src/a.swift","oldString":"x","newString":"y","originalFile":"a\nx\nb\nq\nx2\nz","replaceAll":false,"userModified":true,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":3,"lines":[" a","-x","+y"," b"]},{"oldStart":4,"oldLines":2,"newStart":4,"newLines":3,"lines":[" q","-x2","+y2","+y3"]}]}"#),
        ]
        let set = try await load(try writeMain(lines, in: base))

        XCTAssertEqual(set.files.count, 1)
        let file = try XCTUnwrap(set.files.first)
        XCTAssertEqual(file.path, "/proj/src/a.swift")
        XCTAssertEqual(file.displayPath, "src/a.swift", "cwd-prefixed path relativizes")
        XCTAssertEqual(file.events.count, 1)
        let event = try XCTUnwrap(file.events.first)
        XCTAssertEqual(event.kind, .edit)
        XCTAssertEqual(event.recordUuid, "au1")
        XCTAssertEqual(event.jumpTargetUuid, "au1", "main-file events anchor to their own record")
        XCTAssertNil(event.agentLabel)
        XCTAssertTrue(event.userModified)
        XCTAssertEqual(event.hunks.count, 2)
        XCTAssertEqual(event.hunks[0].lines, [" a", "-x", "+y", " b"], "hunk lines verbatim")
        XCTAssertEqual(event.hunks[1].oldStart, 4)
        XCTAssertEqual(event.additions, 3)
        XCTAssertEqual(event.deletions, 2)
        XCTAssertEqual(set.totalAdditions, 3)
        XCTAssertEqual(set.totalDeletions, 2)
    }

    /// Pins the streaming pre-filter invariant: a result line's only
    /// "tool_use" substring is the embedded tool_result's tool_use_id (the
    /// top-level payload key is camelCase "toolUseResult"), and it must
    /// still be decoded and joined.
    func testPreFilterKeepsResultOnlyLines() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let lines = editPair(toolId: "t1", uuid: "au1", path: "/proj/f.txt")
        XCTAssertFalse(lines[1].contains(#""type":"tool_use""#), "fixture: result line has no tool_use block")
        XCTAssertTrue(lines[1].contains("tool_use_id"), "fixture: gate matches via the join key only")

        let set = try await load(try writeMain(lines, in: base))
        XCTAssertEqual(set.totalEvents, 1)
    }

    // MARK: - Failed edits hidden

    func testFailedEditsExcluded() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        var lines: [String] = []
        // 1. is_error on the embedded block
        lines.append(toolUseLine(uuid: "e1", toolId: "bad1", name: "Edit",
                                 inputJSON: #"{"file_path":"/proj/a.txt","old_string":"x","new_string":"y"}"#))
        lines.append(#"{"type":"user","uuid":"u1","timestamp":"2026-07-01T10:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"bad1","is_error":true,"content":"String to replace not found"}]},"toolUseResult":"Error: not found"}"#)
        // 2. string-typed toolUseResult without is_error (rejected shape)
        lines.append(toolUseLine(uuid: "e2", toolId: "bad2", name: "Edit",
                                 inputJSON: #"{"file_path":"/proj/b.txt","old_string":"x","new_string":"y"}"#))
        lines.append(#"{"type":"user","uuid":"u2","timestamp":"2026-07-01T10:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"bad2","content":"rejected"}]},"toolUseResult":"The user doesn't want to proceed"}"#)
        // 3. dangling tool_use, no result at all
        lines.append(toolUseLine(uuid: "e3", toolId: "bad3", name: "Write",
                                 inputJSON: #"{"file_path":"/proj/c.txt","content":"body"}"#))
        // A valid neighbor must still extract.
        lines.append(contentsOf: editPair(toolId: "ok1", uuid: "e4", path: "/proj/good.txt"))

        let set = try await load(try writeMain(lines, in: base))
        XCTAssertEqual(set.totalEvents, 1, "only the successful edit survives")
        XCTAssertEqual(set.files.first?.path, "/proj/good.txt")
    }

    // MARK: - Ordering and grouping

    func testChronologicalOrderAndGrouping() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        var lines: [String] = []
        lines.append(contentsOf: editPair(toolId: "t1", uuid: "a1", path: "/proj/first.txt",
                                          ts: "2026-07-01T10:00:00.000Z"))
        lines.append(contentsOf: editPair(toolId: "t2", uuid: "a2", path: "/proj/second.txt",
                                          ts: "2026-07-01T10:05:00.000Z"))
        lines.append(contentsOf: editPair(toolId: "t3", uuid: "a3", path: "/proj/first.txt",
                                          ts: "2026-07-01T10:10:00.000Z"))
        // Null-timestamp record sorts last within its file.
        lines.append(toolUseLine(uuid: "a4", toolId: "t4", name: "Edit", ts: nil,
                                 inputJSON: #"{"file_path":"/proj/first.txt","old_string":"x","new_string":"y"}"#))
        lines.append(resultLine(toolId: "t4", resultJSON: #"{"filePath":"/proj/first.txt","oldString":"x","newString":"y","originalFile":"x","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-x","+y"]}]}"#))

        let set = try await load(try writeMain(lines, in: base))

        XCTAssertEqual(set.files.map(\.path), ["/proj/first.txt", "/proj/second.txt"],
                       "files sorted by first-edit time")
        let first = try XCTUnwrap(set.files.first)
        XCTAssertEqual(first.events.map(\.id), ["t1", "t3", "t4"],
                       "per-file chronological, nil timestamp last")
    }

    // MARK: - Write create

    func testWriteCreateFlagsAndFinalHash() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let content = "line1\\nline2"
        let lines = [
            toolUseLine(uuid: "w1", toolId: "t1", name: "Write",
                        inputJSON: #"{"file_path":"/proj/new.txt","content":"\#(content)"}"#),
            resultLine(toolId: "t1", resultJSON: #"{"type":"create","filePath":"/proj/new.txt","content":"\#(content)","structuredPatch":[{"oldStart":0,"oldLines":0,"newStart":1,"newLines":2,"lines":["+line1","+line2"]}]}"#),
        ]
        let set = try await load(try writeMain(lines, in: base))

        let file = try XCTUnwrap(set.files.first)
        XCTAssertTrue(file.isNewFile)
        XCTAssertEqual(file.events.first?.kind, .writeCreate)
        XCTAssertEqual(file.finalContentSHA256, FileChangesService.sha256Hex("line1\nline2"))
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 0)
    }

    // MARK: - NotebookEdit fallback

    func testNotebookEditFallbackAllAdded() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let lines = [
            toolUseLine(uuid: "n1", toolId: "t1", name: "NotebookEdit",
                        inputJSON: #"{"notebook_path":"/proj/nb.ipynb","cell_id":"c1","new_source":"import os\nprint(1)"}"#),
            // Success result but a non-object payload: no structuredPatch available.
            #"{"type":"user","uuid":"u1","timestamp":"2026-07-01T10:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Cell updated"}]},"toolUseResult":"Cell updated"}"#,
        ]
        let set = try await load(try writeMain(lines, in: base))

        let file = try XCTUnwrap(set.files.first)
        XCTAssertEqual(file.path, "/proj/nb.ipynb")
        let event = try XCTUnwrap(file.events.first)
        XCTAssertEqual(event.kind, .notebookEdit)
        XCTAssertTrue(event.isFallbackRendering)
        XCTAssertEqual(event.hunks.first?.lines, ["+import os", "+print(1)"])
        XCTAssertEqual(event.deletions, 0)
        XCTAssertNil(file.finalContentSHA256, "notebook edits cannot reconstruct final content")
    }

    // MARK: - Empty patch

    func testEmptyStructuredPatchKeepsEvent() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let lines = [
            toolUseLine(uuid: "a1", toolId: "t1", name: "Edit",
                        inputJSON: #"{"file_path":"/proj/a.txt","old_string":"x","new_string":"x"}"#),
            resultLine(toolId: "t1", resultJSON: #"{"filePath":"/proj/a.txt","oldString":"x","newString":"x","originalFile":"x","structuredPatch":[]}"#),
        ]
        let set = try await load(try writeMain(lines, in: base))

        XCTAssertEqual(set.totalEvents, 1)
        XCTAssertEqual(set.files.first?.events.first?.hunks.count, 0)
    }

    // MARK: - Subagent merge

    /// Fixture uses the REAL spawn-record shape: bare agentId (no "agent-"
    /// prefix), no usable top-level tool_use_id, agentType null; the spawning
    /// id lives only in the embedded tool_result block, and the friendly label
    /// only in the Task call's input.subagent_type.
    func testSubagentMergeAttributionAndSpawnAnchor() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        var parentLines: [String] = []
        parentLines.append(contentsOf: editPair(toolId: "p1", uuid: "pa1", path: "/proj/shared.txt",
                                                ts: "2026-07-01T10:00:00.000Z"))
        parentLines.append(toolUseLine(uuid: "spawnU", toolId: "tk1", name: "Agent",
                                       ts: "2026-07-01T10:02:00.000Z",
                                       inputJSON: #"{"prompt":"go","subagent_type":"researcher"}"#))
        parentLines.append(#"{"type":"user","uuid":"su1","timestamp":"2026-07-01T10:08:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tk1","content":"done"}]},"toolUseResult":{"agentId":"abc123def","agentType":null,"content":"done"}}"#)
        parentLines.append(contentsOf: editPair(toolId: "p2", uuid: "pa2", path: "/proj/shared.txt",
                                                ts: "2026-07-01T10:10:00.000Z"))

        let subLines = editPair(toolId: "s1", uuid: "sub-a1", path: "/proj/shared.txt",
                                ts: "2026-07-01T10:05:00.000Z")

        let mainURL = try writeMain(parentLines, in: base)
        try writeSubagent(subLines, in: base, fileName: "agent-abc123def.jsonl")

        let set = try await load(mainURL)

        let file = try XCTUnwrap(set.files.first { $0.path == "/proj/shared.txt" })
        XCTAssertEqual(file.events.map(\.id), ["p1", "s1", "p2"],
                       "subagent edit interleaves chronologically")
        let subEvent = try XCTUnwrap(file.events.first { $0.id == "s1" })
        XCTAssertEqual(subEvent.agentLabel, "researcher", "label from the Task input's subagent_type")
        XCTAssertEqual(subEvent.jumpTargetUuid, "spawnU", "anchors to the spawning call's record")
        XCTAssertNil(file.events.first { $0.id == "p1" }?.agentLabel)
    }

    func testUnresolvableSpawnDisablesJump() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let mainURL = try writeMain(editPair(toolId: "p1", uuid: "pa1", path: "/proj/a.txt"), in: base)
        try writeSubagent(editPair(toolId: "s1", uuid: "sa1", path: "/proj/b.txt"),
                          in: base, fileName: "agent-deadbeef1.jsonl")

        let set = try await load(mainURL)
        let subEvent = try XCTUnwrap(set.files.first { $0.path == "/proj/b.txt" }?.events.first)
        XCTAssertNil(subEvent.jumpTargetUuid, "no spawn edge, jump disabled")
        XCTAssertEqual(subEvent.agentLabel, "deadbeef", "falls back to truncated stem")
    }

    func testContextForkReplayDeduped() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let parentPair = editPair(toolId: "p1", uuid: "pa1", path: "/proj/a.txt")
        let mainURL = try writeMain(parentPair, in: base)
        // acompact transcript replays the parent's lines verbatim (same tool id).
        try writeSubagent(parentPair, in: base, fileName: "agent-acompact-xyz.jsonl")

        let set = try await load(mainURL)
        XCTAssertEqual(set.totalEvents, 1, "replayed edit dedupes by tool_use id")
        XCTAssertNil(set.files.first?.events.first?.agentLabel, "parent copy wins attribution")
    }

    // MARK: - Cache

    func testCacheFingerprintInvalidation() async throws {
        let base = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let service = FileChangesService()
        let mainURL = try writeMain(editPair(toolId: "t1", uuid: "a1", path: "/proj/a.txt"), in: base)

        let first = try await service.loadChangeSet(mainFileURL: mainURL, sessionKey: "main")
        XCTAssertEqual(first.totalEvents, 1)

        // Grow the file: size changes, fingerprint misses, re-extraction sees both edits.
        let more = editPair(toolId: "t2", uuid: "a2", path: "/proj/a.txt",
                            ts: "2026-07-01T11:00:00.000Z")
        let handle = try FileHandle(forWritingTo: mainURL)
        handle.seekToEndOfFile()
        handle.write(Data(("\n" + more.joined(separator: "\n")).utf8))
        try handle.close()

        let second = try await service.loadChangeSet(mainFileURL: mainURL, sessionKey: "main")
        XCTAssertEqual(second.totalEvents, 2, "stale cache entry replaced after file growth")
    }
}
