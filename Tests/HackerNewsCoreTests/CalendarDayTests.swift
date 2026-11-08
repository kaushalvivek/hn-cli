import Foundation
import Testing
@testable import HackerNewsCore

@Test func calendarDayAcceptsLeapDay() throws {
    let day = try CalendarDay(year: 2024, month: 2, day: 29)
    #expect(day.description == "2024-02-29")
}

@Test func calendarDayRejectsInvalidDay() {
    #expect(throws: HackerNewsError.self) {
        try CalendarDay(year: 2023, month: 2, day: 29)
    }
    #expect(throws: HackerNewsError.self) {
        try CalendarDay(year: 2024, month: 13, day: 1)
    }
}

@Test func calendarDayParsesAndFormatsISO8601() throws {
    let day = try #require(CalendarDay(iso8601: "2026-11-07"))
    #expect(day.description == "2026-11-07")
    #expect(CalendarDay(iso8601: "2026-1-7") == nil)
    #expect(CalendarDay(iso8601: "not-a-day") == nil)
}

@Test func calendarDayIsOrdered() throws {
    let earlier = try CalendarDay(year: 2025, month: 12, day: 31)
    let later = try CalendarDay(year: 2026, month: 1, day: 1)
    #expect(earlier < later)
    #expect(later > earlier)
}

@Test func calendarDayRoundTripsThroughJSON() throws {
    let day = try CalendarDay(year: 2026, month: 11, day: 7)
    let data = try JSONEncoder().encode(day)
    #expect(data == Data("\"2026-11-07\"".utf8))
    let decoded = try JSONDecoder().decode(CalendarDay.self, from: data)
    #expect(decoded == day)
}
