import XCTest
@testable import Claudoscope

final class CanonParsingTests: XCTestCase {

    private let sample = """
    # Canon

    Intro paragraph that must be ignored, not parsed as a record.

    ## First decision
    kind: choice | date: 2026-07-15 | status: canon
    Body one. Because: reasons.

    ## Old decision
    kind: constraint | date: 2026-07-10 | status: non-canon, superseded by: First decision
    Body two.

    ## Orphan pointer
    kind: gotcha | date: 2026-07-11 | status: non-canon, superseded by: Nonexistent title
    Body three.

    ## No metadata here
    This record has no metadata line, just prose.

    ## Bad kind
    kind: banana | date: 2026-07-12 | status: canon
    Body four.
    """

    func testIntroIgnoredAndRecordCount() {
        let records = CanonParsing.parseCanonRecords(sample)
        XCTAssertEqual(records.count, 5)
        XCTAssertEqual(records.map(\.title), [
            "First decision", "Old decision", "Orphan pointer", "No metadata here", "Bad kind",
        ])
    }

    func testCanonRecordParsedFully() {
        let rec = CanonParsing.parseCanonRecords(sample).first { $0.title == "First decision" }!
        XCTAssertEqual(rec.kind, .choice)
        XCTAssertEqual(rec.dateString, "2026-07-15")
        XCTAssertEqual(rec.status, .canon)
        XCTAssertTrue(rec.hasMetadataLine)
        XCTAssertTrue(rec.body.contains("Body one"))
    }

    func testSupersededStatusPreservesTargetTitleCase() {
        let rec = CanonParsing.parseCanonRecords(sample).first { $0.title == "Old decision" }!
        XCTAssertEqual(rec.status, .superseded(by: "First decision"))
        XCTAssertEqual(rec.kind, .constraint)
    }

    func testNonCanonNoPointer() {
        let text = """
        # Canon

        ## Retired
        kind: choice | date: 2026-07-01 | status: non-canon
        Gone.
        """
        let rec = CanonParsing.parseCanonRecords(text).first!
        XCTAssertEqual(rec.status, .nonCanonNoPointer)
    }

    func testMalformedDetection() {
        let records = CanonParsing.parseCanonRecords(sample)
        let malformed = Set(CanonParsing.malformedRecords(records).map(\.title))
        // No metadata line, and an invalid kind ("banana") are both malformed.
        XCTAssertEqual(malformed, ["No metadata here", "Bad kind"])
    }

    func testNoMetadataRecordTreatsAllAsBody() {
        let rec = CanonParsing.parseCanonRecords(sample).first { $0.title == "No metadata here" }!
        XCTAssertFalse(rec.hasMetadataLine)
        XCTAssertNil(rec.kind)
        XCTAssertEqual(rec.status, .unknown(""))
        XCTAssertTrue(rec.body.contains("just prose"))
    }

    func testDanglingSupersedes() {
        let records = CanonParsing.parseCanonRecords(sample)
        let dangling = CanonParsing.danglingSupersedes(records)
        // Only "Orphan pointer" targets a nonexistent title; "Old decision" resolves.
        XCTAssertEqual(dangling.count, 1)
        XCTAssertEqual(dangling.first?.record.title, "Orphan pointer")
        XCTAssertEqual(dangling.first?.missingTitle, "Nonexistent title")
    }

    func testFenceGuardsAgainstSpuriousRecords() {
        let text = """
        # Canon

        ## Real record
        kind: choice | date: 2026-07-15 | status: canon
        Example:

        ```
        ## not a record
        ```

        Still the same record body.
        """
        let records = CanonParsing.parseCanonRecords(text)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.title, "Real record")
    }

    func testParseProtocolVersion() {
        XCTAssertEqual(CanonParsing.parseProtocolVersion(CanonArtifacts.ruleFileText), 1)
        XCTAssertEqual(CanonParsing.parseProtocolVersion("<!-- claudoscope-canon: v3 -->\n# x"), 3)
        XCTAssertNil(CanonParsing.parseProtocolVersion("# Project Canon\nno marker"))
    }

    func testEmptyInput() {
        XCTAssertTrue(CanonParsing.parseCanonRecords("").isEmpty)
        XCTAssertTrue(CanonParsing.parseCanonRecords("# Canon\n\nJust an intro.").isEmpty)
    }
}
