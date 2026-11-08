# Hacker News domain model

This document defines the product we are modeling: **news.ycombinator.com**. It is not a model of the Firebase API, Algolia, or any other transport. Those are read/write projections of the product and sit behind ports in `HackerNewsCore`.

## 1. Sources of truth

| Source | What it provides | Limits |
| --- | --- | --- |
| news.ycombinator.com | The canonical product: ranking, feeds, threads, profiles, account actions | HTML, session cookies, per-page `auth`/`fnid` tokens |
| Firebase v0 API (`hacker-news.firebaseio.com/v0`) | Items, users, top/new/best/ask/show/job IDs, updates, max item ID | Read-only; no search; no account data; no write actions |
| Algolia (`hn.algolia.com/api/v1`) | Search (relevance and date), latest comments, item trees | Search-specific result shapes; pagination limits |
| HN HTML pages | Past front pages, latest comments, favorites, threads (comments by user), login and all write actions | Fragile; requires session where noted |

The domain model does not care which source is used. A single operation may be satisfied by Firebase, Algolia, HTML, or a combination.

## 2. Ubiquitous language

- **Item** — anything with an HN item ID: story, comment, job, poll, or poll option.
- **Story** — a link or text submission. Includes Ask HN and Show HN submissions.
- **Comment** — a reply to a story or another comment. Comments form a tree.
- **Job** — a job posting. Reads like a story but is not voted on in the same way.
- **Poll / Poll option** — a poll and its choices.
- **User** — an account, identified by a case-sensitive username.
- **Feed** — an ordered list of items: front page, new, best, ask, show, jobs, active threads, latest comments, noob stories/comments, a past front page, or submissions from one site.
- **Thread** — a root item and its comment tree.
- **Session** — an authenticated HN account. Required for personalized reads and all writes.
- **Flags** — items may be `dead` (moderated/hidden) or `deleted` (removed by author).
- **HTML text** — `title`, `text`, and `about` fields carry HTML, not plain text.

## 3. Value objects

| Type | Meaning | Invariants |
| --- | --- | --- |
| `ItemID` | Unique integer item identifier | Positive |
| `UserID` | Case-sensitive username | Non-empty; never case-folded |
| `CalendarDay` | A day used by the past-front-page archive | Valid Gregorian date |
| `HTMLText` | Raw HTML from an HN text field | Kept verbatim |
| `ItemFlags` | `dead` / `deleted` state | Option set |
| `PageRequest` | Offset/limit pagination | `offset >= 0`, `1...1000` limit |
| `ThreadLoadPolicy` | Bounds for recursive thread loading | Depth, node and concurrency limits |
| `SearchQuery` | Search terms, filters, sort and pagination | Semantic query; transport maps to Algolia |
| `VoteDirection` | `up`, `down`, `unvote` | — |

Time is an absolute instant (`Date`). The API's Unix seconds are converted at the transport boundary. `CalendarDay` is intentionally timezone-free because the archive URL is `front?day=YYYY-MM-DD`.

## 4. Entities and aggregates

### Item

`Item` is the aggregate root for content:

```
Item
  id: ItemID
  author: UserID?
  createdAt: Date
  flags: ItemFlags
  content:
    .story(Story)
    .comment(Comment)
    .job(Job)
    .poll(Poll)
    .pollOption(PollOption)
    .deleted(DeletedItem)
```

- Shared metadata stays on `Item`; type-specific fields live in the content value.
- `Story` carries title, optional URL/text, score, comment count, child comment IDs.
- `Comment` carries parent ID, text, child comment IDs.
- `Job` carries title, optional URL/text, score.
- `Poll` carries title, optional text, score, comment count, comment IDs, option IDs.
- `PollOption` carries poll ID, text, score.
- `DeletedItem` preserves parent ID and child IDs so a deleted comment does not break the thread structure.
- `Item.childIDs` is the ordered list used to traverse a thread.

### User

```
User
  id: UserID
  createdAt: Date
  karma: Int
  about: HTMLText?
  submittedItemIDs: [ItemID]
```

`submittedItemIDs` is ordered newest-first as returned by HN. Only users with public activity are retrievable.

### Thread

A read model, not an aggregate that owns the comments:

```
Thread
  root: Item
  replies: [ThreadNode]     // top-level comments, ordered
  loadedItemCount: Int
  missingItemCount: Int
  isComplete: Bool

ThreadNode
  item: Item
  replies: [ThreadNode]
```

Threads are loaded lazily from child IDs. HN does not return a whole thread in one request, so `LoadThread` performs a bounded breadth-first traversal. `isComplete` is false if the policy truncated the tree or an item could not be fetched.

### Feed page / item page

```
ItemPage
  items: [Item]
  offset: Int
  hasMore: Bool
  totalCount: Int?
```

Order is always the source order (rank, recency, or relevance), never the order in which requests completed.

### Search

Search hits are a projection, not full items:

```
SearchHit
  id, kind, author, createdAt
  title?, url?, text?
  score?, commentCount?
  storyID?, parentID?

SearchResults
  hits, totalHits, page, pageCount, query
```

### Session and account

