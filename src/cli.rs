use std::io::{IsTerminal, Read, Write};
use std::process::Command as ProcessCommand;

use chrono::{DateTime, Utc};
use clap::{Args, Parser, Subcommand, ValueEnum};
use serde::Serialize;
use serde_json::json;

use crate::client::HackerNews;
use crate::domain::*;
use crate::drafts::{
    DraftRecord, Drafts, SUBMIT_DRAFT_KEY, excerpt, key_comment, key_edit, load_drafts, save_drafts,
};
use crate::error::{HnError, Result};
use crate::site::{LoginCredentials, SiteFeedEntry, SiteFeedPage, html_to_text};

#[derive(Parser, Debug)]
#[command(
    name = "hn",
    version,
    about = "Hacker News in your terminal — interactive TUI, scriptable CLI, and agent-friendly JSON",
    long_about = None
)]
pub struct Cli {
    /// Emit machine-readable JSON on stdout.
    #[arg(long, global = true, env = "HN_JSON")]
    pub json: bool,

    /// Disable ANSI color in human output.
    #[arg(long, global = true, env = "NO_COLOR")]
    pub no_color: bool,

    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Open the interactive browser.
    #[command(alias = "tui", alias = "ui")]
    Browse {
        #[arg(long, value_enum)]
        feed: Option<FeedName>,
    },

    /// Front page.
    #[command(alias = "news", alias = "top")]
    Front(PageArgs),
    /// Newest stories.
    New(PageArgs),
    /// Best stories.
    Best(PageArgs),
    /// Latest Ask HN posts.
    Ask(PageArgs),
    /// Latest Show HN posts.
    Show(PageArgs),
    /// Latest job posts.
    Jobs(PageArgs),
    /// Threads with recent activity.
    Active(PageArgs),
    /// Latest comments site-wide.
    Comments(PageArgs),
    /// New low-karma submissions.
    #[command(name = "noob-stories")]
    NoobStories(PageArgs),
    /// New low-karma comments.
    #[command(name = "noob-comments")]
    NoobComments(PageArgs),
    /// Front page from a past day.
    Past {
        /// Archive day, YYYY-MM-DD. Defaults to yesterday.
        day: Option<String>,
        #[command(flatten)]
        args: PageArgs,
    },
    /// Submissions from one domain.
    From {
        site: String,
        #[command(flatten)]
        args: PageArgs,
    },

    /// Show one item.
    Item { id: u64 },
    /// Show an item and its comment tree.
    #[command(alias = "tree")]
    Thread { id: u64 },
    /// Show a comment with its ancestor chain.
    Context {
        id: u64,
        #[arg(long, default_value_t = 20)]
        max_depth: usize,
    },
    /// Show a user profile and activity.
    User {
        username: String,
        #[arg(long, value_enum, default_value_t = ActivityArg::Submissions)]
        activity: ActivityArg,
        #[command(flatten)]
        args: PageArgs,
    },
    /// Search Hacker News.
    Search {
        #[arg(default_value = "")]
        query: String,
        #[arg(long)]
        by: Option<String>,
        #[arg(long, value_enum, default_value_t = SortArg::Relevance)]
        sort: SortArg,
        #[arg(long, value_enum, default_value_t = SearchTypeArg::Story)]
        r#type: SearchTypeArg,
        #[command(flatten)]
        args: PageArgs,
    },
    /// Top users by karma.
    Leaders,
    /// Recently changed items and profiles.
    Updates {
        #[arg(long)]
        items: bool,
        #[arg(long)]
        profiles: bool,
    },

    /// Log in and save the session.
    Login {
        #[arg(long)]
        username: Option<String>,
        #[arg(long)]
        password_stdin: bool,
    },
    /// Create an account and save the session.
    Signup {
        #[arg(long)]
        username: Option<String>,
        #[arg(long)]
        password_stdin: bool,
    },
    /// Log out and remove the saved session.
    Logout,
    /// Show the signed-in account.
    Whoami,

    /// Upvote, downvote, or remove a vote.
    Vote {
        id: u64,
        #[arg(long)]
        down: bool,
        #[arg(long)]
        undo: bool,
    },
    /// Submit a story.
    Submit {
        #[arg(short, long)]
        title: Option<String>,
        #[arg(long)]
        url: Option<String>,
        #[arg(long)]
        text: Option<String>,
        /// Resume the saved submission draft.
        #[arg(long)]
        use_draft: bool,
    },
    /// Post a comment or reply.
    #[command(alias = "reply")]
    Comment {
        parent_id: u64,
        #[arg(long)]
        text: Option<String>,
        /// Resume the saved draft for this item in your editor.
        #[arg(long)]
        use_draft: bool,
    },
    /// Edit one of your items.
    Edit {
        id: u64,
        #[arg(long)]
        text: Option<String>,
        /// Resume the saved draft for this item in your editor.
        #[arg(long)]
        use_draft: bool,
    },
    /// Delete one of your items.
    Delete {
        id: u64,
        #[arg(long)]
        yes: bool,
    },
    /// Favorite an item, or remove it.
    Favorite {
        id: u64,
        #[arg(long)]
        undo: bool,
    },
    /// Hide an item, or unhide it.
    Hide {
        id: u64,
        #[arg(long)]
        undo: bool,
    },
    /// Flag an item.
    Flag {
        id: u64,
        #[arg(long, default_value = "")]
        reason: String,
    },
    /// Remove a flag.
    Unflag { id: u64 },

    /// Your upvoted items.
    Upvoted(PageArgs),
    /// Your hidden items.
    Hidden(PageArgs),

    /// List locally saved comment and edit drafts.
    Drafts {
        /// Delete every saved draft.
        #[arg(long)]
        clear: bool,
    },

    /// Describe commands and arguments for agents.
    Capabilities,
}

#[derive(Args, Debug, Clone, Copy)]
pub struct PageArgs {
    #[arg(short, long, default_value_t = 30)]
    pub limit: u32,
    #[arg(short, long, default_value_t = 1)]
    pub page: u64,
}

impl PageArgs {
    fn request(self) -> Result<PageRequest> {
        if self.page == 0 {
            return Err(HnError::InvalidInput("page must be at least 1".into()));
        }
        let offset = (self.page - 1)
            .checked_mul(u64::from(self.limit))
            .ok_or_else(|| HnError::InvalidInput("page is too large".into()))?;
        PageRequest::new(offset, self.limit)
    }
}

