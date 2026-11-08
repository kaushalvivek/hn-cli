/// Reports changed items and profiles, and exposes the item high-water mark.
public protocol UpdateProvider: Sendable {
    func updates() async throws -> Updates
    func maxItemID() async throws -> ItemID
}
