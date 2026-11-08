/// A timezone-free day, used by Hacker News' past-front-page archive
/// (`front?day=YYYY-MM-DD`).
public struct CalendarDay: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...9999).contains(year) else {
            throw HackerNewsError.invalidInput("Year must be between 1 and 9999")
        }
        guard (1...12).contains(month) else {
            throw HackerNewsError.invalidInput("Month must be between 1 and 12")
        }

        let daysInMonth: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            daysInMonth = 31
        case 4, 6, 9, 11:
            daysInMonth = 30
        case 2:
            daysInMonth = Self.isLeapYear(year) ? 29 : 28
        default:
            fatalError("unreachable")
        }

        guard (1...daysInMonth).contains(day) else {
            throw HackerNewsError.invalidInput("Day must be between 1 and \(daysInMonth) for this month")
        }

        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses the `YYYY-MM-DD` form used by the archive.
    public init?(iso8601 string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let value = try? CalendarDay(year: year, month: month, day: day)
        else {
            return nil
        }
        self = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = CalendarDay(iso8601: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a valid YYYY-MM-DD date"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        let paddedMonth = month < 10 ? "0\(month)" : String(month)
        let paddedDay = day < 10 ? "0\(day)" : String(day)
        let paddedYear: String
        switch year {
        case 0..<10: paddedYear = "000\(year)"
        case 10..<100: paddedYear = "00\(year)"
        case 100..<1000: paddedYear = "0\(year)"
        default: paddedYear = String(year)
        }
        return "\(paddedYear)-\(paddedMonth)-\(paddedDay)"
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }
}