#[derive(ValueEnum, Debug, Clone, Copy)]
pub enum FeedName {
    Front,
    New,
    Best,
    Ask,
    Show,
    Jobs,
    Active,
    Comments,
    NoobStories,
    NoobComments,
}

impl FeedName {
    fn feed(self) -> Feed {
        match self {
            FeedName::Front => Feed::FrontPage,
            FeedName::New => Feed::New,
            FeedName::Best => Feed::Best,
            FeedName::Ask => Feed::Ask,
            FeedName::Show => Feed::Show,
            FeedName::Jobs => Feed::Jobs,
            FeedName::Active => Feed::Active,
            FeedName::Comments => Feed::LatestComments,
            FeedName::NoobStories => Feed::NoobStories,
            FeedName::NoobComments => Feed::NoobComments,
        }
    }
}

#[derive(ValueEnum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityArg {
    Submissions,
    Comments,
    Favorites,
    FavoriteComments,
    Upvoted,
    Hidden,
}

impl ActivityArg {
    fn kind(self) -> UserActivityKind {
        match self {
            ActivityArg::Submissions => UserActivityKind::Submissions,
            ActivityArg::Comments => UserActivityKind::Comments,
            ActivityArg::Favorites => UserActivityKind::FavoriteStories,
            ActivityArg::FavoriteComments => UserActivityKind::FavoriteComments,
            ActivityArg::Upvoted => UserActivityKind::Upvoted,
            ActivityArg::Hidden => UserActivityKind::Hidden,
        }
    }
}

#[derive(ValueEnum, Debug, Clone, Copy)]
pub enum SortArg {
    Relevance,
    Date,
}

#[derive(ValueEnum, Debug, Clone, Copy)]
pub enum SearchTypeArg {
    Story,
    Comment,
    All,
    Job,
    Poll,
    Pollopt,
}

impl SearchTypeArg {
    fn kinds(self) -> Vec<ItemKind> {
        match self {
            SearchTypeArg::Story => vec![ItemKind::Story],
            SearchTypeArg::Comment => vec![ItemKind::Comment],
            SearchTypeArg::All => vec![ItemKind::Story, ItemKind::Comment],
            SearchTypeArg::Job => vec![ItemKind::Job],
            SearchTypeArg::Poll => vec![ItemKind::Poll],
            SearchTypeArg::Pollopt => vec![ItemKind::PollOption],
        }
    }
}

struct Out {
    json: bool,
    color: bool,
}

impl Out {
    fn new(cli: &Cli) -> Self {
        Self {
            json: cli.json,
            color: !cli.no_color
                && std::io::stdout().is_terminal()
                && std::env::var_os("NO_COLOR").is_none(),
        }
    }

    fn print_json<T: Serialize>(&self, value: &T) -> Result<()> {
        let text = serde_json::to_string_pretty(value)
            .map_err(|error| HnError::Decoding(error.to_string()))?;
        println!("{text}");
        Ok(())
    }

    fn bold(&self, value: &str) -> String {
        if self.color {
            format!("\x1b[1m{value}\x1b[0m")
        } else {
            value.to_string()
        }
    }

    fn dim(&self, value: &str) -> String {
        if self.color {
            format!("\x1b[2m{value}\x1b[0m")
        } else {
            value.to_string()
        }
    }

    fn link(&self, value: &str) -> String {
        if self.color {
            format!("\x1b[38;2;88;166;255m{value}\x1b[0m")
        } else {
            value.to_string()
        }
    }

    fn ok(&self, action: &str, extra: serde_json::Value) -> Result<()> {
        if self.json {
            let mut value = json!({ "ok": true, "action": action });
            if let (Some(object), Some(extra)) = (value.as_object_mut(), extra.as_object()) {
                for (key, value) in extra {
                    object.insert(key.clone(), value.clone());
                }
            }
            self.print_json(&value)
        } else {
            println!("{action}");
            Ok(())
        }
    }
}

