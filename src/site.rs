use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};
use percent_encoding::percent_decode_str;
use scraper::{ElementRef, Html, Selector};
use serde::{Deserialize, Serialize};
use url::Url;

use crate::domain::*;
use crate::error::{HnError, Result};
use crate::http::{HttpRequest, HttpResponse, HttpTransport, env_url, form_encode};

const MAX_HTML_PAGES: usize = 25;

pub fn config_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("HN_CONFIG_DIR")
        && !dir.is_empty()
    {
        return PathBuf::from(dir);
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".config/hn")
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StoredSession {
    pub cookie: String,
    pub username: UserId,
    pub saved_at: DateTime<Utc>,
}

pub fn load_session() -> Option<StoredSession> {
    let path = config_dir().join("session.json");
    let data = fs::read(path).ok()?;
    serde_json::from_slice(&data).ok()
}

pub fn save_session(session: &StoredSession) -> Result<()> {
    let dir = config_dir();
    fs::create_dir_all(&dir).map_err(|error| HnError::Transport(error.to_string()))?;
    set_private_dir(&dir)?;
    let path = dir.join("session.json");
    let data =
        serde_json::to_vec_pretty(session).map_err(|error| HnError::Decoding(error.to_string()))?;
    fs::write(&path, data).map_err(|error| HnError::Transport(error.to_string()))?;
    set_private_file(&path)?;
    Ok(())
}

pub fn clear_session() -> Result<()> {
    let path = config_dir().join("session.json");
    if path.exists() {
        fs::remove_file(path).map_err(|error| HnError::Transport(error.to_string()))?;
    }
    Ok(())
}

#[cfg(unix)]
fn set_private_dir(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .map_err(|error| HnError::Transport(error.to_string()))
}

#[cfg(not(unix))]
fn set_private_dir(_: &std::path::Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn set_private_file(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|error| HnError::Transport(error.to_string()))
}

