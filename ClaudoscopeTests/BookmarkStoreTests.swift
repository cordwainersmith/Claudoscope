import XCTest
import GRDB
@testable import Claudoscope

final class BookmarkStoreTests: XCTestCase {

    private func makeStore() throws -> BookmarkStore {
        try BookmarkStore(DatabaseQueue())
    }

    private func draft(session: String = "s1", uuid: String = "u1", note: String = "") -> Bookmark {
        Bookmark(
            id: nil, sessionId: session, projectId: "p1", recordUuid: uuid,
            sessionTitle: "Title \(session)", excerpt: "excerpt \(uuid)", note: note,
            createdAt: 1_000, updatedAt: 1_000
        )
    }

    func testInsertAssignsIdAndRoundTrips() async throws {
        let store = try makeStore()
        let inserted = try await store.insert(draft(note: "remember this"))
        XCTAssertNotNil(inserted.id)

        let all = try await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0], inserted)
        XCTAssertEqual(all[0].note, "remember this")
        XCTAssertEqual(all[0].sessionTitle, "Title s1")
    }

    func testUniquePerSessionAndUuid() async throws {
        let store = try makeStore()
        _ = try await store.insert(draft())
        do {
            _ = try await store.insert(draft())
            XCTFail("second insert for the same (session, uuid) must throw")
        } catch {
            // expected
        }
        // Same uuid in another session is a different turn.
        _ = try await store.insert(draft(session: "s2"))
        let all = try await store.fetchAll()
        XCTAssertEqual(all.count, 2)
    }

    func testUpdateNoteBumpsUpdatedAt() async throws {
        let store = try makeStore()
        let inserted = try await store.insert(draft())
        try await store.updateNote(id: inserted.id!, note: "edited")
        let row = try await store.fetchAll().first
        XCTAssertEqual(row?.note, "edited")
        XCTAssertGreaterThan(row?.updatedAt ?? 0, 1_000)
        XCTAssertEqual(row?.createdAt, 1_000)
    }

    func testFetchBySessionIsScoped() async throws {
        let store = try makeStore()
        _ = try await store.insert(draft(session: "s1", uuid: "a"))
        _ = try await store.insert(draft(session: "s1", uuid: "b"))
        _ = try await store.insert(draft(session: "s2", uuid: "c"))
        let s1 = try await store.fetch(sessionId: "s1")
        XCTAssertEqual(Set(s1.map(\.recordUuid)), ["a", "b"])
        XCTAssertTrue(s1.allSatisfy { $0.sessionId == "s1" })
        let none = try await store.fetch(sessionId: "missing")
        XCTAssertTrue(none.isEmpty)
    }

    func testDeleteRemovesRow() async throws {
        let store = try makeStore()
        let a = try await store.insert(draft(uuid: "a"))
        _ = try await store.insert(draft(uuid: "b"))
        try await store.delete(id: a.id!)
        let all = try await store.fetchAll()
        XCTAssertEqual(all.map(\.recordUuid), ["b"])
        // Re-inserting the deleted pair is allowed again.
        _ = try await store.insert(draft(uuid: "a"))
    }

    func testFetchAllIsNewestFirst() async throws {
        let store = try makeStore()
        var old = draft(uuid: "old"); old.createdAt = 10
        var new = draft(uuid: "new"); new.createdAt = 20
        _ = try await store.insert(old)
        _ = try await store.insert(new)
        let all = try await store.fetchAll()
        XCTAssertEqual(all.map(\.recordUuid), ["new", "old"])
    }

    /// An empty excerpt is a valid row: the uuid is the key, not the text.
    func testEmptyExcerptIsStored() async throws {
        let store = try makeStore()
        var b = draft(); b.excerpt = ""
        let inserted = try await store.insert(b)
        XCTAssertNotNil(inserted.id)
        let stored = try await store.fetchAll().first
        XCTAssertEqual(stored?.excerpt, "")
    }
}
