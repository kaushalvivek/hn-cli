use std::sync::Arc;

use serde::Deserialize;
use url::Url;

use crate::domain::*;
use crate::error::{HnError, Result};
use crate::firebase::date_from_seconds;
use crate::http::{HttpRequest, HttpTransport, env_url};

#[derive(Debug, Deserialize)]
struct SearchResponse {
    #[serde(default)]
    hits: Vec<Hit>,
    #[serde(rename = "nbHits", default)]
    total_hits: u64,
    #[serde(rename = "nbPages", default)]
    page_count: u64,
    #[serde(rename = "hitsPerPage", default)]
    hits_per_page: u64,
}

#[derive(Debug, Deserialize)]
struct Hit {
    #[serde(rename = "objectID")]
    object_id: String,
    author: Option<String>,
    title: Option<String>,
    url: Option<String>,
    #[serde(rename = "story_title")]
    story_title: Option<String>,
    #[serde(rename = "story_text")]
    story_text: Option<String>,
    #[serde(rename = "comment_text")]
    comment_text: Option<String>,
    #[serde(rename = "created_at_i")]
    created_at: Option<i64>,
    points: Option<i64>,
    #[serde(rename = "num_comments")]
    num_comments: Option<u64>,
    #[serde(rename = "story_id")]
    story_id: Option<u64>,
    #[serde(rename = "parent_id")]
    parent_id: Option<u64>,
    #[serde(rename = "_tags", default)]
    tags: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct ItemDto {
    id: Option<u64>,
    author: Option<String>,
    #[serde(rename = "created_at_i")]
    created_at: Option<i64>,
    #[serde(rename = "type")]
    kind: Option<String>,
    title: Option<String>,
    url: Option<String>,
    text: Option<String>,
    points: Option<i64>,
    #[serde(rename = "parent_id")]
    parent_id: Option<u64>,
    #[serde(default)]
    children: Vec<ItemDto>,
}

pub struct AlgoliaClient {
    http: Arc<dyn HttpTransport>,
    base: Url,
}

impl AlgoliaClient {
    pub fn new(http: Arc<dyn HttpTransport>) -> Result<Self> {
        Ok(Self {
            http,
            base: env_url("HN_ALGOLIA_URL", "https://hn.algolia.com/api/v1/")?,
        })
    }

    pub async fn search(&self, query: &SearchQuery) -> Result<SearchResults> {
        let (hits, total_hits) = self.fetch_hits(query).await?;
        let page = query.page.page_number();
        let page_count = if total_hits == 0 {
            0
        } else {
            (total_hits + u64::from(query.page.limit) - 1) / u64::from(query.page.limit)
        };
        Ok(SearchResults {
            hits: hits
                .into_iter()
                .map(hit_to_domain)
                .collect::<Result<Vec<_>>>()?,
            total_hits,
            page,
            page_count,
            query: query.terms.clone(),
        })
    }

    pub async fn item_tree(&self, id: ItemId) -> Result<Thread> {
        let url = self
            .base
            .join(&format!("items/{}", id.0))
            .map_err(|error| HnError::InvalidInput(error.to_string()))?;
        let response = self.http.send(HttpRequest::get(url)).await?;
        if !(200..300).contains(&response.status) {
            return Err(HnError::Server(response.status));
        }
        let dto: ItemDto = serde_json::from_slice(&response.body)
            .map_err(|error| HnError::Decoding(error.to_string()))?;
        dto.into_thread()
    }