#[cfg(not(unix))]
fn set_private_file(_: &std::path::Path) -> Result<()> {
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LoginCredentials {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UserSession {
    pub user_id: UserId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SiteFeedEntry {
    pub id: ItemId,
    pub kind: ItemKind,
    pub title: Option<String>,
    pub url: Option<String>,
    pub text: Option<HtmlText>,
    pub author: Option<UserId>,
    pub created_at: DateTime<Utc>,
    pub score: Option<i64>,
    pub comment_count: Option<u64>,
    pub story_id: Option<ItemId>,
    pub story_title: Option<String>,
    pub parent_id: Option<ItemId>,
    pub is_dead: bool,
    pub is_deleted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteFeedPage {
    pub entries: Vec<SiteFeedEntry>,
    pub offset: u64,
    pub has_more: bool,
    pub total_count: Option<u64>,
}

pub struct SiteClient {
    http: Arc<dyn HttpTransport>,
    base: Url,
    session: tokio::sync::RwLock<Option<StoredSession>>,
    auth_token: tokio::sync::RwLock<Option<String>>,
}

impl SiteClient {
    pub fn new(http: Arc<dyn HttpTransport>) -> Result<Self> {
        Ok(Self {
            http,
            base: env_url("HN_SITE_URL", "https://news.ycombinator.com/")?,
            session: tokio::sync::RwLock::new(load_session()),
            auth_token: tokio::sync::RwLock::new(None),
        })
    }

    pub async fn current_session(&self) -> Option<UserSession> {
        self.session
            .read()
            .await
            .as_ref()
            .map(|session| UserSession {
                user_id: session.username.clone(),
            })
    }

    pub async fn validate_session(&self) -> Result<Option<UserSession>> {
        if self.session.read().await.is_none() {
            return Ok(None);
        }
        let response = self.request("news", "GET", None, true, None, true).await?;
        if page_is_login(&response.text())? {
            let mut session = self.session.write().await;
            *session = None;
            *self.auth_token.write().await = None;
            clear_session()?;
            return Ok(None);
        }
        Ok(self.current_session().await)
    }

    pub async fn login(&self, credentials: &LoginCredentials) -> Result<UserSession> {
        self.authenticate(
            vec![
                ("goto".into(), "news".into()),
                ("acct".into(), credentials.username.clone()),
                ("pw".into(), credentials.password.clone()),
            ],
            false,
        )
        .await
    }

    pub async fn signup(&self, credentials: &LoginCredentials) -> Result<UserSession> {
        self.authenticate(
            vec![
                ("creating".into(), "t".into()),
                ("goto".into(), "news".into()),
                ("acct".into(), credentials.username.clone()),
                ("pw".into(), credentials.password.clone()),
            ],
            true,
        )
        .await
    }

    async fn authenticate(
        &self,
        fields: Vec<(String, String)>,
        signup: bool,
    ) -> Result<UserSession> {
        let response = self
            .request("login", "POST", Some(&fields), false, None, false)
            .await?;
        let text = response.text();
        if text.contains("Bad login") {
            return Err(HnError::InvalidCredentials);
        }
        if text.contains("Validation required") {
            return Err(HnError::Unsupported(
                "Hacker News requires browser validation to log in".into(),
            ));
        }
        if text.contains("Sorry") {
            return Err(if signup {
                HnError::InvalidInput("Hacker News rejected the account creation".into())
            } else {
                HnError::InvalidCredentials
            });
        }

        let Some(cookie) = user_cookie(&response) else {
            return Err(if signup {
                HnError::InvalidInput("Hacker News rejected the account creation".into())
            } else {
                HnError::InvalidCredentials
            });
        };
        let Some(username) = username_from_cookie(&cookie) else {
            return Err(HnError::InvalidCredentials);
        };

        let stored = StoredSession {
            cookie,
            username: username.clone(),
            saved_at: Utc::now(),
        };
        save_session(&stored)?;
        *self.session.write().await = Some(stored);
        *self.auth_token.write().await = None;
        Ok(UserSession { user_id: username })
    }

    pub async fn logout(&self) -> Result<()> {
        if self.session.read().await.is_none() {
            clear_session()?;
            return Ok(());
        }
        if let Some(token) = self.auth_token().await {
            let _ = self
                .request(
                    &format!("logout?auth={}&goto=news", form_encode_pair(&token)),
                    "GET",
                    None,
                    true,
                    None,
                    true,
                )
                .await;
        } else {
            let _ = self
                .request("logout?goto=news", "GET", None, true, None, true)
                .await;
        }
        *self.session.write().await = None;
        *self.auth_token.write().await = None;
        clear_session()?;
        Ok(())
    }

    pub async fn feed_entries(&self, feed: &Feed, page: PageRequest) -> Result<SiteFeedPage> {
        let (path, default_kind) = match feed {
            Feed::FrontPage => ("news".to_string(), ItemKind::Story),
            Feed::New => ("newest".to_string(), ItemKind::Story),
            Feed::Best => ("best".to_string(), ItemKind::Story),
            Feed::Ask => ("ask".to_string(), ItemKind::Story),
            Feed::Show => ("show".to_string(), ItemKind::Story),
            Feed::Jobs => ("jobs".to_string(), ItemKind::Job),
            Feed::Active => ("active".to_string(), ItemKind::Story),
            Feed::LatestComments => ("newcomments".to_string(), ItemKind::Comment),
            Feed::NoobStories => ("noobstories".to_string(), ItemKind::Story),
            Feed::NoobComments => ("noobcomments".to_string(), ItemKind::Comment),
            Feed::PastFrontPage(day) => (format!("front?day={day}"), ItemKind::Story),
            Feed::FromSite(site) => (
                format!(
                    "from?site={}",
                    url::form_urlencoded::byte_serialize(site.as_bytes()).collect::<String>()
                ),
                ItemKind::Story,
            ),
        };
        self.paged_entries(&path, page, default_kind, false).await
    }

    pub async fn activity_entries(
        &self,
        user_id: &UserId,
        activity: UserActivityKind,
        page: PageRequest,
    ) -> Result<SiteFeedPage> {
        let username =
            url::form_urlencoded::byte_serialize(user_id.0.as_bytes()).collect::<String>();
        let (path, default_kind, auth_required) = match activity {
            UserActivityKind::Submissions => {
                return Err(HnError::Unsupported(
                    "submissions are served by Firebase".into(),
                ));
            }
            UserActivityKind::Comments => {
                (format!("threads?id={username}"), ItemKind::Comment, false)
            }
            UserActivityKind::FavoriteStories => {
                (format!("favorites?id={username}"), ItemKind::Story, false)
            }
            UserActivityKind::FavoriteComments => (
                format!("favorites?id={username}&comments=t"),
                ItemKind::Comment,
                false,
            ),
            UserActivityKind::Upvoted => {
                let session = self.require_session().await?;
                if session.username != *user_id {
                    return Err(HnError::Unauthorized);
                }
                ("upvoted".to_string(), ItemKind::Story, true)
            }
            UserActivityKind::Hidden => {
                let session = self.require_session().await?;
                if session.username != *user_id {
                    return Err(HnError::Unauthorized);
                }
                ("hidden".to_string(), ItemKind::Story, true)
            }
        };
        self.paged_entries(&path, page, default_kind, auth_required)
            .await
    }

    async fn paged_entries(
        &self,
        start_path: &str,
        page: PageRequest,
        default_kind: ItemKind,
        auth_required: bool,
    ) -> Result<SiteFeedPage> {
        let mut path = start_path.to_string();
        let mut entries: Vec<SiteFeedEntry> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut more = None;
        let target = page.offset + u64::from(page.limit);
        let mut pages = 0;

        while pages < MAX_HTML_PAGES {
            let response = self.request(&path, "GET", None, true, None, true).await?;
            if auth_required {
                self.ensure_not_login_page(&response).await?;
            }
            let document = parse_document(&response.text())?;
            if auth_required && is_login_page(&document) {
                return Err(HnError::Unauthenticated);
            }
            for entry in parse_feed_entries(&document, default_kind)? {
                if seen.insert(entry.id) {
                    entries.push(entry);
                }
            }
            more = more_link(&document);
            pages += 1;
            if entries.len() as u64 >= target || more.is_none() {
                break;
            }
            path = more.clone().unwrap();
        }

        if page.offset >= entries.len() as u64 {
            return Ok(SiteFeedPage {
                entries: Vec::new(),
                offset: page.offset,
                has_more: false,
                total_count: None,
            });
        }
        let start = page.offset as usize;
        let end = (start + page.limit as usize).min(entries.len());
        let slice = entries[start..end].to_vec();
        Ok(SiteFeedPage {
            entries: slice,
            offset: page.offset,
            has_more: end < entries.len() || more.is_some(),
            total_count: None,
        })
    }

    pub async fn leaders(&self) -> Result<Vec<LeaderboardEntry>> {
        let response = self
            .request("leaders", "GET", None, true, None, true)
            .await?;
        let document = parse_document(&response.text())?;
        parse_leaders(&document)
    }

    async fn request(
        &self,
        path: &str,
        method: &str,
        fields: Option<&[(String, String)]>,
        follow_redirects: bool,
        referer: Option<&str>,
        send_cookies: bool,
    ) -> Result<HttpResponse> {
        let url = self
            .base
            .join(path)
            .map_err(|error| HnError::InvalidInput(error.to_string()))?;
        let mut headers = vec![
            (
                "Accept".into(),
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".into(),
            ),
            ("Accept-Language".into(), "en-US,en;q=0.9".into()),
            ("Origin".into(), self.base.origin().ascii_serialization()),
            (
                "Referer".into(),
                referer
                    .map(|value| self.base.join(value).map(|url| url.to_string()))
                    .transpose()
                    .map_err(|error| HnError::InvalidInput(error.to_string()))?
                    .unwrap_or_else(|| self.base.to_string()),
            ),
        ];
        if send_cookies && let Some(session) = self.session.read().await.as_ref() {
            headers.push(("Cookie".into(), format!("user={}", session.cookie)));
        }
        let body = fields.map(|fields| form_encode(fields).into_bytes());
        if fields.is_some() {
            headers.push((
                "Content-Type".into(),
                "application/x-www-form-urlencoded".into(),
            ));
        }
        self.http
            .send(HttpRequest {
                method: method.into(),
                url,
                headers,
                body,
                follow_redirects,
            })
            .await
    }

    async fn require_session(&self) -> Result<StoredSession> {
        self.session
            .read()
            .await
            .clone()
            .ok_or(HnError::Unauthenticated)
    }

    async fn auth_token(&self) -> Option<String> {
        if let Some(token) = self.auth_token.read().await.clone() {
            return Some(token);
        }
        if let Ok(response) = self.request("news", "GET", None, true, None, true).await
            && let Some(token) = find_auth_token(&response.text())
        {
            *self.auth_token.write().await = Some(token.clone());
            return Some(token);
        }
        self.session
            .read()
            .await
            .as_ref()
            .and_then(|session| auth_token_from_cookie(&session.cookie))
    }

    async fn ensure_not_login_page(&self, response: &HttpResponse) -> Result<()> {
        if response.final_url.path().contains("/login") {
            return Err(HnError::Unauthenticated);
        }
        let text = response.text();
        if text.contains("name=\"acct\"") && text.contains("name=\"pw\"") {
            return Err(HnError::Unauthenticated);
        }
        Ok(())
    }
}

fn user_cookie(response: &HttpResponse) -> Option<String> {
    for value in response.set_cookie_headers() {
        let value = value.trim_start();
        if let Some(cookie) = value.strip_prefix("user=") {
            let cookie = cookie.split(';').next().unwrap_or_default();
            if !cookie.is_empty() {
                return Some(cookie.to_string());
            }
        }
    }
    None
}

fn username_from_cookie(cookie: &str) -> Option<UserId> {
    let decoded = percent_decode_str(cookie).decode_utf8_lossy();
    decoded
        .split('&')
        .next()
        .filter(|value| !value.is_empty())
        .map(|value| UserId(value.to_string()))
}

fn auth_token_from_cookie(cookie: &str) -> Option<String> {
    let decoded = percent_decode_str(cookie).decode_utf8_lossy();
    let mut parts = decoded.split('&');
    let _ = parts.next();
    parts
        .next_back()
        .filter(|value| value.len() >= 8)
        .map(|value| value.to_string())
}

fn find_auth_token(html: &str) -> Option<String> {
    let normalized = html.replace("&amp;", "&");
    let index = normalized.find("auth=")?;
    let token: String = normalized[index + 5..]
        .chars()
        .take_while(|character| character.is_ascii_alphanumeric())
        .collect();
    if token.len() >= 8 { Some(token) } else { None }
}

fn form_encode_pair(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect()
}

fn parse_document(html: &str) -> Result<Html> {
    Ok(Html::parse_document(html))
}

// Keep every `Html` value inside a synchronous helper: `scraper::Html` is not
// `Send`, and holding one across an `.await` would make the whole client
// future non-`Send` for the TUI's spawned tasks.
fn page_is_login(html: &str) -> Result<bool> {
    let document = parse_document(html)?;
    Ok(is_login_page(&document))
}

fn form_in_html(
    html: &str,
    input_name: Option<&str>,
    textarea: bool,
) -> Result<Option<ParsedForm>> {
    let document = parse_document(html)?;
    Ok(find_form_in_document(&document, input_name, textarea))
}

fn comment_form_in_html(html: &str) -> Result<Option<ParsedForm>> {
    let document = parse_document(html)?;
    Ok(find_form_in_document(&document, None, true)
        .or_else(|| find_form_in_document(&document, Some("hmac"), false)))
}

fn edit_form_in_html(html: &str) -> Result<Option<ParsedForm>> {
    let document = parse_document(html)?;
    Ok(find_form_in_document(&document, None, true))
}

fn delete_form_in_html(html: &str) -> Result<Option<ParsedForm>> {
    let document = parse_document(html)?;
    Ok(find_form_in_document(&document, Some("fnid"), false)
        .or_else(|| find_form_by_action(&document, "xdelete")))
}

fn is_login_page(document: &Html) -> bool {
    let acct = Selector::parse("input[name=acct]").expect("selector");
    let pw = Selector::parse("input[name=pw]").expect("selector");
    document.select(&acct).next().is_some() && document.select(&pw).next().is_some()
}

fn more_link(document: &Html) -> Option<String> {
    let selector = Selector::parse("a.morelink").expect("selector");
    document
        .select(&selector)
        .next()
        .and_then(|link| link.value().attr("href"))
        .map(|href| href.replace("&amp;", "&"))
}

fn parse_feed_entries(document: &Html, default_kind: ItemKind) -> Result<Vec<SiteFeedEntry>> {
    let row_selector = Selector::parse("tr").expect("selector");
    let rows: Vec<ElementRef> = document.select(&row_selector).collect();
    let mut entries = Vec::new();

    for (index, row) in rows.iter().enumerate() {
        let classes = row.value().classes().collect::<Vec<_>>();
        if !classes.contains(&"athing") {
            continue;
        }
        let Some(id) = row
            .value()
            .attr("id")
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|id| *id > 0)
            .map(ItemId)
        else {
            continue;
        };

        if let Some(title_line) = first_select(row, "span.titleline > a") {
            let title = title_line.text().collect::<String>().trim().to_string();
            let href = title_line.value().attr("href").unwrap_or_default();
            let url = if href.starts_with("item?id=") || href.is_empty() {
                None
            } else {
                Some(href.to_string())
            };

            let subtext = rows[index + 1..]
                .iter()
                .take_while(|row| !row.value().classes().any(|class| class == "athing"))
                .find_map(|row| first_select(row, ".subtext"));

            let score = subtext
                .and_then(|subtext| first_select(&subtext, "span.score"))
                .and_then(|score| first_number(&score.text().collect::<String>()));
            let author = subtext
                .and_then(|subtext| first_select(&subtext, "a[href^='user?id=']"))
                .and_then(|link| link.value().attr("href"))
                .and_then(|href| query_value(href, "id"))
                .map(UserId);
            let created_at = subtext
                .and_then(|subtext| first_select(&subtext, "span.age"))
                .and_then(|age| age.value().attr("title"))
                .map(parse_age)
                .unwrap_or_else(|| Utc.timestamp_opt(0, 0).unwrap());
            let comment_count = subtext
                .and_then(|subtext| {
                    let selector = Selector::parse("a[href^='item?id=']").expect("selector");
                    let links = subtext.select(&selector);
                    links
                        .filter_map(|link| first_number(&link.text().collect::<String>()))
                        .last()
                })
                .map(|value| value as u64);

            entries.push(SiteFeedEntry {
                id,
                kind: if default_kind == ItemKind::Job {
                    ItemKind::Job
                } else {
                    ItemKind::Story
                },
                title: if title.is_empty() { None } else { Some(title) },
                url,
                text: None,
                author,
                created_at,
                score,
                comment_count,
                story_id: Some(id),
                story_title: None,
                parent_id: None,
                is_dead: false,
                is_deleted: false,
            });
            continue;
        }

        let Some(comment_text) = first_select(row, "div.commtext") else {
            continue;
        };
        let comhead = first_select(row, ".comhead");
        let author = comhead
            .and_then(|comhead| first_select(&comhead, "a[href^='user?id=']"))
            .and_then(|link| link.value().attr("href"))
            .and_then(|href| query_value(href, "id"))
            .map(UserId);
        let created_at = comhead
            .and_then(|comhead| first_select(&comhead, "span.age"))
            .and_then(|age| age.value().attr("title"))
            .map(parse_age)
            .unwrap_or_else(|| Utc.timestamp_opt(0, 0).unwrap());
        let parent_id = comhead
            .and_then(|comhead| {
                comhead
                    .select(&Selector::parse("a[href^='item?id=']").expect("selector"))
                    .find(|link| link.text().collect::<String>().trim() == "parent")
            })
            .and_then(|link| link.value().attr("href"))
            .and_then(|href| query_value(href, "id"))
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|id| *id > 0)
            .map(ItemId);
        let (story_id, story_title) = comhead
            .and_then(|comhead| first_select(&comhead, "span.onstory a"))
            .map(|link| {
                (
                    link.value()
                        .attr("href")
                        .and_then(|href| query_value(href, "id"))
                        .and_then(|value| value.parse::<u64>().ok())
                        .filter(|id| *id > 0)
                        .map(ItemId),
                    Some(link.text().collect::<String>().trim().to_string()),
                )
            })
            .unwrap_or((None, None));
        let plain = comment_text.text().collect::<String>();
        let plain = plain.trim();
        let is_deleted = plain == "[deleted]";
        let is_dead = plain == "[dead]";

        entries.push(SiteFeedEntry {
            id,
            kind: ItemKind::Comment,
            title: None,
            url: None,
            text: if is_deleted {
                None
            } else {
                Some(HtmlText(comment_text.inner_html()))
            },
            author,
            created_at,
            score: None,
            comment_count: None,
            story_id,
            story_title,
            parent_id,
            is_dead,
            is_deleted,
        });
    }

    Ok(entries)
}

fn first_select<'a>(element: &ElementRef<'a>, selector: &str) -> Option<ElementRef<'a>> {
    let selector = Selector::parse(selector).ok()?;
    element.select(&selector).next()
}

