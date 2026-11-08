import Testing
@testable import HackerNewsCore

@Test func pageRequestDefaults() {
    #expect(PageRequest.default.offset == 0)
    #expect(PageRequest.default.limit == 30)
}

@Test func pageRequestRejectsInvalidValues() {
    #expect(throws: HackerNewsError.self) {
        try PageRequest(offset: -1)
    }
    #expect(throws: HackerNewsError.self) {
        try PageRequest(limit: 0)
    }
    #expect(throws: HackerNewsError.self) {
        try PageRequest(limit: 1001)
    }
    #expect(throws: HackerNewsError.self) {
        try PageRequest(offset: Int.max, limit: 1)
    }
}

@Test func pageRequestSlices() throws {
    let request = try PageRequest(offset: 1, limit: 2)
    #expect(Array(request.slice(of: [10, 20, 30, 40])) == [20, 30])

    let beyond = try PageRequest(offset: 10, limit: 2)
    #expect(Array(beyond.slice(of: [10, 20])) == [])
}
