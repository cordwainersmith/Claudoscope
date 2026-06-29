import XCTest
@testable import Claudoscope

/// Tests for FileHistoryService aggregation and the file-history-snapshot record
/// decoding (snapshot gated to full mode; isSnapshotUpdate available in both).
final class FileHistoryTests: XCTestCase {

    private func decode(_ json: String, mode: DecodeMode = .full) throws -> ParsedRecordRaw {
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = mode
        return try decoder.decode(ParsedRecordRaw.self, from: Data(json.utf8))
    }

    private func snapshotJSON(messageId: String, isUpdate: Bool, files: [(path: String, version: Int, time: String)]) -> String {
        let backups = files.map {
            "\"\($0.path)\":{\"backupFileName\":\"h@v\($0.version)\",\"version\":\($0.version),\"backupTime\":\"\($0.time)\"}"
        }.joined(separator: ",")
        return "{\"type\":\"file-history-snapshot\",\"messageId\":\"\(messageId)\",\"isSnapshotUpdate\":\(isUpdate),\"snapshot\":{\"messageId\":\"\(messageId)\",\"timestamp\":\"\(files.first?.time ?? "")\",\"trackedFileBackups\":{\(backups)}}}"
    }

    func testSummarizeTakesMaxVersionPerPath() throws {
        let r1 = try decode(snapshotJSON(messageId: "m1", isUpdate: true, files: [
            ("a.swift", 1, "2026-06-01T10:00:00Z"),
            ("b.swift", 2, "2026-06-01T10:00:00Z")
        ]))
        let r2 = try decode(snapshotJSON(messageId: "m2", isUpdate: true, files: [
            ("a.swift", 3, "2026-06-01T11:00:00Z")
        ]))
        let changes = FileHistoryService.summarize(records: [r1, r2])
        XCTAssertEqual(changes.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(changes.first { $0.path == "a.swift" }?.latestVersion, 3)
        XCTAssertEqual(changes.first { $0.path == "b.swift" }?.latestVersion, 2)
        XCTAssertEqual(changes.first { $0.path == "a.swift" }?.lastBackupTime, "2026-06-01T11:00:00Z")
    }

    func testSummarizeIgnoresNonSnapshotRecords() throws {
        let user = try decode("{\"type\":\"user\",\"uuid\":\"u1\"}")
        XCTAssertTrue(FileHistoryService.summarize(records: [user]).isEmpty)
    }

    func testSummarizeToleratesEmptyBackups() throws {
        let r = try decode("{\"type\":\"file-history-snapshot\",\"messageId\":\"m1\",\"isSnapshotUpdate\":false,\"snapshot\":{\"messageId\":\"m1\",\"trackedFileBackups\":{}}}")
        XCTAssertTrue(FileHistoryService.summarize(records: [r]).isEmpty)
    }

    func testCheckpointMessageIdsOnlyIncludesUpdates() throws {
        let upd = try decode(snapshotJSON(messageId: "m1", isUpdate: true, files: [("a.swift", 2, "t")]))
        let cumulative = try decode(snapshotJSON(messageId: "m2", isUpdate: false, files: [("a.swift", 2, "t")]))
        let ids = FileHistoryService.checkpointMessageIds(records: [upd, cumulative])
        XCTAssertEqual(ids, ["m1"])
    }

    func testSnapshotNotDecodedInLiteMode() throws {
        let r = try decode(snapshotJSON(messageId: "m1", isUpdate: true, files: [("a.swift", 1, "t")]), mode: .lite)
        XCTAssertNil(r.snapshot)                 // heavy backup map gated to full mode
        XCTAssertEqual(r.isSnapshotUpdate, true)  // cheap bool decoded in both modes
    }
}
