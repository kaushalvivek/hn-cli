import Foundation

/// The unique identifier of a Hacker News item.
public struct ItemID: Sendable, Hashable, Comparable, Codable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        precondition(rawValue > 0, "ItemID must be positive")
        self.rawValue = rawValue
    }

    public init(integerLiteral value: Int) {
        self.init(value)
    }

    public init?(validating rawValue: Int) {
        guard rawValue > 0 else { return nil }
        self.init(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        guard rawValue > 0 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ItemID must be positive"
            )
        }
        self.init(rawValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { String(rawValue) }

    public static func < (lhs: ItemID, rhs: ItemID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A Hacker News username.
///
/// Usernames are case-sensitive on Hacker News. Do not case-fold or normalize
/// the value when storing or comparing it.
public struct UserID: Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty, "UserID must not be empty")
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init?(validating rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.init(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard !rawValue.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "UserID must not be empty"
            )
        }
        self.init(rawValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