fn query_value(href: &str, name: &str) -> Option<String> {
    let url = if href.starts_with("http") {
        Url::parse(href).ok()?
    } else {
        Url::parse(&format!("https://news.ycombinator.com/{href}")).ok()?
    };
    url.query_pairs()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.into_owned())
}

fn first_number(value: &str) -> Option<i64> {
    value
        .split(|character: char| !character.is_ascii_digit())
        .find(|part| !part.is_empty())
        .and_then(|part| part.parse().ok())
}

fn parse_age(value: &str) -> DateTime<Utc> {
    NaiveDateTime::parse_from_str(value.trim(), "%Y-%m-%dT%H:%M:%S")
        .map(|date| date.and_utc())
        .unwrap_or_else(|_| Utc.timestamp_opt(0, 0).unwrap())
}

fn parse_leaders(document: &Html) -> Result<Vec<LeaderboardEntry>> {
    let row_selector = Selector::parse("tr.athing").expect("selector");
    let link_selector = Selector::parse("a[href^='user?id=']").expect("selector");
    let cell_selector = Selector::parse("td").expect("selector");
    let mut result = Vec::new();
    for row in document.select(&row_selector) {
        let Some(link) = row.select(&link_selector).next() else {
            continue;
        };
        let Some(href) = link.value().attr("href") else {
            continue;
        };
        let Some(username) = query_value(href, "id") else {
            continue;
        };
        let karma = row
            .select(&cell_selector)
            .last()
            .and_then(|cell| cell.text().collect::<String>().trim().parse::<i64>().ok())
            .unwrap_or(0);
        result.push(LeaderboardEntry {
            user_id: UserId(username),
            karma,
        });
    }
    Ok(result)
}

