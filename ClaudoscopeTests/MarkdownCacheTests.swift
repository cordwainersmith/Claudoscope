import XCTest
@testable import Claudoscope

/// Covers the markdown memoization fix (parseMarkdown caching, Equatable blocks)
/// and the hoisted user-message tag stripping helper.
final class MarkdownCacheTests: XCTestCase {

    private let goldenDoc = """
    # Heading 1
    Some intro paragraph with **bold** and `code`.

    ## Subheading
    - item one
    - item two
      - nested item

    1. first
    2. second

    > a blockquote line

    ```swift
    let x = 1
    ```

    | A | B |
    | --- | --- |
    | 1 | 2 |

    ---
    """

    func testMemoizationReturnsEqualOutput() {
        let first = parseMarkdown(goldenDoc)
        let second = parseMarkdown(goldenDoc)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    func testCachedMatchesUncached() {
        XCTAssertEqual(parseMarkdown(goldenDoc), parseMarkdownUncached(goldenDoc))
    }

    func testDistinctContentDistinctResult() {
        let a = parseMarkdown("# Title A")
        let b = parseMarkdown("# Title B")
        XCTAssertNotEqual(a, b)
    }

    func testParsesExpectedBlockKinds() {
        let blocks = parseMarkdown(goldenDoc)
        func contains(_ predicate: (MarkdownBlock) -> Bool) -> Bool { blocks.contains(where: predicate) }

        XCTAssertTrue(contains { if case .heading = $0 { return true } else { return false } })
        XCTAssertTrue(contains { if case .codeBlock = $0 { return true } else { return false } })
        XCTAssertTrue(contains { if case .table = $0 { return true } else { return false } })
        XCTAssertTrue(contains { if case .unorderedList = $0 { return true } else { return false } })
        XCTAssertTrue(contains { if case .orderedList = $0 { return true } else { return false } })
        XCTAssertTrue(contains { if case .blockquote = $0 { return true } else { return false } })
        XCTAssertTrue(contains { if case .horizontalRule = $0 { return true } else { return false } })
    }

    func testStrippedUserTextRemovesTagsAcrossLines() {
        let raw = """
        <system-reminder>
        hidden line
        across multiple lines
        </system-reminder>
        Visible question?
        <local-command-caveat>caveat text</local-command-caveat>
        <user-prompt-submit-hook>hook output</user-prompt-submit-hook>
        """
        let stripped = strippedUserText(raw)
        XCTAssertEqual(stripped, "Visible question?")
        XCTAssertFalse(stripped.contains("hidden line"))
        XCTAssertFalse(stripped.contains("caveat"))
        XCTAssertFalse(stripped.contains("hook output"))
    }

    func testStrippedUserTextNilIsEmpty() {
        XCTAssertEqual(strippedUserText(nil), "")
    }
}