impl Cli {
    pub async fn run(self) -> Result<()> {
        let out = Out::new(&self);
        // These commands are local-only and must work without a network stack
        // or CA certificates (for example inside minimal containers).
        if let Some(command) = &self.command {
            match command {
                Command::Capabilities => {
                    println!("{}", serde_json::to_string_pretty(&capabilities()).unwrap());
                    return Ok(());
                }
                Command::Drafts { clear } => return drafts_command(&out, *clear),
                _ => {}
            }
        }
        let Some(command) = self.command else {
            let client = HackerNews::new()?;
            if !self.json && std::io::stdout().is_terminal() {
                return crate::tui::run(client, Feed::FrontPage).await;
            }
            let page = client
                .feed_entries(&Feed::FrontPage, PageRequest::default())
                .await?;
            if out.json {
                return out.print_json(&page);
            }
            return print_site_page(&out, &page, "Front page", PageRequest::default().limit);
        };

        let client = HackerNews::new()?;
        match command {
            Command::Browse { feed } => {
                if out.json {
                    return Err(HnError::Unsupported(
                        "browse is interactive; use front, thread, search, or another line-oriented command"
                            .into(),
                    ));
                }
                crate::tui::run(client, feed.map(FeedName::feed).unwrap_or(Feed::FrontPage)).await
            }

            Command::Front(args) => {
                feed_command(&client, &out, Feed::FrontPage, args, "Front page").await
            }
            Command::New(args) => feed_command(&client, &out, Feed::New, args, "New stories").await,
            Command::Best(args) => {
                feed_command(&client, &out, Feed::Best, args, "Best stories").await
            }
            Command::Ask(args) => feed_command(&client, &out, Feed::Ask, args, "Ask HN").await,
            Command::Show(args) => feed_command(&client, &out, Feed::Show, args, "Show HN").await,
            Command::Jobs(args) => feed_command(&client, &out, Feed::Jobs, args, "Jobs").await,
            Command::Active(args) => {
                feed_command(&client, &out, Feed::Active, args, "Active threads").await
            }
            Command::Comments(args) => {
                feed_command(&client, &out, Feed::LatestComments, args, "Latest comments").await
            }
            Command::NoobStories(args) => {
                feed_command(&client, &out, Feed::NoobStories, args, "New submissions").await
            }
            Command::NoobComments(args) => {
                feed_command(&client, &out, Feed::NoobComments, args, "New comments").await
            }
            Command::Past { day, args } => {
                let day = match day {
                    Some(day) => CalendarDay::parse(&day)?,
                    None => CalendarDay::yesterday(),
                };
                feed_command(
                    &client,
                    &out,
                    Feed::PastFrontPage(day),
                    args,
                    "Past front page",
                )
                .await
            }
            Command::From { site, args } => {
                let site = site
                    .trim()
                    .trim_start_matches("https://")
                    .trim_start_matches("http://")
                    .to_string();
                feed_command(&client, &out, Feed::FromSite(site), args, "From site").await
            }

            Command::Item { id } => {
                let id = ItemId(id);
                let Some(item) = client.item(id).await? else {
                    return Err(HnError::NotFound(format!("item {id}")));
                };
                if out.json {
                    out.print_json(&item)?;
                } else {
                    print_item(&out, &item);
                }
                Ok(())
            }
            Command::Thread { id } => {
                let thread = client.thread(ItemId(id)).await?;
                if out.json {
                    out.print_json(&thread)?;
                } else {
                    print_thread(&out, &thread);
                }
                Ok(())
            }
            Command::Context { id, max_depth } => {
                let chain = client.context(ItemId(id), max_depth).await?;
                if out.json {
                    out.print_json(&chain)?;
                } else {
                    print_context(&out, &chain);
                }
                Ok(())
            }
            Command::User {
                username,
                activity,
                args,
            } => {
                let user_id = UserId(username);
                let Some(user) = client.user(&user_id).await? else {
                    return Err(HnError::NotFound(format!("user {user_id}")));
                };
                let page = args.request()?;
                let kind = activity.kind();
                let items = if kind == UserActivityKind::Submissions {
                    client.submissions(&user_id, page).await?
                } else {
                    client.activity(&user_id, kind, page).await?
                };
                if out.json {
                    out.print_json(&json!({ "user": user, "activity": items }))?;
                } else {
                    print_user(&out, &user);
                    println!();
                    print_item_page(&out, &items, activity_label(activity));
                }
                Ok(())
            }
            Command::Search {
                query,
                by,
                sort,
                r#type,
                args,
            } => {
                let page = args.request()?;
                let search = SearchQuery {
                    terms: query,
                    kinds: r#type.kinds(),
                    author: by.map(UserId),
                    sort: if matches!(sort, SortArg::Date) {
                        SearchSort::Date
                    } else {
                        SearchSort::Relevance
                    },
                    page,
                    ..SearchQuery::default()
                };
                let results = client.search(&search).await?;
                if out.json {
                    out.print_json(&results)?;
                } else {
                    print_search(&out, &results);
                }
                Ok(())
            }
            Command::Leaders => {
                let leaders = client.leaders().await?;
                if out.json {
                    out.print_json(&leaders)?;
                } else {
                    for (index, entry) in leaders.iter().enumerate() {
                        let karma = if entry.karma > 0 {
                            format!(" · {} karma", entry.karma)
                        } else {
                            String::new()
                        };
                        println!(
                            "{}. {} {}",
                            index + 1,
                            out.link(&entry.user_id.0),
                            out.dim(&karma)
                        );
                    }
                }
                Ok(())
            }
            Command::Updates { items, profiles } => {
                let updates = client.updates().await?;
                if out.json {
                    out.print_json(&updates)?;
                } else {
                    let show_items = items || !profiles;
                    let show_profiles = profiles || !items;
                    if show_items {
                        println!(
                            "{}",
                            out.bold(&format!("Changed items · {}", updates.item_ids.len()))
                        );
                        println!(
                            "{}",
                            updates
                                .item_ids
                                .iter()
                                .map(|id| id.0.to_string())
                                .collect::<Vec<_>>()
                                .join(" ")
                        );
                    }
                    if show_profiles {
                        println!(
                            "{}",
                            out.bold(&format!("Changed profiles · {}", updates.profile_ids.len()))
                        );
                        println!(
                            "{}",
                            updates
                                .profile_ids
                                .iter()
                                .map(|id| id.0.clone())
                                .collect::<Vec<_>>()
                                .join(" ")
                        );
                    }
                }
                Ok(())
            }

            Command::Login {
                username,
                password_stdin,
            } => {
                let credentials = read_credentials(username, password_stdin)?;
                let session = client.login(&credentials).await?;
                if out.json {
                    out.print_json(&json!({ "ok": true, "user": session.user_id }))?;
                } else {
                    println!("Logged in as {}.", session.user_id);
                }
                Ok(())
            }
            Command::Signup {
                username,
                password_stdin,
            } => {
                let credentials = read_credentials(username, password_stdin)?;
                let session = client.signup(&credentials).await?;
                if out.json {
                    out.print_json(&json!({ "ok": true, "user": session.user_id }))?;
                } else {
                    println!("Created account and logged in as {}.", session.user_id);
                }
                Ok(())
            }
            Command::Logout => {
                client.logout().await?;
                out.ok("Logged out", json!({}))?;
                Ok(())
            }
            Command::Whoami => {
                let session = client.validate_session().await?;
                match session {
                    Some(session) => {
                        if out.json {
                            out.print_json(&session)?;
                        } else {
                            println!("{}", session.user_id);
                        }
                        Ok(())
                    }
                    None => {
                        if out.json {
                            out.print_json(&json!({ "authenticated": false }))?;
                        } else {
                            println!("Not logged in.");
                        }
                        Ok(())
                    }
                }
            }

            Command::Vote { id, down, undo } => {
                if down && undo {
                    return Err(HnError::InvalidInput(
                        "--down and --undo cannot be used together".into(),
                    ));
                }
                let direction = if undo {
                    VoteDirection::Unvote
                } else if down {
                    VoteDirection::Down
                } else {
                    VoteDirection::Up
                };
                client.vote(ItemId(id), direction).await?;
                let label = match direction {
                    VoteDirection::Up => "Upvoted",
                    VoteDirection::Down => "Downvoted",
                    VoteDirection::Unvote => "Removed vote on",
                };
                out.ok(&format!("{label} {id}"), json!({ "item_id": id }))?;
                Ok(())
            }
            Command::Submit {
                title,
                url,
                text,
                use_draft,
            } => {
                let submission = resolve_story_submission(title, url, text, use_draft)?;
                match client.submit_story(&submission).await {
                    Ok(id) => {
                        let mut drafts = load_drafts().unwrap_or_default();
                        drafts.remove(SUBMIT_DRAFT_KEY);
                        let _ = save_drafts(&drafts);
                        if out.json {
                            out.print_json(&json!({ "ok": true, "item_id": id }))?;
                        } else if let Some(id) = id {
                            println!("Submitted: https://news.ycombinator.com/item?id={id}");
                        } else {
                            println!("Submitted to Hacker News.");
                        }
                        Ok(())
                    }
                    Err(error) => {
                        let mut drafts = load_drafts().unwrap_or_default();
                        drafts.insert(
                            SUBMIT_DRAFT_KEY.into(),
                            DraftRecord {
                                text: submission.text.clone().unwrap_or_default(),
                                saved_at: Utc::now(),
                                title: Some(submission.title.clone()),
                                url: submission.url.clone(),
                            },
                        );
                        let _ = save_drafts(&drafts);
                        if !out.json {
                            eprintln!(
                                "Your submission was saved as a draft. Resume it with: hn submit --use-draft"
                            );
                        }
                        Err(error)
                    }
                }
            }
            Command::Comment {
                parent_id,
                text,
                use_draft,
            } => {
                let parent = ItemId(parent_id);
                let key = key_comment(parent);
                let mut drafts = load_drafts().unwrap_or_default();
                let text = match text {
                    Some(text) if text == "-" => read_stdin()?,
                    Some(text) => text,
                    None if std::io::stdin().is_terminal() => {
                        compose_comment_text(&client, parent, &mut drafts, use_draft).await?
                    }
                    None => read_stdin()?,
                };
                let submission = CommentSubmission::new(parent, text.clone())?;
                match client.submit_comment(&submission).await {
                    Ok(id) => {
                        if drafts.remove(&key).is_some() {
                            let _ = save_drafts(&drafts);
                        }
                        if out.json {
                            out.print_json(&json!({ "ok": true, "comment_id": id }))?;
                        } else if let Some(id) = id {
                            println!("Comment posted: https://news.ycombinator.com/item?id={id}");
                        } else {
                            println!("Comment posted.");
                        }
                        Ok(())
                    }
                    Err(error) => {
                        drafts.insert(
                            key,
                            DraftRecord {
                                text,
                                saved_at: Utc::now(),
                                title: None,
                                url: None,
                            },
                        );
                        let _ = save_drafts(&drafts);
                        if !out.json {
                            eprintln!(
                                "Your comment was saved as a draft. Resume it with: hn comment {parent_id} --use-draft"
                            );
                        }
                        Err(error)
                    }
                }
            }
            Command::Edit {
                id,
                text,
                use_draft,
            } => {
                let item_id = ItemId(id);
                let key = key_edit(item_id);
                let mut drafts = load_drafts().unwrap_or_default();
                let text = match text {
                    Some(text) if text == "-" => read_stdin()?,
                    Some(text) => text,
                    None if std::io::stdin().is_terminal() => {
                        compose_edit_text(&client, item_id, &mut drafts, use_draft).await?
                    }
                    None => read_stdin()?,
                };
                match client.edit_item(item_id, &text).await {
                    Ok(()) => {
                        if drafts.remove(&key).is_some() {
                            let _ = save_drafts(&drafts);
                        }
                        out.ok(&format!("Edited {id}"), json!({ "item_id": id }))?;
                        Ok(())
                    }
                    Err(error) => {
                        drafts.insert(
                            key,
                            DraftRecord {
                                text,
                                saved_at: Utc::now(),
                                title: None,
                                url: None,
                            },
                        );
                        let _ = save_drafts(&drafts);
                        if !out.json {
                            eprintln!(
                                "Your edit was saved as a draft. Resume it with: hn edit {id} --use-draft"
                            );
                        }
                        Err(error)
                    }
                }
            }
            Command::Delete { id, yes } => {
                if !yes && !confirm(&format!("Delete item {id}?"))? {
                    println!("Cancelled.");
                    return Ok(());
                }
                client.delete_item(ItemId(id)).await?;
                out.ok(&format!("Deleted {id}"), json!({ "item_id": id }))?;
                Ok(())
            }
            Command::Favorite { id, undo } => {
                client.set_favorite(ItemId(id), !undo).await?;
                let label = if undo {
                    format!("Removed {id} from favorites")
                } else {
                    format!("Favorited {id}")
                };
                out.ok(&label, json!({ "item_id": id }))?;
                Ok(())
            }
            Command::Hide { id, undo } => {
                client.set_hidden(ItemId(id), !undo).await?;
                let label = if undo {
                    format!("Unhid {id}")
                } else {
                    format!("Hid {id}")
                };
                out.ok(&label, json!({ "item_id": id }))?;
                Ok(())
            }
            Command::Flag { id, reason } => {
                client.flag(ItemId(id), &reason).await?;
                out.ok(&format!("Flagged {id}"), json!({ "item_id": id }))?;
                Ok(())
            }
            Command::Unflag { id } => {
                client.unflag(ItemId(id)).await?;
                out.ok(&format!("Unflagged {id}"), json!({ "item_id": id }))?;
                Ok(())
            }
            Command::Upvoted(args) => {
                activity_command(&client, &out, UserActivityKind::Upvoted, args, "Upvoted").await
            }
            Command::Hidden(args) => {
                activity_command(&client, &out, UserActivityKind::Hidden, args, "Hidden").await
            }
            Command::Drafts { .. } | Command::Capabilities => {
                unreachable!("capabilities and drafts are handled before client creation")
            }
        }
    }
}

