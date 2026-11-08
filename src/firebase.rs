use std::sync::Arc;

use chrono::{DateTime, TimeZone, Utc};
use serde::Deserialize;
use url::Url;

use crate::domain::*;
use crate::error::{HnError, Result};
use crate::http::{HttpRequest, HttpTransport, env_url};

#[derive(Debug, Deserialize)]
struct ItemDto {
    id: Option<u64>,
    deleted: Option<bool>,
    #[serde(rename = "type")]
    kind: Option<String>,
    by: Option<String>,
    time: Option<i64>,
    text: Option<String>,
    dead: Option<bool>,
    parent: Option<u64>,
    poll: Option<u64>,
    kids: Option<Vec<u64>>,
    url: Option<String>,
    score: Option<i64>,
    title: Option<String>,
    parts: Option<Vec<u64>>,
    descendants: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct UserDto {
    id: Option<String>,
    created: Option<i64>,
    karma: Option<i64>,
    about: Option<String>,
    submitted: Option<Vec<u64>>,
}

#[derive(Debug, Deserialize)]
struct UpdatesDto {
    items: Option<Vec<u64>>,
    profiles: Option<Vec<String>>,
}

pub struct FirebaseClient {
    http: Arc<dyn HttpTransport>,
    base: Url,
}

impl FirebaseClient {
    pub fn new(http: Arc<dyn HttpTransport>) -> Result<Self> {
        Ok(Self {
            http,
            base: env_url("HN_FIREBASE_URL", "https://hacker-news.firebaseio.com/v0/")?,
        })
    }

    pub async fn item(&self, id: ItemId) -> Result<Option<Item>> {
        let value = self.get(&format!("item/{}.json", id.0)).await?;
        if value.trim() == "null" {
            return Ok(None);
        }
        let dto: ItemDto =
            serde_json::from_str(&value).map_err(|error| HnError::Decoding(error.to_string()))?;
        Ok(Some(item_from_dto(dto)?))
    }

    pub async fn user(&self, id: &UserId) -> Result<Option<User>> {
        let value = self
            .get(&format!(
                "user/{}.json",
                url::form_urlencoded::byte_serialize(id.0.as_bytes()).collect::<String>()
            ))
            .await?;
        if value.trim() == "null" {
            return Ok(None);
        }
        let dto: UserDto =
            serde_json::from_str(&value).map_err(|error| HnError::Decoding(error.to_string()))?;
        Ok(Some(user_from_dto(dto)?))
    }

    pub async fn feed_ids(&self, feed: &Feed) -> Result<Vec<ItemId>> {
        let endpoint = match feed {
            Feed::FrontPage => "topstories.json",
            Feed::New => "newstories.json",
            Feed::Best => "beststories.json",
            Feed::Ask => "askstories.json",
            Feed::Show => "showstories.json",
            Feed::Jobs => "jobstories.json",
            _ => {
                return Err(HnError::Unsupported(format!(
                    "feed {} is not served by Firebase",
                    feed.label()
                )));
            }
        };
        let value = self.get(endpoint).await?;
        let ids: Vec<u64> =
            serde_json::from_str(&value).map_err(|error| HnError::Decoding(error.to_string()))?;
        Ok(ids.into_iter().filter(|id| *id > 0).map(ItemId).collect())
    }

    pub async fn updates(&self) -> Result<Updates> {
        let value = self.get("updates.json").await?;
        let dto: UpdatesDto =
            serde_json::from_str(&value).map_err(|error| HnError::Decoding(error.to_string()))?;
        Ok(Updates {
            item_ids: dto
                .items
                .unwrap_or_default()
                .into_iter()
                .filter(|id| *id > 0)
                .map(ItemId)
                .collect(),
            profile_ids: dto
                .profiles
                .unwrap_or_default()
                .into_iter()
                .map(UserId)
                .collect(),
        })
    }

    pub async fn max_item_id(&self) -> Result<ItemId> {
        let value = self.get("maxitem.json").await?;
        let id: u64 =
            serde_json::from_str(&value).map_err(|error| HnError::Decoding(error.to_string()))?;
        if id == 0 {
            return Err(HnError::Decoding("maxitem is not positive".into()));
        }
        Ok(ItemId(id))
    }

