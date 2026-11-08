/// The kind of an item. Raw values match Hacker News' `type` field.
///
/// Deleted items have no kind; use `Item.kind` (which is optional) or inspect
/// `Item.content`.
public enum ItemKind: String, Sendable, Hashable, CaseIterable, Codable {
    case story
    case comment
    case job
    case poll
    case pollOption = "pollopt"
}