fn drafts_command(out: &Out, clear: bool) -> Result<()> {
    let mut drafts = load_drafts().unwrap_or_default();
    if clear {
        drafts.clear();
        save_drafts(&drafts)?;
        if out.json {
            out.print_json(&json!({ "ok": true, "cleared": true }))?;
        } else {
            println!("Cleared saved drafts.");
        }
        return Ok(());
    }
    if out.json {
        out.print_json(&drafts)?;
        return Ok(());
    }
    if drafts.is_empty() {
        println!("No saved drafts.");
        return Ok(());
    }
    let mut entries: Vec<_> = drafts.iter().collect();
    entries.sort_by_key(|(key, _)| key.as_str());
    for (key, draft) in entries {
        println!(
            "{}  {}",
            out.bold(key),
            out.dim(&draft.saved_at.format("%Y-%m-%d %H:%M").to_string())
        );
        if let Some(title) = &draft.title {
            println!("  Title: {title}");
        }
        if let Some(url) = &draft.url {
            println!("  Link:  {}", out.link(url));
        }
        if !draft.text.trim().is_empty() {
            println!("  {}", excerpt(&draft.text, 120));
        }
        if key == SUBMIT_DRAFT_KEY {
            println!("  {}", out.dim("hn submit --use-draft"));
        } else if let Some(id) = draft_target(key) {
            let command = if key.starts_with("comment:") {
                Some(format!("hn comment {id} --use-draft"))
            } else if key.starts_with("edit:") {
                Some(format!("hn edit {id} --use-draft"))
            } else {
                None
            };
            if let Some(command) = command {
                println!("  {}", out.dim(&command));
            }
        }
        println!();
    }
    Ok(())
}

