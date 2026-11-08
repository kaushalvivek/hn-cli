/// Fetches the items and profiles that changed recently.
public struct FetchUpdates: Sendable {
    private let provider: any UpdateProvider

    public init(provider: any UpdateProvider) {
        self.provider = provider
    }

    public func callAsFunction() async throws -> Updates {
        try await provider.updates()
    }
}