pub fn html_to_text(html: &str, width: usize) -> String {
    let document = Html::parse_fragment(html);
    let mut output = String::new();
    for node in document.tree.root().children() {
        render_html_node(node, &mut output, width);
    }
    normalize_text(&output)
}

fn render_html_node(node: ego_tree::NodeRef<'_, scraper::Node>, output: &mut String, width: usize) {
    match node.value() {
        scraper::Node::Text(text) => output.push_str(text),
        scraper::Node::Element(element) => {
            let name = element.name();
            match name {
                "p" => {
                    ensure_blank_line(output);
                    for child in node.children() {
                        render_html_node(child, output, width);
                    }
                    ensure_blank_line(output);
                }
                "br" => output.push('\n'),
                "pre" => {
                    ensure_blank_line(output);
                    for child in node.children() {
                        render_html_node(child, output, width);
                    }
                    ensure_blank_line(output);
                }
                "li" => {
                    output.push_str("\n• ");
                    for child in node.children() {
                        render_html_node(child, output, width);
                    }
                }
                "a" => {
                    for child in node.children() {
                        render_html_node(child, output, width);
                    }
                }
                _ => {
                    for child in node.children() {
                        render_html_node(child, output, width);
                    }
                }
            }
        }
        _ => {}
    }
    let _ = width;
}