async fn feed_command(
    client: &HackerNews,
    out: &Out,
    feed: Feed,
    args: PageArgs,
    heading: &str,
) -> Result<()> {
    let page = client.feed_entries(&feed, args.request()?).await?;
    if out.json {
        out.print_json(&page)
    } else {
        print_site_page(out, &page, heading, args.limit)
    }
}

async fn activity_command(
    client: &HackerNews,
    out: &Out,
    kind: UserActivityKind,
    args: PageArgs,
    heading: &str,
) -> Result<()> {
    let session = client
        .validate_session()
        .await?
        .ok_or(HnError::Unauthenticated)?;
    let page = args.request()?;
    let items = client.activity(&session.user_id, kind, page).await?;
    if out.json {
        out.print_json(&items)
    } else {
        print_item_page(out, &items, heading);
        Ok(())
    }
}

fn print_site_page(out: &Out, page: &SiteFeedPage, heading: &str, limit: u32) -> Result<()> {
    println!("{}", out.bold(heading));
    println!();
    if page.entries.is_empty() {
        println!("{}", out.dim("No items."));
        return Ok(());
    }
    for (index, entry) in page.entries.iter().enumerate() {
        print_site_entry(out, entry, page.offset as usize + index + 1);
    }
    println!();
    println!(
        "{}",
        out.dim(&format!(
            "Page {} · showing {}–{}{}",
            page.offset / u64::from(limit.max(1)) + 1,
            page.offset + 1,
            page.offset + page.entries.len() as u64,
            if page.has_more {
                " · more available"
            } else {
                ""
            }
        ))
    );
    Ok(())
}

fn print_site_entry(out: &Out, entry: &SiteFeedEntry, rank: usize) {
    let title = entry.title.as_deref().unwrap_or("[deleted]");
    match entry.kind {
        ItemKind::Comment => {
            let author = entry
                .author
                .as_ref()
                .map(|a| a.0.as_str())
                .unwrap_or("[deleted]");
            println!(
                "{}. {} {}",
                out.dim(&rank.to_string()),
                out.link(author),
                out.dim(&format!(
                    "· {} · comment {}",
                    relative_time(entry.created_at),
                    entry.id
                ))
            );
            if let Some(story) = &entry.story_title {
                println!("   {}", out.dim(&format!("on {story}")));
            }
            if let Some(text) = &entry.text {
                let text = html_to_text(&text.0, 120).replace('\n', " ");
                println!("   {}", truncate(&text, 280));
            }
        }
        _ => {
            println!("{}. {}", out.dim(&rank.to_string()), out.bold(title));
            let mut parts = Vec::new();
            if let Some(url) = &entry.url
                && let Ok(url) = url::Url::parse(url)
                && let Some(host) = url.host_str()
            {
                parts.push(host.trim_start_matches("www.").to_string());
            }
            if let Some(score) = entry.score {
                parts.push(format!("{score} points"));
            }
            if let Some(comments) = entry.comment_count {
                parts.push(format!("{comments} comments"));
            }
            if let Some(author) = &entry.author {
                parts.push(author.0.clone());
            }
            parts.push(relative_time(entry.created_at));
            println!("   {}", out.dim(&parts.join(" · ")));
            if let Some(text) = &entry.text {
                let text = html_to_text(&text.0, 120).replace('\n', " ");
                if !text.is_empty() {
                    println!("   {}", out.dim(&truncate(&text, 220)));
                }
            }
        }
    }
}

fn print_item_page(out: &Out, page: &ItemPage, heading: &str) {
    println!("{}", out.bold(heading));
    println!();
    if page.items.is_empty() {
        println!("{}", out.dim("No items."));
        return;
    }
    for (index, item) in page.items.iter().enumerate() {
        print_item_line(out, item, page.offset as usize + index + 1);
    }
}

fn print_item_line(out: &Out, item: &Item, rank: usize) {
    let author = item
        .author
        .as_ref()
        .map(|a| a.0.as_str())
        .unwrap_or("[deleted]");
    match &item.content {
        ItemContent::Comment(_) => {
            println!(
                "{}. {} {}",
                out.dim(&rank.to_string()),
                out.link(author),
                out.dim(&format!(
                    "· {} · comment {}",
                    relative_time(item.created_at),
                    item.id
                ))
            );
            if let Some(text) = item.text() {
                let text = html_to_text(&text.0, 120).replace('\n', " ");
                println!("   {}", truncate(&text, 280));
            }
        }
        _ => {
            println!(
                "{}. {}",
                out.dim(&rank.to_string()),
                out.bold(
                    &item
                        .title()
                        .map(|t| html_to_text(&t.0, 200))
                        .unwrap_or_default()
                )
            );
            let mut parts = Vec::new();
            if let Some(url) = item.url().and_then(|u| url::Url::parse(u).ok())
                && let Some(host) = url.host_str()
            {
                parts.push(host.trim_start_matches("www.").to_string());
            }
            if let Some(score) = item.score() {
                parts.push(format!("{score} points"));
            }
            if let Some(comments) = item.comment_count() {
                parts.push(format!("{comments} comments"));
            }
            parts.push(author.to_string());
            parts.push(relative_time(item.created_at));
            println!("   {}", out.dim(&parts.join(" · ")));
            if let Some(text) = item.text() {
                let text = html_to_text(&text.0, 120).replace('\n', " ");
                if !text.is_empty() {
                    println!("   {}", out.dim(&truncate(&text, 220)));
                }
            }
        }
    }
}

