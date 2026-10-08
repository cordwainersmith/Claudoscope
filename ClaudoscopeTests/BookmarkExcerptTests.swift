import XCTest
@testable import Claudoscope

final class BookmarkExcerptTests: XCTestCase {

    private func record(_ json: String) throws -> ParsedRecordRaw {
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = DecodeMode.full
        return try decoder.decode(ParsedRecordRaw.self, from: Data(json.utf8))
    }

    func testUserExcerptStripsHarnessTags() throws {
        let r = try record("{\"type\":\"user\",\"uuid\":\"u\",\"message\":{\"role\":\"user\",\"content\":\"<system-reminder>\\nhidden\\n</system-reminder>\\n  fix the parser  \"}}")
        XCTAssertEqual(Bookmark.excerpt(from: r), "fix the parser")
    }

    /// A system-reminder-only prompt yields an empty excerpt. The bookmark is
    /// still storable (BookmarkStoreTests.testEmptyExcerptIsStored): the uuid
    /// is the key.
    func testSystemReminderOnlyUserTextYieldsEmptyExcerpt() throws {
        let r = try record("{\"type\":\"user\",\"uuid\":\"u\",\"message\":{\"role\":\"user\",\"content\":\"<system-reminder>only this</system-reminder>\"}}")
        XCTAssertEqual(Bookmark.excerpt(from: r), "")
    }

    func testAssistantExcerptUsesFirstNonEmptyTextBlock() throws {
        let r = try record("{\"type\":\"assistant\",\"uuid\":\"a\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\"},{\"type\":\"text\",\"text\":\"   \"},{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"Read\",\"input\":{}},{\"type\":\"text\",\"text\":\"Here is the answer.\"}]}}")
        XCTAssertEqual(Bookmark.excerpt(from: r), "Here is the answer.")
    }

    func testExcerptIsCappedAt200Chars() throws {
        let long = String(repeating: "x", count: 500)
        let r = try record("{\"type\":\"user\",\"uuid\":\"u\",\"message\":{\"role\":\"user\",\"content\":\"\(long)\"}}")
        XCTAssertEqual(Bookmark.excerpt(from: r).count, 200)
    }

    func testNonMessageRecordYieldsEmptyExcerpt() throws {
        let r = try record("{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"uuid\":\"c\"}")
        XCTAssertEqual(Bookmark.excerpt(from: r), "")
    }
}