fn ensure_blank_line(output: &mut String) {
    if output.ends_with("\n\n") {
        return;
    }
    if output.ends_with('\n') {
        output.push('\n');
    } else if !output.is_empty() {
        output.push_str("\n\n");
    }
}

fn normalize_text(value: &str) -> String {
    let mut result = String::new();
    let mut last_was_space = false;
    let mut newlines = 0;
    for character in value.chars() {
        if character == '\r' {
            continue;
        }
        if character == '\n' {
            newlines += 1;
            if newlines <= 2 {
                result.push('\n');
            }
            last_was_space = false;
        } else if character == ' ' || character == '\t' {
            if !last_was_space && !result.ends_with('\n') {
                result.push(' ');
            }
            last_was_space = true;
        } else {
            result.push(character);
            last_was_space = false;
            newlines = 0;
        }
    }
    result.trim().to_string()
}

#[derive(Debug, Clone)]
struct ParsedForm {
    action: String,
    hidden: Vec<(String, String)>,
}

impl SiteClient {
    pub async fn vote(&self, id: ItemId, direction: VoteDirection) -> Result<()> {
        let _ = self.require_session().await?;
        let mut fields = vec![
            ("id".into(), id.0.to_string()),
            ("how".into(), direction.how().into()),
        ];
        if let Some(token) = self.auth_token().await {
            fields.push(("auth".into(), token));
        }
        let response = self
            .request(
                "vote",
                "POST",
                Some(&fields),
                true,
                Some(&format!("item?id={}", id.0)),
                true,
            )
            .await?;
        self.ensure_action_succeeded(&response, "vote")
    }