    async fn get(&self, path: &str) -> Result<String> {
        let url = self
            .base
            .join(path)
            .map_err(|error| HnError::InvalidInput(error.to_string()))?;
        let response = self.http.send(HttpRequest::get(url)).await?;
        if !(200..300).contains(&response.status) {
            return Err(HnError::Server(response.status));
        }
        Ok(response.text())
    }
}

fn item_from_dto(dto: ItemDto) -> Result<Item> {
    let id = dto
        .id
        .filter(|id| *id > 0)
        .map(ItemId)
        .ok_or_else(|| HnError::Decoding("Firebase item is missing a valid id".into()))?;
    let created_at = date_from_seconds(dto.time.unwrap_or(0));
    let author = dto.by.filter(|value| !value.is_empty()).map(UserId);
    let child_ids: Vec<ItemId> = dto
        .kids
        .unwrap_or_default()
        .into_iter()
        .filter(|id| *id > 0)
        .map(ItemId)
        .collect();
    let parent_id = dto.parent.filter(|id| *id > 0).map(ItemId);
    let flags = ItemFlags {
        deleted: dto.deleted.unwrap_or(false),
        dead: dto.dead.unwrap_or(false),
    };

    let kind = dto.kind.as_deref().and_then(|value| match value {
        "story" => Some(ItemKind::Story),
        "comment" => Some(ItemKind::Comment),
        "job" => Some(ItemKind::Job),
        "poll" => Some(ItemKind::Poll),
        "pollopt" => Some(ItemKind::PollOption),
        _ => None,
    });

    let Some(kind) = kind else {
        return Ok(Item {
            id,
            author,
            created_at,
            flags: ItemFlags {
                deleted: true,
                ..flags
            },
            content: ItemContent::Deleted(DeletedItem {
                parent_id,
                child_ids,
            }),
        });
    };

    if flags.deleted {
        return Ok(Item {
            id,
            author,
            created_at,
            flags,
            content: ItemContent::Deleted(DeletedItem {
                parent_id,
                child_ids,
            }),
        });
    }

    let text = dto.text.map(HtmlText);
    let title = HtmlText(dto.title.unwrap_or_default());
    let url = dto
        .url
        .filter(|value| !value.is_empty())
        .and_then(|value| Url::parse(&value).ok())
        .map(|url| url.to_string());

    let content = match kind {
        ItemKind::Story => ItemContent::Story(Story {
            title,
            url,
            text,
            score: dto.score.unwrap_or(0),
            comment_count: dto.descendants.unwrap_or(0),
            comment_ids: child_ids,
        }),
        ItemKind::Comment => {
            let Some(parent_id) = parent_id else {
                return Ok(Item {
                    id,
                    author,
                    created_at,
                    flags,
                    content: ItemContent::Deleted(DeletedItem {
                        parent_id: None,
                        child_ids,
                    }),
                });
            };
            ItemContent::Comment(Comment {
                parent_id,
                text: text.unwrap_or_else(HtmlText::empty),
                child_ids,
            })
        }
        ItemKind::Job => ItemContent::Job(Job {
            title,
            url,
            text,
            score: dto.score.unwrap_or(0),
        }),
        ItemKind::Poll => ItemContent::Poll(Poll {
            title,
            text,
            score: dto.score.unwrap_or(0),
            comment_count: dto.descendants.unwrap_or(0),
            comment_ids: child_ids,
            option_ids: dto
                .parts
                .unwrap_or_default()
                .into_iter()
                .filter(|id| *id > 0)
                .map(ItemId)
                .collect(),
        }),
        ItemKind::PollOption => {
            let Some(poll_id) = dto.poll.filter(|id| *id > 0).map(ItemId) else {
                return Ok(Item {
                    id,
                    author,
                    created_at,
                    flags,
                    content: ItemContent::Deleted(DeletedItem {
                        parent_id,
                        child_ids,
                    }),
                });
            };
            ItemContent::PollOption(PollOption {
                poll_id,
                text: text.unwrap_or_else(HtmlText::empty),
                score: dto.score.unwrap_or(0),
            })
        }
    };

    Ok(Item {
        id,
        author,
        created_at,
        flags,
        content,
    })
}

fn user_from_dto(dto: UserDto) -> Result<User> {
    let id = dto
        .id
        .filter(|value| !value.is_empty())
        .map(UserId)
        .ok_or_else(|| HnError::Decoding("Firebase user is missing a valid id".into()))?;
    Ok(User {
        id,
        created_at: date_from_seconds(dto.created.unwrap_or(0)),
        karma: dto.karma.unwrap_or(0),
        about: dto.about.map(HtmlText),
        submitted_item_ids: dto
            .submitted
            .unwrap_or_default()
            .into_iter()
            .filter(|id| *id > 0)
            .map(ItemId)
            .collect(),
    })
}

pub fn date_from_seconds(seconds: i64) -> DateTime<Utc> {
    Utc.timestamp_opt(seconds, 0)
        .single()
        .unwrap_or_else(|| Utc.timestamp_opt(0, 0).unwrap())
}