fn print_item(out: &Out, item: &Item) {
    if let Some(title) = item.title() {
        println!("{}", out.bold(&html_to_text(&title.0, 200)));
    }
    if let Some(url) = item.url() {
        println!("{}", out.link(url));
    }
    if let Some(score) = item.score() {
        println!(
            "{}",
            out.dim(&format!(
                "{score} points · {} comments · by {} · {} · id {}",
                item.comment_count().unwrap_or(0),
                item.author
                    .as_ref()
                    .map(|a| a.0.as_str())
                    .unwrap_or("[deleted]"),
                relative_time(item.created_at),
                item.id
            ))
        );
    }
    if let Some(text) = item.text() {
        let text = html_to_text(&text.0, 100);
        if !text.is_empty() {
            println!();
            println!("{text}");
        }
    }
    println!();
    println!("{}", out.dim(&format!("Comments: hn thread {}", item.id)));
}

fn print_thread(out: &Out, thread: &Thread) {
    print_item(out, &thread.root);
    println!();
    if thread.replies.is_empty() {
        println!("{}", out.dim("No comments."));
        return;
    }
    for node in &thread.replies {
        print_thread_node(out, node, 0);
    }
    if !thread.is_complete {
        println!();
        println!(
            "{}",
            out.dim(&format!(
                "Loaded {} items; thread is partial",
                thread.loaded_item_count
            ))
        );
    }
}

fn print_thread_node(out: &Out, node: &ThreadNode, depth: usize) {
    let indent = "  ".repeat(depth);
    let author = node
        .item
        .author
        .as_ref()
        .map(|a| a.0.as_str())
        .unwrap_or("[deleted]");
    if node.item.flags.deleted {
        println!("{indent}{}", out.dim("[deleted]"));
    } else {
        println!(
            "{indent}{} {}",
            out.link(author),
            out.dim(&format!(
                "· {} · {}",
                relative_time(node.item.created_at),
                node.item.id
            ))
        );
        if let Some(text) = node.item.text() {
            let text = html_to_text(&text.0, 100);
            for line in text.lines() {
                println!("{indent}{line}");
            }
        }
    }
    println!();
    for reply in &node.replies {
        print_thread_node(out, reply, depth + 1);
    }
}

fn print_context(out: &Out, chain: &[Item]) {
    for (index, item) in chain.iter().enumerate() {
        print_item_line(out, item, index + 1);
        println!();
    }
}

fn print_user(out: &Out, user: &User) {
    println!("{}", out.bold(&user.id.0));
    println!(
        "{}",
        out.dim(&format!(
            "{} karma · joined {} · {} submissions",
            user.karma,
            user.created_at.date_naive(),
            user.submitted_item_ids.len()
        ))
    );
    if let Some(about) = &user.about {
        let text = html_to_text(&about.0, 100);
        if !text.is_empty() {
            println!();
            println!("{text}");
        }
    }
}

fn print_search(out: &Out, results: &SearchResults) {
    if results.hits.is_empty() {
        println!("{}", out.dim("No results."));
        return;
    }
    for (index, hit) in results.hits.iter().enumerate() {
        match hit.kind {
            ItemKind::Comment => {
                println!(
                    "{}. {} {}",
                    out.dim(&(index + 1).to_string()),
                    out.link(
                        hit.author
                            .as_ref()
                            .map(|a| a.0.as_str())
                            .unwrap_or("[deleted]")
                    ),
                    out.dim(&format!(
                        "· {} · comment {}",
                        relative_time(hit.created_at),
                        hit.id
                    ))
                );
                if let Some(story) = &hit.story_title {
                    println!(
                        "   {}",
                        out.dim(&format!("on {}", html_to_text(&story.0, 120)))
                    );
                }
                if let Some(text) = &hit.text {
                    let text = html_to_text(&text.0, 120).replace('\n', " ");
                    println!("   {}", truncate(&text, 280));
                }
            }
            _ => {
                println!(
                    "{}. {}",
                    out.dim(&(index + 1).to_string()),
                    out.bold(
                        &hit.title
                            .as_ref()
                            .map(|t| html_to_text(&t.0, 200))
                            .unwrap_or_default()
                    )
                );
                let mut parts = Vec::new();
                if let Some(url) = hit.url.as_deref().and_then(|u| url::Url::parse(u).ok())
                    && let Some(host) = url.host_str()
                {
                    parts.push(host.trim_start_matches("www.").to_string());
                }
                if let Some(score) = hit.score {
                    parts.push(format!("{score} points"));
                }
                if let Some(comments) = hit.comment_count {
                    parts.push(format!("{comments} comments"));
                }
                if let Some(author) = &hit.author {
                    parts.push(author.0.clone());
                }
                parts.push(relative_time(hit.created_at));
                println!("   {}", out.dim(&parts.join(" · ")));
            }
        }
        println!();
    }
    println!(
        "{}",
        out.dim(&format!(
            "Page {} · {} total{}",
            results.page + 1,
            results.total_hits,
            if results.has_more() {
                " · more results available"
            } else {
                ""
            }
        ))
    );
}

fn relative_time(date: DateTime<Utc>) -> String {
    let seconds = (Utc::now() - date).num_seconds().max(0);
    match seconds {
        ..60 => format!("{seconds}s"),
        60..3600 => format!("{}m", seconds / 60),
        3600..86400 => format!("{}h", seconds / 3600),
        86400..2_592_000 => format!("{}d", seconds / 86400),
        2_592_000..31_536_000 => format!("{}mo", seconds / 2_592_000),
        _ => format!("{}y", seconds / 31_536_000),
    }
}

fn truncate(value: &str, max: usize) -> String {
    if value.chars().count() <= max {
        value.to_string()
    } else {
        let mut result: String = value.chars().take(max.saturating_sub(1)).collect();
        result.push('…');
        result
    }
}

fn prompt_line(prompt: &str) -> Result<String> {
    eprint!("{prompt}");
    std::io::stderr().flush().ok();
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|error| HnError::Transport(error.to_string()))?;
    Ok(line.trim().to_string())
}