    pub async fn submit_story(&self, submission: &StorySubmission) -> Result<Option<ItemId>> {
        let _ = self.require_session().await?;
        let form = self
            .find_form(&["submitlink", "submit"], Some("fnid"), false)
            .await?;
        let mut fields = form.hidden.clone();
        fields.push(("title".into(), submission.title.clone()));
        fields.push(("url".into(), submission.url.clone().unwrap_or_default()));
        fields.push(("text".into(), submission.text.clone().unwrap_or_default()));
        if !fields.iter().any(|(key, _)| key == "fnop") {
            fields.push(("fnop".into(), "submit-page".into()));
        }
        let response = self
            .request("r", "POST", Some(&fields), true, Some("submitlink"), true)
            .await?;
        self.ensure_action_succeeded(&response, "submit")?;
        Ok(parse_item_id_from_url(&response.final_url))
    }

    pub async fn submit_comment(&self, submission: &CommentSubmission) -> Result<Option<ItemId>> {
        let _ = self.require_session().await?;
        let referer = format!("item?id={}", submission.parent_id.0);
        let page = self
            .request(&referer, "GET", None, true, None, true)
            .await?;
        self.ensure_not_login_page(&page).await?;
        let Some(form) = comment_form_in_html(&page.text())? else {
            return Err(HnError::Unsupported(format!(
                "no comment form found for item {}",
                submission.parent_id.0
            )));
        };

        let mut fields = form.hidden.clone();
        fields.push(("parent".into(), submission.parent_id.0.to_string()));
        fields.push(("goto".into(), referer.clone()));
        fields.push(("text".into(), submission.text.clone()));
        let path = if form.action.is_empty() || form.action == "#" {
            "comment".to_string()
        } else {
            form.action.clone()
        };
        let response = self
            .request(&path, "POST", Some(&fields), true, Some(&referer), true)
            .await?;
        self.ensure_action_succeeded(&response, "comment")?;
        Ok(parse_fragment(&response.final_url))
    }

    pub async fn edit_item(&self, id: ItemId, text: &str) -> Result<()> {
        let _ = self.require_session().await?;
        let referer = format!("edit?id={}", id.0);
        let page = self
            .request(&referer, "GET", None, true, None, true)
            .await?;
        self.ensure_not_login_page(&page).await?;
        let Some(form) = edit_form_in_html(&page.text())? else {
            return Err(HnError::Unsupported(format!(
                "no edit form found for item {}",
                id.0
            )));
        };
        let mut fields = form.hidden.clone();
        fields.push(("id".into(), id.0.to_string()));
        fields.push(("text".into(), text.to_string()));
        let path = if form.action.is_empty() || form.action == "#" {
            "xedit".to_string()
        } else {
            form.action.clone()
        };
        let response = self
            .request(&path, "POST", Some(&fields), true, Some(&referer), true)
            .await?;
        self.ensure_action_succeeded(&response, "edit")
    }

