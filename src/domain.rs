use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{HnError, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ItemId(pub u64);

impl std::fmt::Display for ItemId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

impl std::str::FromStr for ItemId {
    type Err = HnError;

    fn from_str(value: &str) -> Result<Self> {
        let id = value
            .parse::<u64>()
            .map_err(|_| HnError::InvalidInput(format!("invalid item id: {value}")))?;
        if id == 0 {
            return Err(HnError::InvalidInput("item id must be positive".into()));
        }
        Ok(Self(id))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct UserId(pub String);

impl std::fmt::Display for UserId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct CalendarDay {
    pub year: i32,
    pub month: u32,
    pub day: u32,
}

impl CalendarDay {
    pub fn new(year: i32, month: u32, day: u32) -> Result<Self> {
        if !(1..=9999).contains(&year) {
            return Err(HnError::InvalidInput(
                "year must be between 1 and 9999".into(),
            ));
        }
        if !(1..=12).contains(&month) {
            return Err(HnError::InvalidInput(
                "month must be between 1 and 12".into(),
            ));
        }
        let max_day = match month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 if is_leap_year(year) => 29,
            2 => 28,
            _ => unreachable!(),
        };
        if !(1..=max_day).contains(&day) {
            return Err(HnError::InvalidInput(format!(
                "day must be between 1 and {max_day} for this month"
            )));
        }
        Ok(Self { year, month, day })
    }

    pub fn yesterday() -> Self {
        let date = Utc::now().date_naive() - chrono::Days::new(1);
        use chrono::Datelike;
        Self {
            year: date.year(),
            month: date.month(),
            day: date.day(),
        }
    }

    pub fn parse(value: &str) -> Result<Self> {
        let mut parts = value.split('-');
        let year = parts
            .next()
            .and_then(|value| value.parse().ok())
            .ok_or_else(|| HnError::InvalidInput("expected YYYY-MM-DD".into()))?;
        let month = parts
            .next()
            .and_then(|value| value.parse().ok())
            .ok_or_else(|| HnError::InvalidInput("expected YYYY-MM-DD".into()))?;
        let day = parts
            .next()
            .and_then(|value| value.parse().ok())
            .ok_or_else(|| HnError::InvalidInput("expected YYYY-MM-DD".into()))?;
        if parts.next().is_some() {
            return Err(HnError::InvalidInput("expected YYYY-MM-DD".into()));
        }
        Self::new(year, month, day)
    }
}

impl std::fmt::Display for CalendarDay {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

fn is_leap_year(year: i32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct HtmlText(pub String);

impl HtmlText {
    pub fn empty() -> Self {
        Self(String::new())
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ItemFlags {
    pub deleted: bool,
    pub dead: bool,
}

impl ItemFlags {
    pub fn is_visible(self) -> bool {
        !self.deleted && !self.dead
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    Story,
    Comment,
    Job,
    Poll,
    #[serde(rename = "pollopt")]
    PollOption,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Story {
    pub title: HtmlText,
    pub url: Option<String>,
    pub text: Option<HtmlText>,
    pub score: i64,
    pub comment_count: u64,
    pub comment_ids: Vec<ItemId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Comment {
    pub parent_id: ItemId,
    pub text: HtmlText,
    pub child_ids: Vec<ItemId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Job {
    pub title: HtmlText,
    pub url: Option<String>,
    pub text: Option<HtmlText>,
    pub score: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Poll {
    pub title: HtmlText,
    pub text: Option<HtmlText>,
    pub score: i64,
    pub comment_count: u64,
    pub comment_ids: Vec<ItemId>,
    pub option_ids: Vec<ItemId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollOption {
    pub poll_id: ItemId,
    pub text: HtmlText,
    pub score: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeletedItem {
    pub parent_id: Option<ItemId>,
    pub child_ids: Vec<ItemId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "data", rename_all = "snake_case")]
pub enum ItemContent {
    Story(Story),
    Comment(Comment),
    Job(Job),
    Poll(Poll),
    #[serde(rename = "pollopt")]
    PollOption(PollOption),
    Deleted(DeletedItem),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: ItemId,
    pub author: Option<UserId>,
    pub created_at: DateTime<Utc>,
    pub flags: ItemFlags,
    pub content: ItemContent,
}

impl Item {
    pub fn kind(&self) -> Option<ItemKind> {
        match &self.content {
            ItemContent::Story(_) => Some(ItemKind::Story),
            ItemContent::Comment(_) => Some(ItemKind::Comment),
            ItemContent::Job(_) => Some(ItemKind::Job),
            ItemContent::Poll(_) => Some(ItemKind::Poll),
            ItemContent::PollOption(_) => Some(ItemKind::PollOption),
            ItemContent::Deleted(_) => None,
        }
    }

    pub fn child_ids(&self) -> &[ItemId] {
        match &self.content {
            ItemContent::Story(story) => &story.comment_ids,
            ItemContent::Comment(comment) => &comment.child_ids,
            ItemContent::Poll(poll) => &poll.comment_ids,
            ItemContent::Deleted(deleted) => &deleted.child_ids,
            ItemContent::Job(_) | ItemContent::PollOption(_) => &[],
        }
    }

    pub fn parent_id(&self) -> Option<ItemId> {
        match &self.content {
            ItemContent::Comment(comment) => Some(comment.parent_id),
            ItemContent::Deleted(deleted) => deleted.parent_id,
            _ => None,
        }
    }

    pub fn title(&self) -> Option<&HtmlText> {
        match &self.content {
            ItemContent::Story(story) => Some(&story.title),
            ItemContent::Job(job) => Some(&job.title),
            ItemContent::Poll(poll) => Some(&poll.title),
            _ => None,
        }
    }

    pub fn text(&self) -> Option<&HtmlText> {
        match &self.content {
            ItemContent::Story(story) => story.text.as_ref(),
            ItemContent::Comment(comment) => Some(&comment.text),
            ItemContent::Job(job) => job.text.as_ref(),
            ItemContent::Poll(poll) => poll.text.as_ref(),
            ItemContent::PollOption(option) => Some(&option.text),
            ItemContent::Deleted(_) => None,
        }
    }

    pub fn score(&self) -> Option<i64> {
        match &self.content {
            ItemContent::Story(story) => Some(story.score),
            ItemContent::Job(job) => Some(job.score),
            ItemContent::Poll(poll) => Some(poll.score),
            ItemContent::PollOption(option) => Some(option.score),
            ItemContent::Comment(_) | ItemContent::Deleted(_) => None,
        }
    }

    pub fn comment_count(&self) -> Option<u64> {
        match &self.content {
            ItemContent::Story(story) => Some(story.comment_count),
            ItemContent::Poll(poll) => Some(poll.comment_count),
            _ => None,
        }
    }

    pub fn url(&self) -> Option<&str> {
        match &self.content {
            ItemContent::Story(story) => story.url.as_deref(),
            ItemContent::Job(job) => job.url.as_deref(),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct User {
    pub id: UserId,
    pub created_at: DateTime<Utc>,
    pub karma: i64,
    pub about: Option<HtmlText>,
    pub submitted_item_ids: Vec<ItemId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", content = "data", rename_all = "snake_case")]
pub enum Feed {
    FrontPage,
    New,
    Best,
    Ask,
    Show,
    Jobs,
    Active,
    LatestComments,
    NoobStories,
    NoobComments,
    PastFrontPage(CalendarDay),
    FromSite(String),
}

impl Feed {
    pub fn label(&self) -> String {
        match self {
            Feed::FrontPage => "front".into(),
            Feed::New => "new".into(),
            Feed::Best => "best".into(),
            Feed::Ask => "ask".into(),
            Feed::Show => "show".into(),
            Feed::Jobs => "jobs".into(),
            Feed::Active => "active".into(),
            Feed::LatestComments => "comments".into(),
            Feed::NoobStories => "noob-stories".into(),
            Feed::NoobComments => "noob-comments".into(),
            Feed::PastFrontPage(day) => format!("past {day}"),
            Feed::FromSite(site) => format!("from {site}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadNode {
    pub item: Item,
    pub replies: Vec<ThreadNode>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Thread {
    pub root: Item,
    pub replies: Vec<ThreadNode>,
    pub loaded_item_count: usize,
    pub missing_item_count: usize,
    pub is_complete: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SearchSort {
    Relevance,
    Date,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchQuery {
    pub terms: String,
    pub kinds: Vec<ItemKind>,
    pub author: Option<UserId>,
    pub story_id: Option<ItemId>,
    pub sort: SearchSort,
    pub page: PageRequest,
    pub created_after: Option<DateTime<Utc>>,
    pub created_before: Option<DateTime<Utc>>,
    pub minimum_score: Option<i64>,
    pub minimum_comments: Option<u64>,
}

impl Default for SearchQuery {
    fn default() -> Self {
        Self {
            terms: String::new(),
            kinds: vec![ItemKind::Story],
            author: None,
            story_id: None,
            sort: SearchSort::Relevance,
            page: PageRequest::default(),
            created_after: None,
            created_before: None,
            minimum_score: None,
            minimum_comments: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchHit {
    pub id: ItemId,
    pub kind: ItemKind,
    pub author: Option<UserId>,
    pub created_at: DateTime<Utc>,
    pub title: Option<HtmlText>,
    pub url: Option<String>,
    pub text: Option<HtmlText>,
    pub score: Option<i64>,
    pub comment_count: Option<u64>,
    pub story_id: Option<ItemId>,
    pub story_title: Option<HtmlText>,
    pub parent_id: Option<ItemId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchResults {
    pub hits: Vec<SearchHit>,
    pub total_hits: u64,
    pub page: u64,
    pub page_count: u64,
    pub query: String,
}

impl SearchResults {
    pub fn has_more(&self) -> bool {
        self.page + 1 < self.page_count
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PageRequest {
    pub offset: u64,
    pub limit: u32,
}

impl Default for PageRequest {
    fn default() -> Self {
        Self {
            offset: 0,
            limit: 30,
        }
    }
}

impl PageRequest {
    pub fn new(offset: u64, limit: u32) -> Result<Self> {
        if limit == 0 || limit > 1000 {
            return Err(HnError::InvalidInput(
                "page limit must be between 1 and 1000".into(),
            ));
        }
        if offset > u64::MAX - u64::from(limit) {
            return Err(HnError::InvalidInput("page offset is too large".into()));
        }
        Ok(Self { offset, limit })
    }

    pub fn page_number(self) -> u64 {
        self.offset / u64::from(self.limit)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemPage {
    pub items: Vec<Item>,
    pub offset: u64,
    pub has_more: bool,
    pub total_count: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemIdPage {
    pub ids: Vec<ItemId>,
    pub offset: u64,
    pub has_more: bool,
    pub total_count: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Updates {
    pub item_ids: Vec<ItemId>,
    pub profile_ids: Vec<UserId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeaderboardEntry {
    pub user_id: UserId,
    pub karma: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UserActivityKind {
    Submissions,
    Comments,
    FavoriteStories,
    FavoriteComments,
    Upvoted,
    Hidden,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VoteDirection {
    Up,
    Down,
    Unvote,
}

impl VoteDirection {
    pub fn how(self) -> &'static str {
        match self {
            VoteDirection::Up => "up",
            VoteDirection::Down => "down",
            VoteDirection::Unvote => "un",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StorySubmission {
    pub title: String,
    pub url: Option<String>,
    pub text: Option<String>,
}

impl StorySubmission {
    pub fn new(
        title: impl Into<String>,
        url: Option<String>,
        text: Option<String>,
    ) -> Result<Self> {
        let title = title.into().trim().to_string();
        if title.is_empty() {
            return Err(HnError::InvalidInput(
                "story title must not be empty".into(),
            ));
        }
        let text = text
            .map(|text| text.trim().to_string())
            .filter(|text| !text.is_empty());
        if url.is_none() && text.is_none() {
            return Err(HnError::InvalidInput("a story needs a URL or text".into()));
        }
        Ok(Self { title, url, text })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommentSubmission {
    pub parent_id: ItemId,
    pub text: String,
}

impl CommentSubmission {
    pub fn new(parent_id: ItemId, text: impl Into<String>) -> Result<Self> {
        let text = text.into().trim().to_string();
        if text.is_empty() {
            return Err(HnError::InvalidInput(
                "comment text must not be empty".into(),
            ));
        }
        Ok(Self { parent_id, text })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn item_ids_must_be_positive() {
        assert_eq!("123".parse::<ItemId>().unwrap(), ItemId(123));
        assert!("0".parse::<ItemId>().is_err());
        assert!("-1".parse::<ItemId>().is_err());
        assert!("abc".parse::<ItemId>().is_err());
    }

    #[test]
    fn calendar_days_validate_real_dates() {
        assert!(CalendarDay::new(2024, 2, 29).is_ok());
        assert!(CalendarDay::new(2023, 2, 29).is_err());
        assert!(CalendarDay::new(2026, 13, 1).is_err());
        assert_eq!(
            CalendarDay::parse("2026-11-08").unwrap().to_string(),
            "2026-11-08"
        );
        assert!(CalendarDay::parse("2026-11").is_err());
    }

    #[test]
    fn page_requests_use_one_based_pages() {
        let page = PageRequest::new(60, 30).unwrap();
        assert_eq!(page.page_number(), 2);
        assert!(PageRequest::new(0, 0).is_err());
        assert!(PageRequest::new(0, 1001).is_err());
    }

    #[test]
    fn submissions_are_trimmed_and_validated() {
        let comment = CommentSubmission::new(ItemId(1), "  hello  ").unwrap();
        assert_eq!(comment.text, "hello");
        assert!(CommentSubmission::new(ItemId(1), "   ").is_err());

        assert!(StorySubmission::new("", None, Some("text".into())).is_err());
        assert!(StorySubmission::new("Title", None, None).is_err());
        let story = StorySubmission::new(" Title ", None, Some(" text ".into())).unwrap();
        assert_eq!(story.title, "Title");
        assert_eq!(story.text.as_deref(), Some("text"));
    }

    #[test]
    fn items_serialize_with_a_tagged_content_kind() {
        let item = Item {
            id: ItemId(1),
            author: Some(UserId("pg".into())),
            created_at: chrono::Utc.timestamp_opt(0, 0).unwrap(),
            flags: ItemFlags::default(),
            content: ItemContent::Story(Story {
                title: HtmlText("Hello".into()),
                url: Some("https://example.com".into()),
                text: None,
                score: 42,
                comment_count: 3,
                comment_ids: vec![ItemId(2)],
            }),
        };
        let value = serde_json::to_value(&item).unwrap();
        assert_eq!(value["content"]["kind"], "story");
        assert_eq!(value["content"]["data"]["score"], 42);
        assert_eq!(
            serde_json::to_value(ItemContent::PollOption(PollOption {
                poll_id: ItemId(1),
                text: HtmlText("option".into()),
                score: 1,
            }))
            .unwrap()["kind"],
            "pollopt"
        );
        let decoded: Item = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, item);
    }
}
