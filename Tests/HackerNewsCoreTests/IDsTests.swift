import Foundation
import Testing
@testable import HackerNewsCore

@Test func itemIDRejectsNonPositiveJSON() {
    let data = Data("0".utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ItemID.self, from: data)
    }
}

@Test func itemIDRoundTripsThroughJSON() throws {
    let data = try JSONEncoder().encode(ItemID(42))
    let decoded = try JSONDecoder().decode(ItemID.self, from: data)
    #expect(decoded == ItemID(42))
    #expect(data == Data("42".utf8))
}

@Test func userIDsAreCaseSensitive() {
    #expect(UserID("pg") != UserID("PG"))
    #expect(UserID("pg").rawValue == "pg")
}

@Test func userIDRejectsEmptyJSON() {
    let data = Data("\"\"".utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(UserID.self, from: data)
    }
}