    pub async fn delete_item(&self, id: ItemId) -> Result<()> {
        let _ = self.require_session().await?;
        let goto = url::form_urlencoded::byte_serialize(format!("item?id={}", id.0).as_bytes())
            .collect::<String>();
        let referer = format!("delete-confirm?id={}&goto={goto}", id.0);
        let page = self
            .request(&referer, "GET", None, true, None, true)
            .await?;
        self.ensure_not_login_page(&page).await?;
        let Some(form) = delete_form_in_html(&page.text())? else {
            return Err(HnError::Unsupported(format!(
                "no delete form found for item {}",
                id.0
            )));
        };
        let mut fields = form.hidden.clone();
        fields.push(("d".into(), "Yes".into()));
        let path = if form.action.is_empty() || form.action == "#" {
            "xdelete".to_string()
        } else {
            form.action.clone()
        };
        let response = self
            .request(&path, "POST", Some(&fields), true, Some(&referer), true)
            .await?;
        self.ensure_action_succeeded(&response, "delete")
    }

    pub async fn set_favorite(&self, id: ItemId, favorite: bool) -> Result<()> {
        self.toggle("fave", id, favorite).await
    }

    pub async fn set_hidden(&self, id: ItemId, hidden: bool) -> Result<()> {
        self.toggle("hide", id, hidden).await
    }

    async fn toggle(&self, path: &str, id: ItemId, enabled: bool) -> Result<()> {
        let _ = self.require_session().await?;
        let mut fields = vec![("id".into(), id.0.to_string())];
        if !enabled {
            fields.push(("un".into(), "t".into()));
        }
        if let Some(token) = self.auth_token().await {
            fields.push(("auth".into(), token));
        }
        let response = self
            .request(
                path,
                "POST",
                Some(&fields),
                true,
                Some(&format!("item?id={}", id.0)),
                true,
            )
            .await?;
        self.ensure_action_succeeded(&response, path)
    }

    pub async fn flag(&self, id: ItemId, reason: &str) -> Result<()> {
        let _ = self.require_session().await?;
        let mut fields = vec![("id".into(), id.0.to_string())];
        if !reason.trim().is_empty() {
            fields.push(("reason".into(), reason.trim().into()));
        }
        if let Some(token) = self.auth_token().await {
            fields.push(("auth".into(), token));
        }
        let response = self
            .request(
                "flag",
                "POST",
                Some(&fields),
                true,
                Some(&format!("item?id={}", id.0)),
                true,
            )
            .await?;
        self.ensure_action_succeeded(&response, "flag")
    }

    pub async fn unflag(&self, id: ItemId) -> Result<()> {
        let _ = self.require_session().await?;
        let mut fields = vec![("id".into(), id.0.to_string()), ("un".into(), "t".into())];
        if let Some(token) = self.auth_token().await {
            fields.push(("auth".into(), token));
        }
        let response = self
            .request(
                "flag",
                "POST",
                Some(&fields),
                true,
                Some(&format!("item?id={}", id.0)),
                true,
            )
            .await?;
        self.ensure_action_succeeded(&response, "unflag")
    }

    async fn find_form(
        &self,
        paths: &[&str],
        input_name: Option<&str>,
        textarea: bool,
    ) -> Result<ParsedForm> {
        for path in paths {
            let response = self.request(path, "GET", None, true, None, true).await?;
            self.ensure_not_login_page(&response).await?;
            if let Some(form) = form_in_html(&response.text(), input_name, textarea)? {
                return Ok(form);
            }
        }
        Err(HnError::Unsupported(
            "could not find the Hacker News form".into(),
        ))
    }

    fn ensure_action_succeeded(&self, response: &HttpResponse, action: &str) -> Result<()> {
        if response.final_url.path().contains("/login") {
            return Err(HnError::Unauthenticated);
        }
        let text = response.text();
        if response.status >= 400 {
            return Err(HnError::Server(response.status));
        }
        let lower = text.to_lowercase();
        if lower.contains("unknown or expired link") {
            return Err(HnError::InvalidInput(
                "the Hacker News form expired; try again".into(),
            ));
        }
        if lower.contains("you have to wait") || lower.contains("posting too fast") {
            return Err(HnError::RateLimited(None));
        }
        if lower.contains("already been submitted") {
            return Err(HnError::InvalidInput(
                "that link has already been submitted to Hacker News".into(),
            ));
        }
        if lower.contains("please confirm") {
            return Err(HnError::InvalidInput(
                "Hacker News asked for confirmation before accepting this submission".into(),
            ));
        }
        if lower.contains("not able to serve your requests")
            || lower.contains("couldn't serve your request")
        {
            return Err(HnError::RateLimited(None));
        }
        if lower.contains("validation required") {
            return Err(HnError::Unsupported(
                "Hacker News requires browser validation for this action".into(),
            ));
        }
        if lower.contains("bad login") {
            return Err(HnError::Unauthenticated);
        }
        if lower.contains("you have to be logged in") || lower.contains("not logged in") {
            return Err(HnError::Unauthenticated);
        }
        let _ = action;
        Ok(())
    }
}