```
UserSession(userID)
StorySubmission(title, url?, text?)
CommentSubmission(parentID, text)
```

Credentials and session tokens are transport concerns and never live in the domain. `AccountProvider` exposes the intent (`logIn`, `signUp`, `vote`, `submitStory`, `comment`, `edit`, `delete`, `favorite`, `hide`, `flag`, `unflag`, `logOut`).

## 5. Operations

### Public reads (no session)

| Operation | Description | Backing source |
| --- | --- | --- |
| Browse feed | Front page, new, best, ask, show, jobs, active, noob stories/comments | Firebase feed IDs + items, or HN HTML |
| Latest comments | Newest comments site-wide | HN `newcomments` HTML or Algolia |
| Past front page | Front page for a `CalendarDay` | HN `front?day=` HTML |
| Submissions from a site | Stories from one domain | HN `from?site=` HTML |
| Leaders | Top users by karma | HN `leaders` HTML |
| Fetch item | One item by ID | Firebase or Algolia |
| Load thread | Root item plus comment tree within a policy | Firebase item traversal |
| Fetch user | Profile by username | Firebase |
| Fetch user submissions | A page of a user's submissions | Firebase user + items |
| Fetch user comments | A page of a user's comments/threads | HN `threads` HTML or Algolia |
| Fetch favorites | Public favorites (stories or comments) | HN `favorites` HTML |
| Search | Stories/comments by relevance or date, with filters | Algolia |
| Fetch updates | Changed item IDs and profile IDs | Firebase `updates` |
| Fetch max item | Latest item ID for discovery | Firebase `maxitem` |

### Authenticated reads

| Operation | Description |
| --- | --- |
| Current session | The signed-in account, if any |
| Upvoted items | Items the signed-in user has upvoted |
| Hidden items | Items the signed-in user has hidden |

### Writes (unofficial; session + page tokens)

| Operation | Description |
| --- | --- |
| Log in / sign up / log out | Establish or end a session |
| Vote / unvote / downvote | Vote on a story or comment |
| Submit story | Link or text submission, with title |
| Post comment / reply | Comment on a story or comment |
| Edit | Edit an owned item |
| Delete | Delete an owned item |
| Favorite / unfavorite | Add/remove from favorites |
| Hide / unhide | Hide/unhide from the signed-in user's view |
| Flag / unflag | Report an item, or remove a report |

HN has **no official write API**. These actions use the site's HTML forms, session cookies, and per-page `auth`/`fnid`/`hmac` tokens. They are implemented in `HackerNewsAdapters` and exposed by the CLI; because they depend on HN's markup, they are the most fragile part of the client.

## 6. Invariants and edge cases

- **IDs:** item IDs are positive integers; user IDs are case-sensitive strings.
- **Rank order:** feed order is meaningful and must be preserved through concurrent item fetching.
- **HTML:** titles, text, and about fields are HTML. Rendering (plain text for the CLI, attributed text for iOS) is a presentation concern; the domain keeps raw HTML.
- **Deleted and dead items:** `deleted` items lose their text/author but keep ID, parent, time, and often kids. `dead` items keep their content but are not normally shown. Both must remain representable so threads do not lose children.
- **Missing items:** HN may return `null` for an item ID. Thread loading records the miss and continues; feeds simply omit the item.
- **Feed sizes:** Firebase exposes up to 500 top/new/best IDs and 200 ask/show/job IDs. The domain paginates over whatever the provider returns.
- **Comment counts:** `descendants` is HN's total comment count and can exceed the number of comments currently loaded.
- **Pagination:** feeds paginate over a fixed ID list; search paginates by page; HTML pages have their own pagination. `PageRequest` is the common offset/limit abstraction.
- **Search tags/numeric filters:** domain filters (`author`, `story`, `createdAfter`, `minimumScore`, …) are semantic; Algolia tag and numeric-filter syntax belongs to the adapter.
- **No rate limit** is documented for the Firebase API, but that is not a guarantee. Algolia has its own limits.
- **Auth is brittle:** write operations depend on HTML structure and tokens. They must fail explicitly, never silently.
- **Unsupported reads:** `upvoted` and `hidden` redirect to login when signed out. The adapter should surface `.unauthenticated`.

## 7. What is intentionally not modeled

- HN moderation powers (moderators, vouching, banning).
- Email/password recovery flows.
- Scraping, ranking, and anti-abuse internals.
- Notifications (HN has no notification feed).
- Presentation concerns: typography, HTML rendering, link previews, ranking heuristics.

## 8. Package boundaries

```
Domain      pure Swift values and read models; no networking
Ports       narrow capabilities: ItemProvider, FeedProvider, UserProvider,
            UserActivityProvider, SearchProvider, UpdateProvider,
            LeaderboardProvider, AccountProvider
Operations  orchestration: FetchFeedPage, LoadThread, FetchUserSubmissions, ...
Adapters    Firebase, Algolia, HN HTML/session (HackerNewsAdapters)
Interfaces  CLI (Sources/hn); iOS app (future)
```

The domain depends on nothing but Foundation. The CLI and iOS app depend on the domain. Adapters implement ports and translate transport errors into `HackerNewsError`.