    async fn fetch_hits(&self, query: &SearchQuery) -> Result<(Vec<Hit>, u64)> {
        let requested_window = query
            .page
            .offset
            .saturating_add(u64::from(query.page.limit));
        let page_size = u64::from(query.page.limit)
            .max(requested_window)
            .clamp(1, 1000);
        let start_page = if requested_window <= 1000 {
            0
        } else {
            query.page.offset / 1000
        };
        let mut offset_within = if requested_window <= 1000 {
            query.page.offset
        } else {
            query.page.offset % 1000
        };

        let mut collected = Vec::new();
        let mut total_hits = 0;
        let mut page = start_page;

        while collected.len() < query.page.limit as usize {
            let mut url = self
                .base
                .join(if query.sort == SearchSort::Date {
                    "search_by_date"
                } else {
                    "search"
                })
                .map_err(|error| HnError::InvalidInput(error.to_string()))?;
            {
                let mut pairs = url.query_pairs_mut();
                pairs.append_pair("hitsPerPage", &page_size.to_string());
                pairs.append_pair("page", &page.to_string());
                if !query.terms.is_empty() {
                    pairs.append_pair("query", &query.terms);
                }
                let tags = tags_for(query);
                if !tags.is_empty() {
                    pairs.append_pair("tags", &tags.join(","));
                }
                let numeric = numeric_filters(query);
                if !numeric.is_empty() {
                    pairs.append_pair("numericFilters", &numeric.join(","));
                }
            }

            let response = self.http.send(HttpRequest::get(url)).await?;
            if !(200..300).contains(&response.status) {
                return Err(HnError::Server(response.status));
            }
            let result: SearchResponse = serde_json::from_slice(&response.body)
                .map_err(|error| HnError::Decoding(error.to_string()))?;
            total_hits = result.total_hits;
            let mut page_hits = result.hits;
            if offset_within > 0 {
                let drop = offset_within.min(page_hits.len() as u64) as usize;
                page_hits.drain(0..drop);
                offset_within -= drop as u64;
            }
            collected.extend(page_hits);

            if page + 1 >= result.page_count || result.hits_per_page == 0 {
                break;
            }
            page += 1;
        }

        collected.truncate(query.page.limit as usize);
        Ok((collected, total_hits))
    }
}

fn tags_for(query: &SearchQuery) -> Vec<String> {
    let mut tags = Vec::new();
    if !query.kinds.is_empty() {
        let kind_tags: Vec<&str> = query
            .kinds
            .iter()
            .map(|kind| match kind {
                ItemKind::Story => "story",
                ItemKind::Comment => "comment",
                ItemKind::Job => "job",
                ItemKind::Poll => "poll",
                ItemKind::PollOption => "pollopt",
            })
            .collect();
        if kind_tags.len() == 1 {
            tags.push(kind_tags[0].to_string());
        } else {
            tags.push(format!("({})", kind_tags.join(",")));
        }
    }
    if let Some(author) = &query.author {
        tags.push(format!("author_{}", author.0));
    }
    if let Some(story_id) = query.story_id {
        tags.push(format!("story_{}", story_id.0));
    }
    tags
}

fn numeric_filters(query: &SearchQuery) -> Vec<String> {
    let mut filters = Vec::new();
    if let Some(after) = query.created_after {
        filters.push(format!("created_at_i>{}", after.timestamp()));
    }
    if let Some(before) = query.created_before {
        filters.push(format!("created_at_i<{}", before.timestamp()));
    }
    if let Some(score) = query.minimum_score {
        filters.push(format!("points>={score}"));
    }
    if let Some(comments) = query.minimum_comments {
        filters.push(format!("num_comments>={comments}"));
    }
    filters
}

fn hit_to_domain(hit: Hit) -> Result<SearchHit> {
    let id = hit
        .object_id
        .parse::<u64>()
        .ok()
        .filter(|id| *id > 0)
        .map(ItemId)
        .ok_or_else(|| HnError::Decoding("Algolia hit has an invalid objectID".into()))?;

    let kind = if hit.tags.iter().any(|tag| tag == "comment") {
        ItemKind::Comment
    } else if hit.tags.iter().any(|tag| tag == "pollopt") {
        ItemKind::PollOption
    } else if hit.tags.iter().any(|tag| tag == "poll") {
        ItemKind::Poll
    } else if hit.tags.iter().any(|tag| tag == "job") {
        ItemKind::Job
    } else {
        ItemKind::Story
    };

    Ok(SearchHit {
        id,
        kind,
        author: hit.author.filter(|value| !value.is_empty()).map(UserId),
        created_at: date_from_seconds(hit.created_at.unwrap_or(0)),
        title: hit.title.map(HtmlText),
        url: hit.url.filter(|value| !value.is_empty()),
        text: if kind == ItemKind::Comment {
            hit.comment_text.map(HtmlText)
        } else {
            hit.story_text.map(HtmlText)
        },
        score: hit.points,
        comment_count: hit.num_comments,
        story_id: hit.story_id.filter(|id| *id > 0).map(ItemId),
        story_title: hit.story_title.map(HtmlText),
        parent_id: hit.parent_id.filter(|id| *id > 0).map(ItemId),
    })
}

impl ItemDto {
    fn into_thread(self) -> Result<Thread> {
        let root_id = self
            .id
            .filter(|id| *id > 0)
            .map(ItemId)
            .ok_or_else(|| HnError::Decoding("Algolia tree is missing its root id".into()))?;
        let root = self.make_item(root_id, true)?;
        let replies = self
            .children
            .iter()
            .map(|child| child.make_node())
            .collect::<Result<Vec<_>>>()?;
        let loaded = 1 + replies.iter().map(count_nodes).sum::<usize>();
        Ok(Thread {
            root,
            replies,
            loaded_item_count: loaded,
            missing_item_count: 0,
            is_complete: true,
        })
    }

