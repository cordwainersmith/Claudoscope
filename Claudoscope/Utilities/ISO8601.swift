import Foundation

enum ISO8601 {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let noFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        parseFixedLayout(s) ?? withFractional.date(from: s) ?? noFractional.date(from: s)
    }

    /// Integer-arithmetic parse of `YYYY-MM-DDTHH:MM:SS[.fff]Z`, the only shape
    /// Claude Code writes. Every per-append pass over the corpus parses one
    /// timestamp per session, and the ICU formatters above cost microseconds
    /// each; this path costs nanoseconds. Anything it does not recognise
    /// (offsets, leap seconds, invalid days) falls through to the formatters.
    static func parseFixedLayout(_ s: String) -> Date? {
        var bytes = s.utf8.makeIterator()
        func digits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let b = bytes.next(), b >= 48, b <= 57 else { return nil }
                value = value * 10 + Int(b - 48)
            }
            return value
        }
        func expect(_ c: UInt8) -> Bool { bytes.next() == c }

        guard let year = digits(4), expect(UInt8(ascii: "-")),
              let month = digits(2), expect(UInt8(ascii: "-")),
              let day = digits(2), expect(UInt8(ascii: "T")),
              let hour = digits(2), expect(UInt8(ascii: ":")),
              let minute = digits(2), expect(UInt8(ascii: ":")),
              let second = digits(2) else { return nil }

        var fraction = 0.0
        var next = bytes.next()
        if next == UInt8(ascii: ".") {
            var scale = 0.1
            var sawDigit = false
            next = bytes.next()
            while let b = next, b >= 48, b <= 57 {
                fraction += Double(b - 48) * scale
                scale /= 10
                sawDigit = true
                next = bytes.next()
            }
            guard sawDigit else { return nil }
        }
        guard next == UInt8(ascii: "Z"), bytes.next() == nil else { return nil }

        guard (1...12).contains(month), day >= 1, day <= daysInMonth(month, year: year),
              hour < 24, minute < 60, second < 60 else { return nil }

        // Days since 1970-01-01 from a proleptic Gregorian civil date
        // (Howard Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146097 + dayOfEra - 719468

        let seconds = Double(days * 86400 + hour * 3600 + minute * 60 + second)
        return Date(timeIntervalSince1970: seconds + fraction)
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// LOCAL calendar day ("YYYY-MM-DD") for an ISO timestamp. Local rather than
    /// UTC so it matches `Calendar.current.startOfDay`, which drives the "today"
    /// filter and the analytics date ranges. Shared so per-day cost attribution
    /// and dated rate lookups can never disagree about which day a message is on.
    static func localDayKey(_ s: String) -> String? {
        guard let date = parse(s) else { return nil }
        return localDayFormatter.string(from: date)
    }

    static func localDayKey(for date: Date) -> String {
        localDayFormatter.string(from: date)
    }
}
