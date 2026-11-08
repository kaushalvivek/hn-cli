import Foundation
import HackerNewsCore

struct AlgoliaSearchResponse: Decodable {
    let hits: [AlgoliaHit]
    let nbHits: Int
    let page: Int
    let nbPages: Int
    let hitsPerPage: Int?
    let query: String?
}

struct AlgoliaHit: Decodable {
    let objectID: String
    let author: String?
    let title: String?
    let url: String?
    let storyTitle: String?
    let storyText: String?
    let commentText: String?
    let createdAt: Int?
    let points: Int?
    let numComments: Int?
    let storyID: Int?
    let parentID: Int?
    let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case objectID
        case author
        case title
        case url
        case storyTitle = "story_title"
        case storyText = "story_text"
        case commentText = "comment_text"
        case createdAt = "created_at_i"
        case points
        case numComments = "num_comments"
        case storyID = "story_id"
        case parentID = "parent_id"
        case tags = "_tags"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .objectID) {
            objectID = stringID
        } else {
            objectID = String(try container.decode(Int.self, forKey: .objectID))
        }
        author = try container.decodeIfPresent(String.self, forKey: .author)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        storyTitle = try container.decodeIfPresent(String.self, forKey: .storyTitle)
        storyText = try container.decodeIfPresent(String.self, forKey: .storyText)
        commentText = try container.decodeIfPresent(String.self, forKey: .commentText)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
        points = try container.decodeIfPresent(Int.self, forKey: .points)
        numComments = try container.decodeIfPresent(Int.self, forKey: .numComments)
        storyID = try container.decodeIfPresent(Int.self, forKey: .storyID)
        parentID = try container.decodeIfPresent(Int.self, forKey: .parentID)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
    }

    func toDomain() throws -> SearchHit {
        guard let idValue = Int(objectID), let id = ItemID(validating: idValue) else {
            throw HackerNewsError.decoding("Algolia hit has an invalid objectID: \(objectID)")
        }

        let kind: ItemKind
        if tags?.contains("comment") == true {
            kind = .comment
        } else if tags?.contains("pollopt") == true {
            kind = .pollOption
        } else if tags?.contains("poll") == true {
            kind = .poll
        } else if tags?.contains("job") == true {
            kind = .job
        } else {
            kind = .story
        }

        return SearchHit(
            id: id,
            kind: kind,
            author: author.flatMap(UserID.init(validating:)),
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt ?? 0)),
            title: title.map(HTMLText.init),
            url: url.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            text: (kind == .comment ? commentText : storyText).map(HTMLText.init),
            score: points,
            commentCount: numComments,
            storyID: storyID.flatMap(ItemID.init(validating:)),
            storyTitle: storyTitle.map(HTMLText.init),
            parentID: parentID.flatMap(ItemID.init(validating:))
        )
    }
}
