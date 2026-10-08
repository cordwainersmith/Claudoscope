import XCTest
@testable import Claudoscope

/// `ISO8601.parse` has an integer-arithmetic fast path for the fixed
/// `YYYY-MM-DDTHH:MM:SS[.fff]Z` layout. It must agree with the ICU formatter
/// on every timestamp it accepts, and decline anything else so the formatter
/// still decides.
final class ISO8601FastPathTests: XCTestCase {
    private let reference: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let plainReference: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Only real calendar days: the ICU formatter silently rolls an invalid
    /// day (Feb 30) into the next month, while the fast path declines it and
    /// defers to the formatter, so the shared entry point still agrees.
    func testFastPathMatchesFormatterAcrossCalendar() {
        var checked = 0
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        for year in [1999, 2000, 2024, 2025, 2026, 2100] {
            for month in 1...12 {
                let monthLength = utc.range(of: .day, in: .month,
                                            for: utc.date(from: DateComponents(year: year, month: month, day: 1))!)!.count
                for day in [1, 15, 28, 29, 30, 31] where day <= monthLength {
                    for (hour, minute, second, millis) in [(0, 0, 0, 0), (23, 59, 59, 999), (12, 30, 45, 7), (9, 5, 1, 120)] {
                        let fractional = String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                                                year, month, day, hour, minute, second, millis)
                        let plain = String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
                                           year, month, day, hour, minute, second)
                        assertAgrees(fractional, reference: reference.date(from: fractional))
                        assertAgrees(plain, reference: plainReference.date(from: plain))
                        checked += 2
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    private func assertAgrees(_ s: String, reference: Date?, file: StaticString = #filePath, line: UInt = #line) {
        let fast = ISO8601.parseFixedLayout(s)
        guard let reference else {
            XCTAssertNil(fast, "fast path accepted \(s) but the formatter rejects it", file: file, line: line)
            return
        }
        guard let fast else {
            XCTFail("fast path declined valid \(s)", file: file, line: line)
            return
        }
        XCTAssertEqual(fast.timeIntervalSince1970, reference.timeIntervalSince1970, accuracy: 0.0005, s, file: file, line: line)
        XCTAssertEqual(ISO8601.parse(s)?.timeIntervalSince1970 ?? -1, reference.timeIntervalSince1970, accuracy: 0.0005, s, file: file, line: line)
    }

    func testFastPathDeclinesOtherShapes() {
        for s in [
            "2026-10-08T09:33:12+00:00",
            "2026-10-08T09:33:12.123+02:00",
            "2026-10-08 09:33:12Z",
            "2026-10-08T09:33:12.Z",
            "2026-10-08T09:33:12Zx",
            "2026-10-08T09:33:60Z",
            "2026-13-08T09:33:12Z",
            "2026-02-29T09:33:12Z",
            "",
            "garbage",
        ] {
            XCTAssertNil(ISO8601.parseFixedLayout(s), s)
        }
        // The formatter still handles offsets through the shared entry point.
        XCTAssertNotNil(ISO8601.parse("2026-10-08T09:33:12+00:00"))
    }

    func testFractionalDigitsBeyondMillisecondsStillParse() {
        let date = ISO8601.parseFixedLayout("2026-10-08T09:33:12.123456Z")
        let millis = reference.date(from: "2026-10-08T09:33:12.123Z")!
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, millis.timeIntervalSince1970 + 0.000456, accuracy: 0.000001)
    }
}
