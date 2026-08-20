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
        withFractional.date(from: s) ?? noFractional.date(from: s)
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
}
