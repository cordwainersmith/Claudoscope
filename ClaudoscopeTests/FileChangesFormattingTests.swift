import XCTest
@testable import Claudoscope

/// Pure helpers of FileChangesService: unified-patch text, Edit final-content
/// reconstruction, and the disk-state tri-check.
final class FileChangesFormattingTests: XCTestCase {

    private func makeEvent(
        id: String = "t1",
        kind: FileEditKind = .edit,
        timestamp: String? = "2026-07-01T10:00:00.000Z",
        hunks: [PatchHunk]
    ) -> FileEditEvent {
        FileEditEvent(
            id: id, kind: kind, recordUuid: "u1", jumpTargetUuid: "u1",
            agentLabel: nil, timestamp: timestamp, hunks: hunks,
            additions: hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("+") }.count },
            deletions: hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("-") }.count },
            replaceAll: false, userModified: false, isFallbackRendering: false
        )
    }

    // MARK: - Unified patch text

    func testUnifiedPatchFormatExact() {
        let event = makeEvent(hunks: [
            PatchHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 4,
                      lines: [" a", "-b", "+B", "+B2", " c"]),
        ])
        let text = FileChangesService.unifiedPatchText(event: event, displayPath: "src/x.swift")
        XCTAssertEqual(text, """
        --- a/src/x.swift
        +++ b/src/x.swift
        @@ -1,3 +1,4 @@
         a
        -b
        +B
        +B2
         c

        """, "exact framing, verbatim body, trailing newline")
    }

    func testUnifiedPatchCreateUsesDevNull() {
        let event = makeEvent(kind: .writeCreate, hunks: [
            PatchHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: ["+hello"]),
        ])
        let text = FileChangesService.unifiedPatchText(event: event, displayPath: "/abs/new.txt")
        XCTAssertTrue(text.hasPrefix("--- /dev/null\n+++ b/abs/new.txt\n"),
                      "create diffs against /dev/null; absolute paths lose the leading slash")
    }

    func testWholeFilePatchConcatenatesChronologically() {
        let first = makeEvent(id: "t1", timestamp: "2026-07-01T10:00:00.000Z", hunks: [
            PatchHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-a", "+b"]),
        ])
        let second = makeEvent(id: "t2", timestamp: "2026-07-01T10:05:00.000Z", hunks: [
            PatchHunk(oldStart: 5, oldLines: 1, newStart: 5, newLines: 1, lines: ["-c", "+d"]),
        ])
        let file = ChangedFile(
            path: "/proj/f.txt", displayPath: "f.txt", isNewFile: false,
            events: [first, second], additions: 2, deletions: 2,
            finalContentSHA256: nil, lastTimestamp: second.timestamp
        )
        let text = FileChangesService.unifiedPatchText(file: file)
        let firstRange = text.range(of: "+b")
        let secondRange = text.range(of: "+d")
        XCTAssertNotNil(firstRange)
        XCTAssertNotNil(secondRange)
        XCTAssertLessThan(firstRange!.lowerBound, secondRange!.lowerBound,
                          "events appear in chronological order")
        XCTAssertEqual(text.components(separatedBy: "--- a/f.txt").count - 1, 2,
                       "one section header per event")
    }

    // MARK: - Final content reconstruction

    func testEditFinalContentFirstOccurrence() {
        let original = "alpha\ntarget\nbeta\ntarget\n"
        let result = FileChangesService.finalContent(
            original: original, oldString: "target", newString: "REPLACED", replaceAll: false
        )
        XCTAssertEqual(result, "alpha\nREPLACED\nbeta\ntarget\n",
                       "only the first occurrence changes")
    }

    func testEditFinalContentReplaceAll() {
        let original = "alpha\ntarget\nbeta\ntarget\n"
        let result = FileChangesService.finalContent(
            original: original, oldString: "target", newString: "REPLACED", replaceAll: true
        )
        XCTAssertEqual(result, "alpha\nREPLACED\nbeta\nREPLACED\n")
    }

    func testEditFinalContentUnapplicable() {
        XCTAssertNil(FileChangesService.finalContent(
            original: "abc", oldString: "missing", newString: "x", replaceAll: false
        ))
        XCTAssertNil(FileChangesService.finalContent(
            original: "abc", oldString: "", newString: "x", replaceAll: false
        ))
    }

    // MARK: - Disk states

    func testDiskStatesTriState() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-diskstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cleanURL = dir.appendingPathComponent("clean.txt")
        let modifiedURL = dir.appendingPathComponent("modified.txt")
        let missingURL = dir.appendingPathComponent("missing.txt")
        try "expected".write(to: cleanURL, atomically: true, encoding: .utf8)
        try "drifted".write(to: modifiedURL, atomically: true, encoding: .utf8)

        func changedFile(_ url: URL, sha: String?) -> ChangedFile {
            ChangedFile(path: url.path, displayPath: url.lastPathComponent, isNewFile: false,
                        events: [], additions: 0, deletions: 0,
                        finalContentSHA256: sha, lastTimestamp: nil)
        }
        let expectedSHA = FileChangesService.sha256Hex("expected")
        let set = FileChangeSet(
            sessionKey: "k",
            files: [
                changedFile(cleanURL, sha: expectedSHA),
                changedFile(modifiedURL, sha: expectedSHA),
                changedFile(missingURL, sha: expectedSHA),
                changedFile(dir.appendingPathComponent("unknown.txt"), sha: nil),
            ],
            totalAdditions: 0, totalDeletions: 0, totalEvents: 0
        )

        let states = await FileChangesService().diskStates(for: set)
        XCTAssertEqual(states[cleanURL.path], .clean)
        XCTAssertEqual(states[modifiedURL.path], .modified)
        XCTAssertEqual(states[missingURL.path], .missing)
        XCTAssertEqual(states[dir.appendingPathComponent("unknown.txt").path], .unknown)
    }
}