    fn make_node(&self) -> Result<ThreadNode> {
        let id =
            self.id.filter(|id| *id > 0).map(ItemId).ok_or_else(|| {
                HnError::Decoding("Algolia tree has a child without an id".into())
            })?;
        let item = self.make_item(id, false)?;
        let replies = self
            .children
            .iter()
            .map(|child| child.make_node())
            .collect::<Result<Vec<_>>>()?;
        Ok(ThreadNode { item, replies })
    }

    fn make_item(&self, id: ItemId, is_root: bool) -> Result<Item> {
        let author = self
            .author
            .clone()
            .filter(|value| !value.is_empty())
            .map(UserId);
        let created_at = date_from_seconds(self.created_at.unwrap_or(0));
        let child_ids: Vec<ItemId> = self
            .children
            .iter()
            .filter_map(|child| child.id.filter(|id| *id > 0).map(ItemId))
            .collect();
        let parent_id = self.parent_id.filter(|id| *id > 0).map(ItemId);
        let text = self.text.clone().map(HtmlText);
        let url = self
            .url
            .clone()
            .filter(|value| !value.is_empty())
            .and_then(|value| Url::parse(&value).ok())
            .map(|url| url.to_string());

        let kind = self.kind.as_deref().and_then(|value| match value {
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
                    dead: false,
                },
                content: ItemContent::Deleted(DeletedItem {
                    parent_id,
                    child_ids,
                }),
            });
        };

        let comment_count = if is_root {
            self.children
                .iter()
                .map(|child| 1 + count_dto_children(child))
                .sum()
        } else {
            0
        };

        let content = match kind {
            ItemKind::Story => ItemContent::Story(Story {
                title: HtmlText(self.title.clone().unwrap_or_default()),
                url,
                text,
                score: self.points.unwrap_or(0),
                comment_count: comment_count as u64,
                comment_ids: child_ids,
            }),
            ItemKind::Comment => {
                let Some(parent_id) = parent_id else {
                    return Ok(Item {
                        id,
                        author,
                        created_at,
                        flags: ItemFlags {
                            deleted: true,
                            dead: false,
                        },
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
                title: HtmlText(self.title.clone().unwrap_or_default()),
                url,
                text,
                score: self.points.unwrap_or(0),
            }),
            ItemKind::Poll => ItemContent::Poll(Poll {
                title: HtmlText(self.title.clone().unwrap_or_default()),
                text,
                score: self.points.unwrap_or(0),
                comment_count: comment_count as u64,
                comment_ids: child_ids,
                option_ids: Vec::new(),
            }),
            ItemKind::PollOption => {
                let Some(poll_id) = parent_id else {
                    return Ok(Item {
                        id,
                        author,
                        created_at,
                        flags: ItemFlags {
                            deleted: true,
                            dead: false,
                        },
                        content: ItemContent::Deleted(DeletedItem {
                            parent_id: None,
                            child_ids,
                        }),
                    });
                };
                ItemContent::PollOption(PollOption {
                    poll_id,
                    text: text.unwrap_or_else(HtmlText::empty),
                    score: self.points.unwrap_or(0),
                })
            }
        };

        Ok(Item {
            id,
            author,
            created_at,
            flags: ItemFlags {
                deleted: false,
                dead: false,
            },
            content,
        })
    }
}

fn count_nodes(node: &ThreadNode) -> usize {
    1 + node.replies.iter().map(count_nodes).sum::<usize>()
}

fn count_dto_children(node: &ItemDto) -> usize {
    node.children
        .iter()
        .map(|child| 1 + count_dto_children(child))
        .sum()
}
