/// Offset/limit pagination over an ordered list.
public struct PageRequest: Sendable, Hashable {
    public let offset: Int
    public let limit: Int

    public static let `default` = PageRequest(uncheckedOffset: 0, limit: 30)

    public init(offset: Int = 0, limit: Int = 30) throws {
        guard offset >= 0 else {
            throw HackerNewsError.invalidInput("Page offset must not be negative")
        }
        guard (1...1000).contains(limit) else {
            throw HackerNewsError.invalidInput("Page limit must be between 1 and 1000")
        }
        guard offset <= Int.max - limit else {
            throw HackerNewsError.invalidInput("Page offset is too large")
        }
        self.offset = offset
        self.limit = limit
    }

    private init(uncheckedOffset offset: Int, limit: Int) {
        self.offset = offset
        self.limit = limit
    }
}

extension PageRequest {
    /// The slice of a sequence selected by this request.
    func slice<T>(of values: [T]) -> ArraySlice<T> {
        guard offset < values.count else {
            return values[values.endIndex...]
        }
        let end = Swift.min(offset + limit, values.count)
        return values[offset..<end]
    }
}