fn resolve_story_submission(
    title: Option<String>,
    url: Option<String>,
    text: Option<String>,
    use_draft: bool,
) -> Result<StorySubmission> {
    let draft = if use_draft {
        load_drafts()
            .unwrap_or_default()
            .get(SUBMIT_DRAFT_KEY)
            .cloned()
    } else {
        None
    };
    let mut title = title.or_else(|| draft.as_ref().and_then(|draft| draft.title.clone()));
    let mut url = url.or_else(|| draft.as_ref().and_then(|draft| draft.url.clone()));
    let mut text = match text {
        Some(text) if text == "-" => Some(read_stdin()?),
        Some(text) => Some(text),
        None => draft
            .as_ref()
            .map(|draft| draft.text.clone())
            .filter(|text| !text.trim().is_empty()),
    };

    if title
        .as_deref()
        .map(|title| title.trim().is_empty())
        .unwrap_or(true)
        && std::io::stdin().is_terminal()
    {
        title = Some(prompt_line("Title: ")?);
    }
    let title = title.ok_or_else(|| {
        HnError::InvalidInput("a title is required; pass --title or run interactively".into())
    })?;

    if url.is_none() && text.is_none() && std::io::stdin().is_terminal() {
        let link = prompt_line("Link (leave empty for a text post): ")?;
        if !link.trim().is_empty() {
            url = Some(link);
        }
        if url.is_none() {
            eprintln!("Write the post text below. Save and quit your editor to submit.");
            text = Some(edit_text("")?);
        }
    }
    if url.is_none() && text.is_none() {
        return Err(HnError::InvalidInput(
            "pass --url or --text, or run interactively".into(),
        ));
    }
    StorySubmission::new(title, url, text)
}

async fn compose_comment_text(
    client: &HackerNews,
    parent: ItemId,
    drafts: &mut Drafts,
    use_draft: bool,
) -> Result<String> {
    if let Ok(Some(item)) = client.item(parent).await {
        eprintln!("Replying to {}", item_context(&item));
        if let Some(text) = item.text() {
            let text = crate::site::html_to_text(&text.0, 100);
            if !text.is_empty() {
                eprintln!("> {}", excerpt(&text, 200));
            }
        }
        eprintln!();
    }
    let key = key_comment(parent);
    let initial = if use_draft {
        drafts
            .get(&key)
            .map(|draft| draft.text.clone())
            .unwrap_or_default()
    } else {
        String::new()
    };
    if !initial.is_empty() {
        eprintln!("Saved draft loaded. Delete all text to cancel.");
    }
    if !std::io::stdin().is_terminal() {
        return read_stdin();
    }
    edit_text(&initial)
}

async fn compose_edit_text(
    client: &HackerNews,
    item_id: ItemId,
    drafts: &mut Drafts,
    use_draft: bool,
) -> Result<String> {
    let existing = client.item(item_id).await.ok().flatten();
    if let Some(item) = &existing {
        eprintln!("Editing {}", item_context(item));
        if let Some(text) = item.text() {
            let text = crate::site::html_to_text(&text.0, 100);
            if !text.is_empty() {
                eprintln!("> {}", excerpt(&text, 200));
            }
        }
        eprintln!();
    }
    let key = key_edit(item_id);
    let initial = if use_draft {
        drafts
            .get(&key)
            .map(|draft| draft.text.clone())
            .unwrap_or_default()
    } else {
        existing
            .as_ref()
            .and_then(|item| item.text().map(|text| text.0.clone()))
            .unwrap_or_default()
    };
    if !std::io::stdin().is_terminal() {
        return read_stdin();
    }
    edit_text(&initial)
}

fn item_context(item: &Item) -> String {
    let author = item
        .author
        .as_ref()
        .map(|author| author.0.as_str())
        .unwrap_or("[deleted]");
    match item.title() {
        Some(title) => format!(
            "{author} in \"{}\"",
            crate::site::html_to_text(&title.0, 120)
        ),
        None => format!("{author} · item {}", item.id),
    }
}

fn draft_target(key: &str) -> Option<&str> {
    key.split_once(':').map(|(_, value)| value)
}

fn read_stdin() -> Result<String> {
    let mut text = String::new();
    std::io::stdin()
        .read_to_string(&mut text)
        .map_err(|error| HnError::Transport(error.to_string()))?;
    let text = text.trim().to_string();
    if text.is_empty() {
        return Err(HnError::InvalidInput("no text was provided".into()));
    }
    Ok(text)
}

fn edit_text(initial: &str) -> Result<String> {
    let mut file =
        tempfile::NamedTempFile::new().map_err(|error| HnError::Transport(error.to_string()))?;
    file.write_all(initial.as_bytes())
        .map_err(|error| HnError::Transport(error.to_string()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(file.path(), std::fs::Permissions::from_mode(0o600));
    }
    let editor = std::env::var("VISUAL")
        .or_else(|_| std::env::var("EDITOR"))
        .unwrap_or_else(|_| "vi".into());
    let quoted = shell_quote(file.path().to_string_lossy().as_ref());
    let status = ProcessCommand::new("/bin/sh")
        .arg("-c")
        .arg(format!("{editor} {quoted}"))
        .status()
        .map_err(|error| HnError::Transport(error.to_string()))?;
    if !status.success() {
        return Err(HnError::Transport(format!(
            "editor exited with status {}",
            status.code().unwrap_or(-1)
        )));
    }
    let text = std::fs::read_to_string(file.path())
        .map_err(|error| HnError::Transport(error.to_string()))?
        .trim()
        .to_string();
    if text.is_empty() {
        return Err(HnError::InvalidInput("the text is empty".into()));
    }
    Ok(text)
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn read_credentials(username: Option<String>, password_stdin: bool) -> Result<LoginCredentials> {
    let username = match username {
        Some(username) => username.trim().to_string(),
        None => {
            eprint!("Username: ");
            std::io::stderr().flush().ok();
            let mut line = String::new();
            std::io::stdin()
                .read_line(&mut line)
                .map_err(|error| HnError::Transport(error.to_string()))?;
            line.trim().to_string()
        }
    };
    if username.is_empty() {
        return Err(HnError::InvalidInput("a username is required".into()));
    }

    let password = if password_stdin {
        let mut line = String::new();
        std::io::stdin()
            .read_line(&mut line)
            .map_err(|error| HnError::Transport(error.to_string()))?;
        line.trim_end_matches(['\r', '\n']).to_string()
    } else if let Ok(password) = std::env::var("HN_PASSWORD") {
        password
    } else {
        rpassword::prompt_password("Password: ")
            .map_err(|error| HnError::Transport(error.to_string()))?
    };
    if password.is_empty() {
        return Err(HnError::InvalidInput("a password is required".into()));
    }
    Ok(LoginCredentials { username, password })
}

fn confirm(message: &str) -> Result<bool> {
    eprint!("{message} [y/N] ");
    std::io::stderr().flush().ok();
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|error| HnError::Transport(error.to_string()))?;
    Ok(matches!(line.trim().to_lowercase().as_str(), "y" | "yes"))
}

fn activity_label(activity: ActivityArg) -> &'static str {
    match activity {
        ActivityArg::Submissions => "Submissions",
        ActivityArg::Comments => "Comments",
        ActivityArg::Favorites => "Favorites",
        ActivityArg::FavoriteComments => "Favorite comments",
        ActivityArg::Upvoted => "Upvoted",
        ActivityArg::Hidden => "Hidden",
    }
}

