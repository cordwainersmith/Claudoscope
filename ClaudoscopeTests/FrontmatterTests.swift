import XCTest
@testable import Claudoscope

/// Regression: `parseFrontmatter` used to treat the OPENING `---` fence as the
/// end-of-frontmatter marker, so every fenced skill/agent file returned nil
/// name/description and empty metadata (the frontmatter leaked into the body).
/// These tests lock in fenced parsing, folded-scalar handling, multi-line lists,
/// and the unchanged fence-less fallback.
final class FrontmatterTests: XCTestCase {

    func testFencedInlineDescription() {
        let content = """
        ---
        name: builder
        description: Implementation work that needs judgment.
        model: opus
        effort: medium
        ---
        You do the whole task.
        """
        let r = parseFrontmatter(content)
        XCTAssertEqual(r.name, "builder")
        XCTAssertEqual(r.description, "Implementation work that needs judgment.")
        XCTAssertEqual(r.metadata["model"], "opus")
        XCTAssertEqual(r.metadata["effort"], "medium")
        XCTAssertEqual(r.body, "You do the whole task.")
        XCTAssertNil(r.metadata["name"])         // name/description are not duplicated into metadata
        XCTAssertNil(r.metadata["description"])
    }

    func testFoldedDescriptionCollapsesToOneLine() {
        let content = """
        ---
        name: blog-writer
        description: >
          Content generation specialist
          for blog posts.
        ---
        Body.
        """
        let r = parseFrontmatter(content)
        XCTAssertEqual(r.name, "blog-writer")
        XCTAssertEqual(r.description, "Content generation specialist for blog posts.")
        XCTAssertEqual(r.body, "Body.")
    }

    func testMultiLineListValueIsCaptured() {
        let content = """
        ---
        name: writer
        tools:
          - Read
          - Write
          - Edit
        ---
        Body.
        """
        let r = parseFrontmatter(content)
        // Stored raw (with "- " prefixes) so ConfigService.parseToolList can normalize it.
        let tools = r.metadata["tools"] ?? ""
        XCTAssertTrue(tools.contains("- Read"))
        XCTAssertTrue(tools.contains("- Write"))
        XCTAssertTrue(tools.contains("- Edit"))
    }

    func testBlankLineInsideFenceDoesNotTerminate() {
        let content = """
        ---
        name: a

        model: opus
        ---
        Body.
        """
        let r = parseFrontmatter(content)
        XCTAssertEqual(r.name, "a")
        XCTAssertEqual(r.metadata["model"], "opus")
        XCTAssertEqual(r.body, "Body.")
    }

    func testFencelessWithTrailingFenceStripsIt() {
        // A caller that strips the opening `---` leaves fence-less content with a
        // trailing closing fence; the terminator must not leak into the body.
        let content = """
        name: recon
        model: haiku
        ---

        You locate things.
        """
        let r = parseFrontmatter(content)
        XCTAssertEqual(r.name, "recon")
        XCTAssertEqual(r.metadata["model"], "haiku")
        XCTAssertEqual(r.body, "You locate things.")
        XCTAssertFalse(r.body.contains("---"))
    }

    func testFencelessStillWorks() {
        let content = """
        name: x
        description: hi there
        user-invokable: true

        Body line
        """
        let r = parseFrontmatter(content)
        XCTAssertEqual(r.name, "x")
        XCTAssertEqual(r.description, "hi there")
        XCTAssertEqual(r.metadata["user-invokable"], "true")
        XCTAssertEqual(r.body, "Body line")
    }
}