fn find_form_in_document(
    document: &Html,
    input_name: Option<&str>,
    textarea: bool,
) -> Option<ParsedForm> {
    let form_selector = Selector::parse("form").expect("selector");
    for form in document.select(&form_selector) {
        let hidden = parse_hidden_inputs(&form);
        let has_input = input_name
            .map(|name| hidden.iter().any(|(key, _)| key == name))
            .unwrap_or(true);
        let has_textarea = form
            .select(&Selector::parse("textarea").expect("selector"))
            .next()
            .is_some();
        if has_input && (!textarea || has_textarea) {
            return Some(ParsedForm {
                action: form.value().attr("action").unwrap_or_default().to_string(),
                hidden,
            });
        }
    }
    None
}

fn find_form_by_action(document: &Html, action: &str) -> Option<ParsedForm> {
    let form_selector = Selector::parse("form").expect("selector");
    for form in document.select(&form_selector) {
        let value = form.value().attr("action").unwrap_or_default();
        if value.to_lowercase().contains(&action.to_lowercase()) {
            return Some(ParsedForm {
                action: value.to_string(),
                hidden: parse_hidden_inputs(&form),
            });
        }
    }
    None
}

fn parse_hidden_inputs(form: &ElementRef<'_>) -> Vec<(String, String)> {
    let input_selector = Selector::parse("input").expect("selector");
    form.select(&input_selector)
        .filter_map(|input| {
            let kind = input.value().attr("type").unwrap_or_default();
            if !kind.eq_ignore_ascii_case("hidden") {
                return None;
            }
            let name = input.value().attr("name")?;
            if name == "creating" {
                return None;
            }
            Some((
                name.to_string(),
                input.value().attr("value").unwrap_or_default().to_string(),
            ))
        })
        .collect()
}

fn parse_item_id_from_url(url: &Url) -> Option<ItemId> {
    url.query_pairs()
        .find(|(key, _)| key == "id")
        .and_then(|(_, value)| value.parse::<u64>().ok())
        .filter(|id| *id > 0)
        .map(ItemId)
}

fn parse_fragment(url: &Url) -> Option<ItemId> {
    url.fragment()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|id| *id > 0)
        .map(ItemId)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FEED: &str = r#"
    <html><body><table>
      <tr class="athing" id="101">
        <td class="title"><span class="titleline"><a href="https://example.com/post">Example post</a></span></td>
      </tr>
      <tr>
        <td class="subtext">
          <span class="score">42 points</span>
          by <a href="user?id=alice">alice</a>
          <span class="age" title="2026-11-08T10:00:00">3 hours ago</span>
          | <a href="item?id=101">7 comments</a>
        </td>
      </tr>
    </table></body></html>"#;

    #[test]
    fn parses_story_rows_from_site_html() {
        let document = parse_document(FEED).unwrap();
        let entries = parse_feed_entries(&document, ItemKind::Story).unwrap();
        assert_eq!(entries.len(), 1);
        let entry = &entries[0];
        assert_eq!(entry.id, ItemId(101));
        assert_eq!(entry.title.as_deref(), Some("Example post"));
        assert_eq!(entry.url.as_deref(), Some("https://example.com/post"));
        assert_eq!(entry.author.as_ref().unwrap().0, "alice");
        assert_eq!(entry.score, Some(42));
        assert_eq!(entry.comment_count, Some(7));
    }

    #[test]
    fn detects_login_pages_and_forms() {
        let login = r#"<html><body><form method="post" action="login">
          <input type="text" name="acct"><input type="password" name="pw">
        </form></body></html>"#;
        assert!(page_is_login(login).unwrap());
        assert!(!page_is_login(FEED).unwrap());

        let comment = r#"<html><body><form method="post" action="comment">
          <input type="hidden" name="hmac" value="token">
          <textarea name="text"></textarea>
        </form></body></html>"#;
        let form = comment_form_in_html(comment).unwrap().unwrap();
        assert_eq!(form.action, "comment");
        assert!(form.hidden.iter().any(|(key, _)| key == "hmac"));
    }

    #[test]
    fn html_to_text_keeps_paragraphs_and_strips_tags() {
        let text = html_to_text("<p>Hello <b>world</b></p><p>Second &amp; last</p>", 80);
        assert!(text.contains("Hello world"));
        assert!(text.contains("Second & last"));
        assert!(!text.contains('<'));
    }

    #[test]
    fn parses_auth_token_from_html() {
        assert_eq!(
            find_auth_token(r#"<a href="logout?auth=abc12345678&amp;goto=news">logout</a>"#),
            Some("abc12345678".into())
        );
        assert_eq!(find_auth_token("<a href=\"news\">no token</a>"), None);
    }

    #[test]
    fn reads_cookie_parts() {
        assert_eq!(
            username_from_cookie("alice&token12345678").unwrap().0,
            "alice"
        );
        assert_eq!(
            auth_token_from_cookie("alice&token12345678"),
            Some("token12345678".into())
        );
    }
}