fn capabilities() -> serde_json::Value {
    json!({
        "name": "hn",
        "version": env!("CARGO_PKG_VERSION"),
        "description": "Hacker News CLI, TUI, and agent-friendly JSON interface",
        "docs": {
            "agents": "https://github.com/kaushalvivek/hn-cli/blob/main/AGENTS.md",
            "llms": "https://github.com/kaushalvivek/hn-cli/blob/main/llms.txt",
            "repository": "https://github.com/kaushalvivek/hn-cli"
        },
        "global_flags": [
            {"name": "--json", "env": "HN_JSON", "description": "Emit machine-readable JSON on stdout"},
            {"name": "--no-color", "env": "NO_COLOR", "description": "Disable ANSI color in human output"}
        ],
        "exit_codes": {"0": "success", "1": "error"},
        "json_errors": {
            "stream": "stderr",
            "shape": {"ok": false, "error": {"code": "snake_case_code", "message": "human readable"}},
            "codes": [
                "invalid_input", "not_found", "unauthenticated", "invalid_credentials",
                "unauthorized", "unsupported", "rate_limited", "server_error",
                "transport_error", "decoding_error", "cancelled"
            ]
        },
        "auth": {
            "required_for": ["upvoted", "hidden", "logout", "vote", "submit", "comment", "edit", "delete", "favorite", "hide", "flag", "unflag"],
            "session_file": "~/.config/hn/session.json",
            "login": "hn login --username USER --password-stdin",
            "status": "hn whoami --json",
            "passwords_are_never_persisted": true
        },
        "environment": [
            {"name": "HN_CONFIG_DIR", "description": "Config directory (default ~/.config/hn)"},
            {"name": "HN_JSON", "description": "Same as --json"},
            {"name": "HN_PASSWORD", "description": "Password for non-interactive login; prefer --password-stdin"},
            {"name": "HN_INSTALL_DIR", "description": "Install directory used by install.sh"},
            {"name": "HN_SITE_URL", "description": "Override the Hacker News HTML base URL (testing)"},
            {"name": "HN_FIREBASE_URL", "description": "Override the Firebase base URL (testing)"},
            {"name": "HN_ALGOLIA_URL", "description": "Override the Algolia base URL (testing)"},
            {"name": "VISUAL", "description": "Editor used by interactive comment/edit"},
            {"name": "EDITOR", "description": "Fallback editor"},
            {"name": "NO_COLOR", "description": "Disable color"}
        ],
        "commands": [
            {"name": "front", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "new", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "best", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "ask", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "show", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "jobs", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "active", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "comments", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "noob-stories", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "noob-comments", "auth": false, "args": ["--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "past", "auth": false, "args": ["day", "--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "from", "auth": false, "args": ["site", "--limit", "--page"], "output": "SiteFeedPage"},
            {"name": "item", "auth": false, "args": ["id"], "output": "Item"},
            {"name": "thread", "auth": false, "args": ["id"], "output": "Thread"},
            {"name": "context", "auth": false, "args": ["id", "--max-depth"], "output": "[Item]"},
            {"name": "user", "auth": false, "args": ["username", "--activity", "--limit", "--page"], "output": "User + ItemPage"},
            {"name": "search", "auth": false, "args": ["query", "--by", "--sort", "--type", "--limit", "--page"], "output": "SearchResults"},
            {"name": "leaders", "auth": false, "args": [], "output": "[LeaderboardEntry]"},
            {"name": "updates", "auth": false, "args": ["--items", "--profiles"], "output": "Updates"},
            {"name": "upvoted", "auth": true, "args": ["--limit", "--page"], "output": "ItemPage"},
            {"name": "hidden", "auth": true, "args": ["--limit", "--page"], "output": "ItemPage"},
            {"name": "login", "auth": false, "args": ["--username", "--password-stdin"], "output": "{ok,user}"},
            {"name": "signup", "auth": false, "args": ["--username", "--password-stdin"], "output": "{ok,user}"},
            {"name": "logout", "auth": true, "args": [], "output": "{ok}"},
            {"name": "whoami", "auth": false, "args": [], "output": "{user_id} | {authenticated:false}"},
            {"name": "vote", "auth": true, "args": ["id", "--down", "--undo"], "output": "{ok,item_id}"},
            {"name": "submit", "auth": true, "args": ["--title", "--url", "--text", "--use-draft"], "output": "{ok,item_id}"},
            {"name": "comment", "auth": true, "args": ["parent_id", "--text", "--use-draft"], "output": "{ok,comment_id}"},
            {"name": "edit", "auth": true, "args": ["id", "--text", "--use-draft"], "output": "{ok,item_id}"},
            {"name": "delete", "auth": true, "args": ["id", "--yes"], "output": "{ok,item_id}"},
            {"name": "favorite", "auth": true, "args": ["id", "--undo"], "output": "{ok,item_id}"},
            {"name": "hide", "auth": true, "args": ["id", "--undo"], "output": "{ok,item_id}"},
            {"name": "flag", "auth": true, "args": ["id", "--reason"], "output": "{ok,item_id}"},
            {"name": "unflag", "auth": true, "args": ["id"], "output": "{ok,item_id}"},
            {"name": "drafts", "auth": false, "args": ["--clear"], "output": "DraftMap | {ok,cleared}"},
            {"name": "capabilities", "auth": false, "args": [], "output": "Capabilities"}
        ]
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_args_become_page_requests() {
        let request = PageArgs { limit: 30, page: 2 }.request().unwrap();
        assert_eq!(request.offset, 30);
        assert_eq!(request.limit, 30);
        assert!(PageArgs { limit: 30, page: 0 }.request().is_err());
    }

    #[test]
    fn capabilities_are_self_describing() {
        let value = capabilities();
        assert_eq!(value["name"], "hn");
        assert!(value["commands"].as_array().unwrap().len() > 20);
        assert_eq!(value["json_errors"]["stream"], "stderr");
    }
}
