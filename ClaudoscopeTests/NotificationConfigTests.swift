import XCTest
@testable import Claudoscope

final class NotificationConfigTests: XCTestCase {

    func testCodableRoundTrip() throws {
        var c = NotificationConfig.default
        c.masterEnabled = true
        c.soundEnabled = false
        c.quietHoursEnabled = true
        c.quietHoursStartMinutes = 90
        c.quietHoursEndMinutes = 420
        c.mutedProjectIds = ["-a-b", "-c-d"]

        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(NotificationConfig.self, from: data)
        XCTAssertEqual(c, back)
    }

    func testMutedSetSemantics() {
        var c = NotificationConfig.default
        c.mutedProjectIds.insert("-x")
        c.mutedProjectIds.insert("-x")   // idempotent
        XCTAssertEqual(c.mutedProjectIds, ["-x"])
        c.mutedProjectIds.remove("-x")
        XCTAssertTrue(c.mutedProjectIds.isEmpty)
    }

    func testDecodeIsResilientToDefault() {
        // A fresh install has no persisted blob; loading falls back to .default.
        XCTAssertFalse(NotificationConfig.default.masterEnabled)
        XCTAssertTrue(NotificationConfig.default.soundEnabled)
        XCTAssertTrue(NotificationConfig.default.mutedProjectIds.isEmpty)
    }

    // MARK: - Quiet hours

    private func at(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    func testQuietHoursSameDayWindow() {
        var c = NotificationConfig.default
        c.quietHoursEnabled = true
        c.quietHoursStartMinutes = 9 * 60    // 09:00
        c.quietHoursEndMinutes = 17 * 60     // 17:00
        XCTAssertTrue(c.isInQuietHours(at(10, 30)))
        XCTAssertFalse(c.isInQuietHours(at(8, 0)))
        XCTAssertFalse(c.isInQuietHours(at(17, 0)))   // end is exclusive
        XCTAssertTrue(c.isInQuietHours(at(9, 0)))     // start is inclusive
    }

    func testQuietHoursWrapsMidnight() {
        var c = NotificationConfig.default
        c.quietHoursEnabled = true
        c.quietHoursStartMinutes = 23 * 60   // 23:00
        c.quietHoursEndMinutes = 7 * 60      // 07:00
        XCTAssertTrue(c.isInQuietHours(at(23, 30)))
        XCTAssertTrue(c.isInQuietHours(at(2, 0)))
        XCTAssertFalse(c.isInQuietHours(at(12, 0)))
        XCTAssertFalse(c.isInQuietHours(at(7, 0)))    // end exclusive
    }

    func testQuietHoursDisabledIsAlwaysFalse() {
        var c = NotificationConfig.default
        c.quietHoursEnabled = false
        c.quietHoursStartMinutes = 0
        c.quietHoursEndMinutes = 1439
        XCTAssertFalse(c.isInQuietHours(at(12, 0)))
    }

    func testQuietHoursZeroWidthMutesNothing() {
        var c = NotificationConfig.default
        c.quietHoursEnabled = true
        c.quietHoursStartMinutes = 600
        c.quietHoursEndMinutes = 600
        XCTAssertFalse(c.isInQuietHours(at(10, 0)))
    }
}
