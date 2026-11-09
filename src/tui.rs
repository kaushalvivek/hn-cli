use std::collections::HashSet;
use std::io::{self, Write};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use crossterm::event::{
    self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
    Event as TermEvent, EventStream, KeyCode, KeyEvent, KeyModifiers, MouseEventKind,
};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use futures::StreamExt;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Wrap};
use ratatui::{Frame, Terminal};
use tokio::sync::mpsc;

use crate::client::HackerNews;
use crate::domain::*;
use crate::drafts::{
    DraftRecord, Drafts, SUBMIT_DRAFT_KEY, key_comment, key_edit, load_drafts, save_drafts,
};
use crate::error::{HnError, Result};
use crate::site::{LoginCredentials, SiteFeedEntry, UserSession, html_to_text};

const ACCENT: Color = Color::Rgb(255, 102, 0);
const LINK: Color = Color::Rgb(88, 166, 255);
const SUCCESS: Color = Color::Rgb(63, 185, 80);
const ERROR: Color = Color::Rgb(248, 81, 73);
const WARNING: Color = Color::Rgb(210, 153, 34);
const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

#[derive(Debug, Clone, PartialEq, Eq)]
enum Source {
    Feed(Feed),
    Upvoted,
    Hidden,
    Search(String),
}

impl Source {
    fn label(&self) -> String {
        match self {
            Source::Feed(feed) => feed.label(),
            Source::Upvoted => "upvoted".into(),
            Source::Hidden => "hidden".into(),
            Source::Search(query) => format!("search {query}"),
        }
    }

    fn requires_auth(&self) -> bool {
        matches!(self, Source::Upvoted | Source::Hidden)
    }
}

#[derive(Debug, Clone)]
struct TuiEntry {
    id: ItemId,
    kind: ItemKind,
    title: Option<String>,
    url: Option<String>,
    text: Option<String>,
    author: Option<UserId>,
    created_at: DateTime<Utc>,
    score: Option<i64>,
    comment_count: Option<u64>,
    story_title: Option<String>,
    is_dead: bool,
    is_deleted: bool,
}

impl TuiEntry {
    fn from_site(entry: &SiteFeedEntry) -> Self {
        Self {
            id: entry.id,
            kind: entry.kind,
            title: entry.title.clone(),
            url: entry.url.clone(),
            text: entry.text.as_ref().map(|text| html_to_text(&text.0, 1000)),
            author: entry.author.clone(),
            created_at: entry.created_at,
            score: entry.score,
            comment_count: entry.comment_count,
            story_title: entry.story_title.clone(),
            is_dead: entry.is_dead,
            is_deleted: entry.is_deleted,
        }
    }

    fn from_item(item: &Item) -> Self {
        Self {
            id: item.id,
            kind: item.kind().unwrap_or(ItemKind::Comment),
            title: item.title().map(|title| html_to_text(&title.0, 1000)),
            url: item.url().map(|url| url.to_string()),
            text: item.text().map(|text| html_to_text(&text.0, 1000)),
            author: item.author.clone(),
            created_at: item.created_at,
            score: item.score(),
            comment_count: item.comment_count(),
            story_title: None,
            is_dead: item.flags.dead,
            is_deleted: item.flags.deleted,
        }
    }

    fn from_hit(hit: &SearchHit) -> Self {
        Self {
            id: hit.id,
            kind: hit.kind,
            title: hit.title.as_ref().map(|title| html_to_text(&title.0, 1000)),
            url: hit.url.clone(),
            text: hit.text.as_ref().map(|text| html_to_text(&text.0, 1000)),
            author: hit.author.clone(),
            created_at: hit.created_at,
            score: hit.score,
            comment_count: hit.comment_count,
            story_title: hit
                .story_title
                .as_ref()
                .map(|title| html_to_text(&title.0, 1000)),
            is_dead: false,
            is_deleted: false,
        }
    }

    fn display_title(&self) -> String {
        if self.is_deleted {
            return "[deleted]".into();
        }
        self.title
            .clone()
            .filter(|value| !value.is_empty())
            .or_else(|| self.story_title.clone())
            .or_else(|| self.text.clone())
            .unwrap_or_else(|| "[deleted]".into())
    }

    fn domain(&self) -> Option<String> {
        let url = url::Url::parse(self.url.as_deref()?).ok()?;
        url.host_str()
            .map(|host| host.trim_start_matches("www.").to_string())
    }
}

#[derive(Debug, Clone)]
struct VisibleComment {
    item: Item,
    depth: usize,
    has_children: bool,
    collapsed: bool,
}

#[derive(Debug, Clone)]
struct ThreadState {
    thread: Thread,
    visible: Vec<VisibleComment>,
    selected: usize,
    collapsed: HashSet<ItemId>,
}

impl ThreadState {
    fn new(thread: Thread) -> Self {
        let mut state = Self {
            thread,
            visible: Vec::new(),
            selected: 0,
            collapsed: HashSet::new(),
        };
        state.rebuild();
        state
    }

    fn rebuild(&mut self) {
        let mut visible = Vec::new();
        fn walk(
            nodes: &[ThreadNode],
            depth: usize,
            collapsed: &HashSet<ItemId>,
            visible: &mut Vec<VisibleComment>,
        ) {
            for node in nodes {
                let is_collapsed = collapsed.contains(&node.item.id);
                visible.push(VisibleComment {
                    item: node.item.clone(),
                    depth,
                    has_children: !node.replies.is_empty(),
                    collapsed: is_collapsed,
                });
                if !is_collapsed {
                    walk(&node.replies, depth + 1, collapsed, visible);
                }
            }
        }
        walk(&self.thread.replies, 0, &self.collapsed, &mut visible);
        self.visible = visible;
        self.selected = self.selected.min(self.visible.len().saturating_sub(1));
    }

    fn selected_item(&self) -> Option<&Item> {
        self.visible.get(self.selected).map(|comment| &comment.item)
    }

    fn toggle(&mut self) {
        let Some(comment) = self.visible.get(self.selected) else {
            return;
        };
        if !comment.has_children {
            return;
        }
        let id = comment.item.id;
        if !self.collapsed.insert(id) {
            self.collapsed.remove(&id);
        }
        self.rebuild();
    }

    fn insert(&mut self, item: Item, parent_id: ItemId) -> bool {
        if parent_id == self.thread.root.id {
            self.thread.replies.push(ThreadNode {
                item: item.clone(),
                replies: Vec::new(),
            });
            self.rebuild();
            self.select(item.id);
            return true;
        }
        fn find_mut(nodes: &mut [ThreadNode], id: ItemId) -> Option<&mut ThreadNode> {
            for node in nodes {
                if node.item.id == id {
                    return Some(node);
                }
                if let Some(found) = find_mut(&mut node.replies, id) {
                    return Some(found);
                }
            }
            None
        }
        if let Some(parent) = find_mut(&mut self.thread.replies, parent_id) {
            parent.replies.push(ThreadNode {
                item: item.clone(),
                replies: Vec::new(),
            });
            self.rebuild();
            self.select(item.id);
            true
        } else {
            false
        }
    }

    fn update_text(&mut self, id: ItemId, text: &str) -> bool {
        fn find_mut(nodes: &mut [ThreadNode], id: ItemId) -> Option<&mut ThreadNode> {
            for node in nodes {
                if node.item.id == id {
                    return Some(node);
                }
                if let Some(found) = find_mut(&mut node.replies, id) {
                    return Some(found);
                }
            }
            None
        }
        let Some(node) = find_mut(&mut self.thread.replies, id) else {
            return false;
        };
        let new_text = HtmlText(text.to_string());
        node.item = with_item_text(&node.item, new_text);
        self.rebuild();
        true
    }

    fn select(&mut self, id: ItemId) {
        if let Some(index) = self
            .visible
            .iter()
            .position(|comment| comment.item.id == id)
        {
            self.selected = index;
        }
    }
}

fn with_item_text(item: &Item, text: HtmlText) -> Item {
    let content = match &item.content {
        ItemContent::Story(story) => ItemContent::Story(Story {
            title: story.title.clone(),
            url: story.url.clone(),
            text: Some(text),
            score: story.score,
            comment_count: story.comment_count,
            comment_ids: story.comment_ids.clone(),
        }),
        ItemContent::Comment(comment) => ItemContent::Comment(Comment {
            parent_id: comment.parent_id,
            text,
            child_ids: comment.child_ids.clone(),
        }),
        ItemContent::Job(job) => ItemContent::Job(Job {
            title: job.title.clone(),
            url: job.url.clone(),
            text: Some(text),
            score: job.score,
        }),
        ItemContent::Poll(poll) => ItemContent::Poll(Poll {
            title: poll.title.clone(),
            text: Some(text),
            score: poll.score,
            comment_count: poll.comment_count,
            comment_ids: poll.comment_ids.clone(),
            option_ids: poll.option_ids.clone(),
        }),
        ItemContent::PollOption(option) => ItemContent::PollOption(PollOption {
            poll_id: option.poll_id,
            text,
            score: option.score,
        }),
        ItemContent::Deleted(_) => item.content.clone(),
    };
    Item {
        id: item.id,
        author: item.author.clone(),
        created_at: item.created_at,
        flags: item.flags,
        content,
    }
}

#[derive(Debug, Clone)]
enum Detail {
    Empty,
    Preview(TuiEntry),
    Thread(ThreadState),
    Error(ItemId, String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ComposeContext {
    label: String,
    author: Option<UserId>,
    story_title: Option<String>,
    excerpt: Option<String>,
    target: ItemId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ComposeKind {
    Comment { parent_id: ItemId },
    Edit { item_id: ItemId },
}

impl ComposeKind {
    fn key(&self) -> String {
        match self {
            ComposeKind::Comment { parent_id } => key_comment(*parent_id),
            ComposeKind::Edit { item_id } => key_edit(*item_id),
        }
    }

    fn title(&self) -> &'static str {
        match self {
            ComposeKind::Comment { .. } => "Reply",
            ComposeKind::Edit { .. } => "Edit",
        }
    }

    fn submit_label(&self) -> &'static str {
        match self {
            ComposeKind::Comment { .. } => "post",
            ComposeKind::Edit { .. } => "save",
        }
    }
}

#[derive(Debug, Clone, Default)]
struct Editor {
    text: String,
    cursor: usize,
}

impl Editor {
    fn new(text: String) -> Self {
        let cursor = text.chars().count();
        Self { text, cursor }
    }

    fn chars(&self) -> Vec<char> {
        self.text.chars().collect()
    }

    fn insert(&mut self, text: &str) {
        let normalized = text
            .replace("\r\n", "\n")
            .replace('\r', "\n")
            .replace('\t', "    ");
        let mut chars = self.chars();
        let index = self.cursor.min(chars.len());
        chars.splice(index..index, normalized.chars());
        self.text = chars.into_iter().collect();
        self.cursor = index + normalized.chars().count();
    }

    fn insert_single_line(&mut self, text: &str) {
        let cleaned: String = text
            .chars()
            .map(|character| match character {
                '\n' | '\r' => ' ',
                other => other,
            })
            .collect();
        self.insert(&cleaned);
    }

    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let mut chars = self.chars();
        let index = self.cursor.min(chars.len());
        chars.remove(index - 1);
        self.text = chars.into_iter().collect();
        self.cursor = index - 1;
    }

    fn delete_forward(&mut self) {
        let mut chars = self.chars();
        if self.cursor < chars.len() {
            chars.remove(self.cursor);
            self.text = chars.into_iter().collect();
        }
    }

    fn move_left(&mut self) {
        self.cursor = self.cursor.saturating_sub(1);
    }

    fn move_right(&mut self) {
        self.cursor = (self.cursor + 1).min(self.text.chars().count());
    }

    fn line_bounds(&self, chars: &[char]) -> (usize, usize) {
        let position = self.cursor.min(chars.len());
        let mut start = position;
        while start > 0 && chars[start - 1] != '\n' {
            start -= 1;
        }
        let mut end = position;
        while end < chars.len() && chars[end] != '\n' {
            end += 1;
        }
        (start, end)
    }

    fn move_home(&mut self) {
        let chars = self.chars();
        self.cursor = self.line_bounds(&chars).0;
    }

    fn move_end(&mut self) {
        let chars = self.chars();
        self.cursor = self.line_bounds(&chars).1;
    }

    fn move_up(&mut self) {
        let chars = self.chars();
        let (start, _) = self.line_bounds(&chars);
        if start == 0 {
            self.cursor = 0;
            return;
        }
        let prev_end = start - 1;
        let mut prev_start = prev_end;
        while prev_start > 0 && chars[prev_start - 1] != '\n' {
            prev_start -= 1;
        }
        let column = self.cursor - start;
        self.cursor = prev_start + column.min(prev_end - prev_start);
    }

    fn move_down(&mut self) {
        let chars = self.chars();
        let (start, end) = self.line_bounds(&chars);
        if end >= chars.len() {
            self.cursor = chars.len();
            return;
        }
        let next_start = end + 1;
        let mut next_end = next_start;
        while next_end < chars.len() && chars[next_end] != '\n' {
            next_end += 1;
        }
        let column = self.cursor - start;
        self.cursor = next_start + column.min(next_end - next_start);
    }

    fn page(&mut self, up: bool) {
        for _ in 0..6 {
            if up {
                self.move_up();
            } else {
                self.move_down();
            }
        }
    }

    fn trimmed(&self) -> String {
        self.text.trim().to_string()
    }
}

#[derive(Debug, Clone)]
struct ComposeState {
    kind: ComposeKind,
    context: ComposeContext,
    editor: Editor,
    scroll: usize,
    submitting: bool,
    error: Option<String>,
    restored: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SubmitField {
    Title,
    Url,
    Text,
}

#[derive(Debug, Clone)]
struct SubmitState {
    title: Editor,
    url: Editor,
    text: Editor,
    focus: SubmitField,
    scroll: usize,
    submitting: bool,
    error: Option<String>,
    restored: bool,
}

impl SubmitState {
    fn new() -> Self {
        Self {
            title: Editor::default(),
            url: Editor::default(),
            text: Editor::default(),
            focus: SubmitField::Title,
            scroll: 0,
            submitting: false,
            error: None,
            restored: false,
        }
    }

    fn editor_mut(&mut self) -> &mut Editor {
        match self.focus {
            SubmitField::Title => &mut self.title,
            SubmitField::Url => &mut self.url,
            SubmitField::Text => &mut self.text,
        }
    }

    fn next_field(&mut self, delta: isize) {
        let index = match self.focus {
            SubmitField::Title => 0,
            SubmitField::Url => 1,
            SubmitField::Text => 2,
        };
        self.focus = match (index + delta).rem_euclid(3) {
            0 => SubmitField::Title,
            1 => SubmitField::Url,
            _ => SubmitField::Text,
        };
    }

    fn has_content(&self) -> bool {
        !self.title.trimmed().is_empty()
            || !self.url.trimmed().is_empty()
            || !self.text.trimmed().is_empty()
    }
}

#[derive(Debug, Clone)]
enum Overlay {
    Help,
    Commands {
        query: String,
        selected: usize,
    },
    Search {
        query: String,
    },
    Login {
        username: String,
        password: String,
        field: usize,
        error: Option<String>,
        submitting: bool,
    },
    Confirm {
        message: String,
        kind: ConfirmKind,
    },
    Compose(ComposeState),
    Submit(SubmitState),
}

#[derive(Debug, Clone, Copy)]
enum ConfirmKind {
    Delete(ItemId),
}

#[derive(Debug, Clone)]
struct Toast {
    message: String,
    color: Color,
    expires: std::time::Instant,
}

enum Event {
    SourceLoaded {
        generation: u64,
        source: Source,
        result: Result<(Vec<TuiEntry>, bool)>,
    },
    ThreadLoaded {
        generation: u64,
        id: ItemId,
        result: Result<Thread>,
    },
    LoggedIn(Result<UserSession>),
    CommentPosted {
        parent_id: ItemId,
        text: String,
        result: Result<Option<ItemId>>,
        item: Option<Item>,
    },
    Edited {
        id: ItemId,
        text: String,
        result: Result<()>,
    },
    Action(Result<String>),
    StorySubmitted(Result<Option<ItemId>>),
    User(Result<Option<UserSession>>),
}

struct App {
    client: Arc<HackerNews>,
    source: Source,
    sources: Vec<Source>,
    source_index: usize,
    entries: Vec<TuiEntry>,
    selected: usize,
    list_start: usize,
    has_more: bool,
    loading_source: bool,
    source_generation: u64,
    thread_generation: u64,
    detail: Detail,
    thread_loading: bool,
    focus: Focus,
    overlay: Option<Overlay>,
    user: Option<UserSession>,
    toast: Option<Toast>,
    should_quit: bool,
    spinner: usize,
    tx: mpsc::UnboundedSender<Event>,
    drafts: Drafts,
    list_height: usize,
    detail_height: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Focus {
    Sidebar,
    List,
    Detail,
}

impl App {
    fn new(client: Arc<HackerNews>, initial_feed: Feed, tx: mpsc::UnboundedSender<Event>) -> Self {
        let sources = sidebar_sources();
        let initial = Source::Feed(initial_feed);
        let source_index = sources
            .iter()
            .position(|source| *source == initial)
            .unwrap_or(0);
        let source = sources[source_index].clone();
        let drafts = load_drafts().unwrap_or_default();
        Self {
            client,
            source,
            sources,
            source_index,
            entries: Vec::new(),
            selected: 0,
            list_start: 0,
            has_more: false,
            loading_source: true,
            source_generation: 0,
            thread_generation: 0,
            detail: Detail::Empty,
            thread_loading: false,
            focus: Focus::List,
            overlay: None,
            user: None,
            toast: None,
            should_quit: false,
            spinner: 0,
            tx,
            drafts,
            list_height: 10,
            detail_height: 10,
        }
    }

    fn bootstrap(&mut self) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let session = client.current_session().await;
            let result = if session.is_some() {
                client.validate_session().await
            } else {
                Ok(None)
            };
            let _ = tx.send(Event::User(result));
        });
        self.load_source(true);
    }

    fn load_source(&mut self, reset: bool) {
        if reset {
            self.source_generation += 1;
            self.loading_source = true;
            self.has_more = false;
        }
        let generation = self.source_generation;
        let source = self.source.clone();
        let client = self.client.clone();
        let tx = self.tx.clone();
        let offset = if reset { 0 } else { self.entries.len() as u64 };
        let page = match PageRequest::new(offset, 30) {
            Ok(page) => page,
            Err(error) => {
                self.toast(error.to_string(), ERROR);
                self.loading_source = false;
                return;
            }
        };
        tokio::spawn(async move {
            let result = load_source_entries(&client, &source, page).await;
            let _ = tx.send(Event::SourceLoaded {
                generation,
                source,
                result,
            });
        });
    }

    fn handle_event(&mut self, event: Event) {
        match event {
            Event::SourceLoaded {
                generation,
                source,
                result,
            } => {
                if generation != self.source_generation || source != self.source {
                    return;
                }
                self.loading_source = false;
                match result {
                    Ok((entries, has_more)) => {
                        if generation == self.source_generation {
                            self.has_more = has_more;
                            if self.entries.is_empty() {
                                self.entries = entries;
                                self.selected = 0;
                            } else {
                                self.entries.extend(entries);
                            }
                            self.selected = self.selected.min(self.entries.len().saturating_sub(1));
                            self.set_preview();
                            self.ensure_list_visible();
                        }
                    }
                    Err(error) => {
                        self.toast(error.to_string(), ERROR);
                        if matches!(error, HnError::Unauthenticated) {
                            self.open_login();
                        }
                    }
                }
            }
            Event::ThreadLoaded {
                generation,
                id,
                result,
            } => {
                if generation != self.thread_generation {
                    return;
                }
                self.thread_loading = false;
                match result {
                    Ok(thread) => {
                        self.detail = Detail::Thread(ThreadState::new(thread));
                        self.focus = Focus::Detail;
                    }
                    Err(error) => {
                        self.toast(error.to_string(), ERROR);
                        self.detail = Detail::Error(id, error.to_string());
                    }
                }
            }
            Event::StorySubmitted(result) => match result {
                Ok(id) => {
                    self.drafts.remove(SUBMIT_DRAFT_KEY);
                    save_drafts(&self.drafts).ok();
                    self.overlay = None;
                    let message = match id {
                        Some(id) => format!("Submitted: https://news.ycombinator.com/item?id={id}"),
                        None => "Submitted to Hacker News".into(),
                    };
                    self.toast(message, SUCCESS);
                    self.load_source(true);
                }
                Err(error) => {
                    if let Some(Overlay::Submit(form)) = self.overlay.as_mut() {
                        form.submitting = false;
                        form.error = Some(error.to_string());
                    }
                }
            },
            Event::User(result) => {
                self.user = result.unwrap_or(None);
            }
            Event::LoggedIn(result) => match result {
                Ok(session) => {
                    self.user = Some(session.clone());
                    if matches!(self.overlay, Some(Overlay::Login { .. })) {
                        self.overlay = None;
                    }
                    self.toast(format!("Logged in as {}", session.user_id), SUCCESS);
                    if self.source.requires_auth() {
                        self.load_source(true);
                    }
                }
                Err(login_error) => {
                    if let Some(Overlay::Login {
                        error, submitting, ..
                    }) = self.overlay.as_mut()
                    {
                        *submitting = false;
                        *error = Some(login_error.to_string());
                    } else {
                        self.toast(login_error.to_string(), ERROR);
                    }
                }
            },
            Event::CommentPosted {
                parent_id,
                text,
                result,
                item,
            } => {
                if let Some(Overlay::Compose(compose)) = &self.overlay
                    && compose.kind != (ComposeKind::Comment { parent_id })
                {
                    return;
                }
                match result {
                    Ok(id) => {
                        self.drafts.remove(&key_comment(parent_id));
                        save_drafts(&self.drafts).ok();
                        self.overlay = None;
                        self.toast(
                            id.map(|id| format!("Comment posted: {id}"))
                                .unwrap_or_else(|| "Comment posted".into()),
                            SUCCESS,
                        );
                        if let (Some(item), Some(id)) = (item, id) {
                            if let Detail::Thread(thread) = &mut self.detail
                                && thread.insert(item, parent_id)
                            {
                                let _ = text;
                                self.focus = Focus::Detail;
                                return;
                            }
                            let _ = id;
                        }
                        if matches!(self.detail, Detail::Thread(_)) {
                            self.reload_thread();
                        }
                    }
                    Err(error) => {
                        if let Some(Overlay::Compose(compose)) = self.overlay.as_mut() {
                            compose.submitting = false;
                            compose.error = Some(error.to_string());
                        }
                        self.drafts.insert(
                            key_comment(parent_id),
                            DraftRecord {
                                text,
                                saved_at: Utc::now(),
                                title: None,
                                url: None,
                            },
                        );
                        save_drafts(&self.drafts).ok();
                    }
                }
            }
            Event::Edited { id, text, result } => match result {
                Ok(()) => {
                    self.drafts.remove(&key_edit(id));
                    save_drafts(&self.drafts).ok();
                    self.overlay = None;
                    self.toast(format!("Edited {id}"), SUCCESS);
                    if let Detail::Thread(thread) = &mut self.detail {
                        if thread.thread.root.id == id {
                            self.reload_thread();
                        } else {
                            thread.update_text(id, &text);
                        }
                    }
                }
                Err(error) => {
                    if let Some(Overlay::Compose(compose)) = self.overlay.as_mut() {
                        compose.submitting = false;
                        compose.error = Some(error.to_string());
                    }
                }
            },
            Event::Action(result) => match result {
                Ok(message) => self.toast(message, SUCCESS),
                Err(error) => {
                    self.toast(error.to_string(), ERROR);
                    if matches!(error, HnError::Unauthenticated) {
                        self.open_login();
                    }
                }
            },
        }
    }

    fn set_preview(&mut self) {
        if let Some(entry) = self.entries.get(self.selected).cloned() {
            self.detail = Detail::Preview(entry);
        } else {
            self.detail = Detail::Empty;
        }
    }

    fn open_selected(&mut self) {
        match self.focus {
            Focus::Sidebar => {
                self.select_source(self.source_index);
            }
            Focus::List => {
                if let Some(entry) = self.entries.get(self.selected).cloned() {
                    self.open_entry(entry);
                }
            }
            Focus::Detail => {
                if let Detail::Thread(thread) = &mut self.detail {
                    thread.toggle();
                } else if let Detail::Preview(entry) = &self.detail {
                    let entry = entry.clone();
                    self.open_entry(entry);
                }
            }
        }
    }

    fn open_entry(&mut self, entry: TuiEntry) {
        self.thread_generation += 1;
        let generation = self.thread_generation;
        self.detail = Detail::Preview(entry.clone());
        self.thread_loading = true;
        self.focus = Focus::Detail;
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = client.thread(entry.id).await;
            let _ = tx.send(Event::ThreadLoaded {
                generation,
                id: entry.id,
                result,
            });
        });
    }

    fn reload_thread(&mut self) {
        let id = match &self.detail {
            Detail::Thread(thread) => thread.thread.root.id,
            _ => return,
        };
        self.thread_generation += 1;
        let generation = self.thread_generation;
        self.thread_loading = true;
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = client.thread(id).await;
            let _ = tx.send(Event::ThreadLoaded {
                generation,
                id,
                result,
            });
        });
    }

    fn select_source(&mut self, index: usize) {
        if index >= self.sources.len() {
            return;
        }
        self.source_index = index;
        self.source = self.sources[index].clone();
        self.entries.clear();
        self.selected = 0;
        self.list_start = 0;
        self.detail = Detail::Empty;
        self.focus = Focus::List;
        if self.source.requires_auth() && self.user.is_none() {
            self.open_login();
            return;
        }
        self.load_source(true);
    }

    fn cycle_source(&mut self, delta: isize) {
        if self.sources.is_empty() {
            return;
        }
        let len = self.sources.len() as isize;
        let next = (self.source_index as isize + delta).rem_euclid(len) as usize;
        self.select_source(next);
    }

    fn move_selection(&mut self, delta: isize) {
        match self.focus {
            Focus::Sidebar => {
                let len = self.sources.len();
                if len > 0 {
                    self.source_index =
                        (self.source_index as isize + delta).clamp(0, len as isize - 1) as usize;
                }
            }
            Focus::List => {
                if !self.entries.is_empty() {
                    self.selected = (self.selected as isize + delta)
                        .clamp(0, self.entries.len() as isize - 1)
                        as usize;
                    self.set_preview();
                    self.ensure_list_visible();
                    if self.has_more && self.selected >= self.entries.len().saturating_sub(4) {
                        self.load_source(false);
                    }
                }
            }
            Focus::Detail => {
                if let Detail::Thread(thread) = &mut self.detail
                    && !thread.visible.is_empty()
                {
                    thread.selected = (thread.selected as isize + delta)
                        .clamp(0, thread.visible.len() as isize - 1)
                        as usize;
                }
            }
        }
    }

    fn move_top(&mut self) {
        match self.focus {
            Focus::Sidebar => self.source_index = 0,
            Focus::List => {
                self.selected = 0;
                self.list_start = 0;
                self.set_preview();
            }
            Focus::Detail => {
                if let Detail::Thread(thread) = &mut self.detail {
                    thread.selected = 0;
                }
            }
        }
    }

    fn move_bottom(&mut self) {
        match self.focus {
            Focus::Sidebar => self.source_index = self.sources.len().saturating_sub(1),
            Focus::List => {
                if !self.entries.is_empty() {
                    self.selected = self.entries.len() - 1;
                    self.set_preview();
                    self.ensure_list_visible();
                }
            }
            Focus::Detail => {
                if let Detail::Thread(thread) = &mut self.detail {
                    thread.selected = thread.visible.len().saturating_sub(1);
                }
            }
        }
    }

    fn page(&mut self, delta: isize) {
        let amount = if self.focus == Focus::Detail {
            (self.detail_height / 3).max(1)
        } else {
            (self.list_height / 2).max(1)
        };
        self.move_selection(delta * amount as isize);
    }

    fn cycle_focus(&mut self) {
        self.focus = match self.focus {
            Focus::Sidebar => Focus::List,
            Focus::List => {
                if matches!(self.detail, Detail::Thread(_)) {
                    Focus::Detail
                } else {
                    Focus::Sidebar
                }
            }
            Focus::Detail => Focus::Sidebar,
        };
    }

    fn go_back(&mut self) {
        if self.overlay.is_some() {
            self.close_overlay();
            return;
        }
        if self.focus == Focus::Detail {
            self.focus = Focus::List;
            self.set_preview();
        }
    }

    fn ensure_list_visible(&mut self) {
        let visible_entries = (self.list_height / 2).max(1);
        if self.selected < self.list_start {
            self.list_start = self.selected;
        } else if self.selected >= self.list_start + visible_entries {
            self.list_start = self.selected - visible_entries + 1;
        }
    }

    fn toast(&mut self, message: impl Into<String>, color: Color) {
        self.toast = Some(Toast {
            message: message.into(),
            color,
            expires: std::time::Instant::now() + Duration::from_secs(4),
        });
    }

    fn tick(&mut self) {
        self.spinner = (self.spinner + 1) % SPINNER.len();
        if let Some(toast) = &self.toast
            && toast.expires <= std::time::Instant::now()
        {
            self.toast = None;
        }
    }

    fn open_login(&mut self) {
        if self.user.is_some() {
            self.toast("Already logged in", WARNING);
            return;
        }
        self.overlay = Some(Overlay::Login {
            username: String::new(),
            password: String::new(),
            field: 0,
            error: None,
            submitting: false,
        });
    }

    fn submit_login(&mut self) {
        let Some(Overlay::Login {
            username,
            password,
            field,
            error,
            submitting,
        }) = self.overlay.as_mut()
        else {
            return;
        };
        if *submitting {
            return;
        }
        if username.trim().is_empty() {
            *error = Some("Enter your username".into());
            return;
        }
        if password.is_empty() {
            *error = Some("Enter your password".into());
            return;
        }
        let credentials = LoginCredentials {
            username: username.trim().to_string(),
            password: password.clone(),
        };
        *submitting = true;
        *error = None;
        let _ = field;
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = client.login(&credentials).await;
            let _ = tx.send(Event::LoggedIn(result));
        });
    }

    fn logout(&mut self) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = client.logout().await;
            if let Err(error) = result {
                let _ = tx.send(Event::Action(Err(error)));
            }
        });
        self.user = None;
        self.toast("Logged out", WARNING);
        if self.source.requires_auth() {
            self.select_source(0);
        }
    }

    fn open_compose_comment(&mut self) {
        let Some(target) = self.target_entry() else {
            self.toast("Select a story or comment to reply to", WARNING);
            return;
        };
        let kind = ComposeKind::Comment {
            parent_id: target.id,
        };
        let context = self.compose_context(&target, "Replying to");
        self.open_compose(kind, context, None);
    }

    fn open_compose_edit(&mut self) {
        let Some(target) = self.target_entry() else {
            self.toast("Select an item to edit", WARNING);
            return;
        };
        let kind = ComposeKind::Edit { item_id: target.id };
        let context = self.compose_context(&target, "Editing");
        self.open_compose(kind, context, target.text.clone());
    }

    fn compose_context(&self, target: &TuiEntry, label: &str) -> ComposeContext {
        let mut story_title = target.story_title.clone();
        if story_title.is_none()
            && let Detail::Thread(thread) = &self.detail
            && thread.thread.root.kind() == Some(ItemKind::Story)
        {
            story_title = Some(TuiEntry::from_item(&thread.thread.root).display_title());
        }
        if story_title.is_none() && target.kind == ItemKind::Story {
            story_title = Some(target.display_title());
        }
        ComposeContext {
            label: label.into(),
            author: target.author.clone(),
            story_title,
            excerpt: target.text.clone(),
            target: target.id,
        }
    }

    fn open_compose(
        &mut self,
        kind: ComposeKind,
        context: ComposeContext,
        initial: Option<String>,
    ) {
        let key = kind.key();
        let draft = self.drafts.get(&key).map(|record| record.text.clone());
        let restored = draft.is_some();
        let text = draft.or(initial).unwrap_or_default();
        self.overlay = Some(Overlay::Compose(ComposeState {
            kind,
            context,
            editor: Editor::new(text),
            scroll: 0,
            submitting: false,
            error: None,
            restored,
        }));
    }

    fn target_entry(&self) -> Option<TuiEntry> {
        if self.focus == Focus::Sidebar {
            return None;
        }
        if self.focus == Focus::Detail {
            if let Detail::Thread(thread) = &self.detail
                && let Some(item) = thread.selected_item()
            {
                return Some(TuiEntry::from_item(item));
            }
            if let Detail::Preview(entry) = &self.detail {
                return Some(entry.clone());
            }
        }
        self.entries.get(self.selected).cloned()
    }

    fn submit_compose(&mut self) {
        let Some(Overlay::Compose(compose)) = self.overlay.as_mut() else {
            return;
        };
        if compose.submitting {
            return;
        }
        if compose.editor.trimmed().is_empty() {
            compose.error = Some("Write something first".into());
            return;
        }
        compose.submitting = true;
        compose.error = None;
        let kind = compose.kind.clone();
        let text = compose.editor.text.clone();
        let key = kind.key();
        self.drafts.insert(
            key.clone(),
            DraftRecord {
                text: text.clone(),
                saved_at: Utc::now(),
                title: None,
                url: None,
            },
        );
        save_drafts(&self.drafts).ok();
        let client = self.client.clone();
        let tx = self.tx.clone();
        match kind {
            ComposeKind::Comment { parent_id } => {
                let submission = match CommentSubmission::new(parent_id, text.clone()) {
                    Ok(submission) => submission,
                    Err(error) => {
                        if let Some(Overlay::Compose(compose)) = self.overlay.as_mut() {
                            compose.submitting = false;
                            compose.error = Some(error.to_string());
                        }
                        return;
                    }
                };
                tokio::spawn(async move {
                    let result = client.submit_comment(&submission).await;
                    let item = if let Ok(Some(id)) = &result {
                        client.item(*id).await.ok().flatten()
                    } else {
                        None
                    };
                    let _ = tx.send(Event::CommentPosted {
                        parent_id,
                        text,
                        result,
                        item,
                    });
                });
            }
            ComposeKind::Edit { item_id } => {
                tokio::spawn(async move {
                    let result = client.edit_item(item_id, &text).await;
                    let _ = tx.send(Event::Edited {
                        id: item_id,
                        text,
                        result,
                    });
                });
            }
        }
        let _ = key;
    }

    fn cancel_compose(&mut self) {
        let Some(Overlay::Compose(compose)) = self.overlay.as_ref() else {
            return;
        };
        if compose.submitting {
            return;
        }
        let key = compose.kind.key();
        if compose.editor.trimmed().is_empty() {
            self.drafts.remove(&key);
        } else {
            self.drafts.insert(
                key,
                DraftRecord {
                    text: compose.editor.text.clone(),
                    saved_at: Utc::now(),
                    title: None,
                    url: None,
                },
            );
        }
        save_drafts(&self.drafts).ok();
        self.overlay = None;
        self.toast("Draft saved", WARNING);
    }

    fn save_active_draft(&mut self) {
        if let Some(Overlay::Compose(compose)) = &self.overlay
            && !compose.editor.trimmed().is_empty()
        {
            self.drafts.insert(
                compose.kind.key(),
                DraftRecord {
                    text: compose.editor.text.clone(),
                    saved_at: Utc::now(),
                    title: None,
                    url: None,
                },
            );
            save_drafts(&self.drafts).ok();
        } else if let Some(Overlay::Submit(form)) = &self.overlay
            && form.has_content()
        {
            self.drafts.insert(
                SUBMIT_DRAFT_KEY.into(),
                DraftRecord {
                    text: form.text.text.clone(),
                    saved_at: Utc::now(),
                    title: Some(form.title.text.clone()).filter(|title| !title.trim().is_empty()),
                    url: Some(form.url.text.clone()).filter(|url| !url.trim().is_empty()),
                },
            );
            save_drafts(&self.drafts).ok();
        }
    }

    fn close_overlay(&mut self) {
        if matches!(self.overlay, Some(Overlay::Compose(_))) {
            self.cancel_compose();
        } else if matches!(self.overlay, Some(Overlay::Submit(_))) {
            self.cancel_submit();
        } else {
            self.overlay = None;
        }
    }

    fn open_search(&mut self) {
        let query = if let Source::Search(query) = &self.source {
            query.clone()
        } else {
            String::new()
        };
        self.overlay = Some(Overlay::Search { query });
    }

    fn perform_search(&mut self, query: String) {
        let query = query.trim().to_string();
        if query.is_empty() {
            self.overlay = None;
            return;
        }
        self.overlay = None;
        self.source = Source::Search(query);
        self.entries.clear();
        self.selected = 0;
        self.focus = Focus::List;
        self.load_source(true);
    }

    fn open_commands(&mut self) {
        self.overlay = Some(Overlay::Commands {
            query: String::new(),
            selected: 0,
        });
    }

    fn command_items(&self) -> Vec<(String, Command)> {
        let mut commands = Vec::new();
        for (index, source) in self.sources.iter().enumerate() {
            commands.push((format!("Go to {}", source.label()), Command::Source(index)));
        }
        commands.push(("Submit a story".into(), Command::Submit));
        commands.push(("Search Hacker News".into(), Command::Search));
        commands.push(("Refresh".into(), Command::Refresh));
        commands.push(("Keyboard help".into(), Command::Help));
        if self.user.is_some() {
            commands.push(("Log out".into(), Command::Logout));
        } else {
            commands.push(("Log in".into(), Command::Login));
        }
        commands.push(("Quit".into(), Command::Quit));
        commands
    }

    fn filtered_commands(&self) -> Vec<(String, Command)> {
        let Some(Overlay::Commands { query, .. }) = &self.overlay else {
            return Vec::new();
        };
        let query = query.trim().to_lowercase();
        self.command_items()
            .into_iter()
            .filter(|(title, _)| query.is_empty() || title.to_lowercase().contains(&query))
            .collect()
    }

    fn execute_command(&mut self) {
        let commands = self.filtered_commands();
        let Some(Overlay::Commands { selected, .. }) = &self.overlay else {
            return;
        };
        let selected = *selected;
        let Some((_, command)) = commands.get(selected) else {
            self.overlay = None;
            return;
        };
        self.overlay = None;
        match command {
            Command::Source(index) => self.select_source(*index),
            Command::Submit => self.open_submit(),
            Command::Search => self.open_search(),
            Command::Refresh => {
                self.load_source(true);
                if matches!(self.detail, Detail::Thread(_)) {
                    self.reload_thread();
                }
            }
            Command::Login => self.open_login(),
            Command::Logout => self.logout(),
            Command::Help => self.overlay = Some(Overlay::Help),
            Command::Quit => self.should_quit = true,
        }
    }

    fn spawn_action<F>(&self, future: F)
    where
        F: std::future::Future<Output = Result<String>> + Send + 'static,
    {
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let _ = tx.send(Event::Action(future.await));
        });
    }

    fn vote(&mut self, direction: VoteDirection) {
        let Some(target) = self.target_entry() else {
            return;
        };
        let client = self.client.clone();
        self.spawn_action(async move {
            client.vote(target.id, direction).await?;
            let label = match direction {
                VoteDirection::Up => "Upvoted",
                VoteDirection::Down => "Downvoted",
                VoteDirection::Unvote => "Removed vote on",
            };
            Ok(format!("{label} {}", target.id))
        });
    }

    fn favorite(&mut self, undo: bool) {
        let Some(target) = self.target_entry() else {
            return;
        };
        let client = self.client.clone();
        self.spawn_action(async move {
            client.set_favorite(target.id, !undo).await?;
            Ok(if undo {
                format!("Removed {} from favorites", target.id)
            } else {
                format!("Favorited {}", target.id)
            })
        });
    }

    fn hide(&mut self, undo: bool) {
        let Some(target) = self.target_entry() else {
            return;
        };
        let client = self.client.clone();
        self.spawn_action(async move {
            client.set_hidden(target.id, !undo).await?;
            Ok(if undo {
                format!("Unhid {}", target.id)
            } else {
                format!("Hid {}", target.id)
            })
        });
    }

    fn flag(&mut self) {
        let Some(target) = self.target_entry() else {
            return;
        };
        let client = self.client.clone();
        self.spawn_action(async move {
            client.flag(target.id, "").await?;
            Ok(format!("Flagged {}", target.id))
        });
    }

    fn request_delete(&mut self) {
        let Some(target) = self.target_entry() else {
            return;
        };
        self.overlay = Some(Overlay::Confirm {
            message: format!("Delete item {}?", target.id),
            kind: ConfirmKind::Delete(target.id),
        });
    }

    fn confirm_yes(&mut self) {
        let Some(Overlay::Confirm { kind, .. }) = self.overlay.clone() else {
            return;
        };
        self.overlay = None;
        match kind {
            ConfirmKind::Delete(id) => {
                let client = self.client.clone();
                self.spawn_action(async move {
                    client.delete_item(id).await?;
                    Ok(format!("Deleted {}", id))
                });
            }
        }
    }

    fn open_url(&self) {
        let Some(target) = self.target_entry() else {
            return;
        };
        let url = target
            .url
            .clone()
            .unwrap_or_else(|| format!("https://news.ycombinator.com/item?id={}", target.id.0));
        let command = if cfg!(target_os = "macos") {
            "open"
        } else {
            "xdg-open"
        };
        let _ = std::process::Command::new(command).arg(url).spawn();
    }

    fn copy_url(&mut self) {
        let Some(target) = self.target_entry() else {
            return;
        };
        let url = target
            .url
            .clone()
            .unwrap_or_else(|| format!("https://news.ycombinator.com/item?id={}", target.id.0));
        let command = if cfg!(target_os = "macos") {
            "pbcopy"
        } else {
            "xclip"
        };
        let process = std::process::Command::new(command)
            .stdin(std::process::Stdio::piped())
            .spawn();
        if let Ok(mut child) = process {
            if let Some(stdin) = child.stdin.as_mut() {
                let _ = stdin.write_all(url.as_bytes());
            }
            let _ = child.wait();
            self.toast("Copied URL", SUCCESS);
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum Command {
    Source(usize),
    Submit,
    Search,
    Refresh,
    Login,
    Logout,
    Help,
    Quit,
}

fn sidebar_sources() -> Vec<Source> {
    vec![
        Source::Feed(Feed::FrontPage),
        Source::Feed(Feed::New),
        Source::Feed(Feed::Best),
        Source::Feed(Feed::Ask),
        Source::Feed(Feed::Show),
        Source::Feed(Feed::Jobs),
        Source::Feed(Feed::Active),
        Source::Feed(Feed::LatestComments),
        Source::Feed(Feed::NoobStories),
        Source::Feed(Feed::NoobComments),
        Source::Feed(Feed::PastFrontPage(CalendarDay::yesterday())),
        Source::Upvoted,
        Source::Hidden,
    ]
}

async fn load_source_entries(
    client: &HackerNews,
    source: &Source,
    page: PageRequest,
) -> Result<(Vec<TuiEntry>, bool)> {
    match source {
        Source::Feed(feed) => {
            let page = client.feed_entries(feed, page).await?;
            Ok((
                page.entries.iter().map(TuiEntry::from_site).collect(),
                page.has_more,
            ))
        }
        Source::Upvoted | Source::Hidden => {
            let session = client
                .current_session()
                .await
                .ok_or(HnError::Unauthenticated)?;
            let kind = if matches!(source, Source::Upvoted) {
                UserActivityKind::Upvoted
            } else {
                UserActivityKind::Hidden
            };
            let page = client.activity(&session.user_id, kind, page).await?;
            Ok((
                page.items.iter().map(TuiEntry::from_item).collect(),
                page.has_more,
            ))
        }
        Source::Search(query) => {
            let results = client
                .search(&SearchQuery {
                    terms: query.clone(),
                    kinds: vec![ItemKind::Story, ItemKind::Comment],
                    page,
                    ..SearchQuery::default()
                })
                .await?;
            Ok((
                results.hits.iter().map(TuiEntry::from_hit).collect(),
                results.has_more(),
            ))
        }
    }
}

pub async fn run(client: HackerNews, initial_feed: Feed) -> Result<()> {
    let client = Arc::new(client);
    let (tx, mut rx) = mpsc::unbounded_channel();
    let mut app = App::new(client, initial_feed, tx);
    app.bootstrap();

    enable_raw_mode().map_err(|error| HnError::Transport(error.to_string()))?;
    let mut stdout = io::stdout();
    execute!(
        stdout,
        EnterAlternateScreen,
        EnableMouseCapture,
        EnableBracketedPaste,
        crossterm::cursor::Hide
    )
    .map_err(|error| HnError::Transport(error.to_string()))?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal =
        Terminal::new(backend).map_err(|error| HnError::Transport(error.to_string()))?;

    let guard = TerminalGuard;
    let mut events = EventStream::new();
    let mut ticker = tokio::time::interval(Duration::from_millis(180));
    let result = loop {
        if let Err(error) = terminal.draw(|frame| draw(frame, &mut app)) {
            break Err(HnError::Transport(error.to_string()));
        }
        if app.should_quit {
            break Ok(());
        }
        tokio::select! {
            maybe_event = events.next() => {
                match maybe_event {
                    Some(Ok(event)) => app.handle_terminal_event(event),
                    Some(Err(error)) => break Err(HnError::Transport(error.to_string())),
                    None => break Ok(()),
                }
            }
            Some(event) = rx.recv() => app.handle_event(event),
            _ = ticker.tick() => app.tick(),
        }
    };

    drop(guard);
    let _ = terminal.show_cursor();
    result
}

struct TerminalGuard;

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(
            io::stdout(),
            LeaveAlternateScreen,
            DisableMouseCapture,
            DisableBracketedPaste,
            crossterm::cursor::Show
        );
    }
}

impl App {
    fn handle_terminal_event(&mut self, event: TermEvent) {
        match event {
            TermEvent::Key(key) => {
                if key.kind == event::KeyEventKind::Release {
                    return;
                }
                self.handle_key(key);
            }
            TermEvent::Mouse(mouse) => match mouse.kind {
                MouseEventKind::ScrollUp => self.move_selection(-1),
                MouseEventKind::ScrollDown => self.move_selection(1),
                _ => {}
            },
            TermEvent::Resize(_, _) => {}
            TermEvent::Paste(text) => {
                if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                    compose.editor.insert(&text);
                } else if let Some(Overlay::Submit(form)) = &mut self.overlay {
                    form.editor_mut().insert(&text);
                }
            }
            _ => {}
        }
    }

    fn handle_key(&mut self, key: KeyEvent) {
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
            self.save_active_draft();
            self.should_quit = true;
            return;
        }
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('p') {
            self.open_commands();
            return;
        }
        if self.overlay.is_some() {
            self.handle_overlay_key(key);
            return;
        }
        match key.code {
            KeyCode::Char('q') => {
                self.save_active_draft();
                self.should_quit = true;
            }
            KeyCode::Char('?') => self.overlay = Some(Overlay::Help),
            KeyCode::Char(':') => self.open_commands(),
            KeyCode::Char('/') => self.open_search(),
            KeyCode::Char('L') => self.open_login(),
            KeyCode::Char('r') => {
                self.load_source(true);
                if matches!(self.detail, Detail::Thread(_)) {
                    self.reload_thread();
                }
            }
            KeyCode::Char('j') | KeyCode::Down => self.move_selection(1),
            KeyCode::Char('k') | KeyCode::Up => self.move_selection(-1),
            KeyCode::Char('g') | KeyCode::Home => self.move_top(),
            KeyCode::Char('G') | KeyCode::End => self.move_bottom(),
            KeyCode::PageDown => self.page(1),
            KeyCode::PageUp => self.page(-1),
            KeyCode::Tab => self.cycle_focus(),
            KeyCode::Enter | KeyCode::Char('l') | KeyCode::Right => self.open_selected(),
            KeyCode::Esc | KeyCode::Char('h') | KeyCode::Left => self.go_back(),
            KeyCode::Char(' ') => {
                if self.focus == Focus::Detail {
                    if let Detail::Thread(thread) = &mut self.detail {
                        thread.toggle();
                    }
                } else {
                    self.open_selected();
                }
            }
            KeyCode::Char('v') => self.vote(VoteDirection::Up),
            KeyCode::Char('V') => self.vote(VoteDirection::Down),
            KeyCode::Char('u') => self.vote(VoteDirection::Unvote),
            KeyCode::Char('f') => self.favorite(false),
            KeyCode::Char('F') => self.favorite(true),
            KeyCode::Char('H') => self.hide(false),
            KeyCode::Char('U') => self.hide(true),
            KeyCode::Char('!') => self.flag(),
            KeyCode::Char('c') => self.open_compose_comment(),
            KeyCode::Char('e') => self.open_compose_edit(),
            KeyCode::Char('d') => self.request_delete(),
            KeyCode::Char('s') => self.open_submit(),
            KeyCode::Char('o') => self.open_url(),
            KeyCode::Char('y') => self.copy_url(),
            KeyCode::Char('[') => self.cycle_source(-1),
            KeyCode::Char(']') => self.cycle_source(1),
            KeyCode::Char(character) if character.is_ascii_digit() => {
                if let Some(index) = character.to_digit(10)
                    && index > 0
                {
                    self.select_source(index as usize - 1);
                }
            }
            _ => {}
        }
    }

    fn open_submit(&mut self) {
        let mut form = SubmitState::new();
        if let Some(draft) = self.drafts.get(SUBMIT_DRAFT_KEY).cloned() {
            form.title = Editor::new(draft.title.unwrap_or_default());
            form.url = Editor::new(draft.url.unwrap_or_default());
            form.text = Editor::new(draft.text);
            form.restored = form.has_content();
        }
        self.overlay = Some(Overlay::Submit(form));
    }

    fn cancel_submit(&mut self) {
        let Some(Overlay::Submit(form)) = self.overlay.as_ref() else {
            return;
        };
        if form.submitting {
            return;
        }
        let draft = if form.has_content() {
            Some(DraftRecord {
                text: form.text.text.clone(),
                saved_at: Utc::now(),
                title: Some(form.title.text.clone()).filter(|title| !title.trim().is_empty()),
                url: Some(form.url.text.clone()).filter(|url| !url.trim().is_empty()),
            })
        } else {
            None
        };
        if let Some(draft) = draft {
            self.drafts.insert(SUBMIT_DRAFT_KEY.into(), draft);
        } else {
            self.drafts.remove(SUBMIT_DRAFT_KEY);
        }
        save_drafts(&self.drafts).ok();
        self.overlay = None;
        self.toast("Draft saved", WARNING);
    }

    fn submit_story_form(&mut self) {
        let Some(Overlay::Submit(form)) = self.overlay.as_mut() else {
            return;
        };
        if form.submitting {
            return;
        }
        let title = form.title.text.trim().to_string();
        let url = form.url.text.trim().to_string();
        let text = form.text.text.trim().to_string();
        if title.is_empty() {
            form.error = Some("Title is required".into());
            form.focus = SubmitField::Title;
            return;
        }
        if title.chars().count() > 80 {
            form.error = Some("Titles are limited to 80 characters".into());
            form.focus = SubmitField::Title;
            return;
        }
        let url = if url.is_empty() { None } else { Some(url) };
        let text = if text.is_empty() { None } else { Some(text) };
        let submission = match StorySubmission::new(title.clone(), url.clone(), text.clone()) {
            Ok(submission) => submission,
            Err(error) => {
                form.error = Some(error.to_string());
                form.focus = if form.url.text.trim().is_empty() && text.is_none() {
                    SubmitField::Text
                } else if !form.url.text.trim().is_empty() {
                    SubmitField::Url
                } else {
                    SubmitField::Title
                };
                return;
            }
        };
        form.submitting = true;
        form.error = None;
        self.drafts.insert(
            SUBMIT_DRAFT_KEY.into(),
            DraftRecord {
                text: text.clone().unwrap_or_default(),
                saved_at: Utc::now(),
                title: Some(title.clone()),
                url: url.clone(),
            },
        );
        save_drafts(&self.drafts).ok();
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = client.submit_story(&submission).await;
            let _ = tx.send(Event::StorySubmitted(result));
        });
    }

    fn handle_overlay_key(&mut self, key: KeyEvent) {
        let control = key.modifiers.contains(KeyModifiers::CONTROL);
        match self.overlay.clone() {
            Some(Overlay::Help) => {
                self.overlay = None;
            }
            Some(Overlay::Commands { .. }) => match key.code {
                KeyCode::Esc => self.overlay = None,
                KeyCode::Enter => self.execute_command(),
                KeyCode::Up => {
                    if let Some(Overlay::Commands { selected, .. }) = &mut self.overlay {
                        *selected = selected.saturating_sub(1);
                    }
                }
                KeyCode::Down => {
                    let count = self.filtered_commands().len();
                    if let Some(Overlay::Commands { selected, .. }) = &mut self.overlay {
                        *selected = (*selected + 1).min(count.saturating_sub(1));
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Overlay::Commands { query, selected }) = &mut self.overlay {
                        query.pop();
                        *selected = 0;
                    }
                }
                KeyCode::Char(character) => {
                    if let Some(Overlay::Commands { query, selected }) = &mut self.overlay {
                        query.push(character);
                        *selected = 0;
                    }
                }
                _ => {}
            },
            Some(Overlay::Search { .. }) => match key.code {
                KeyCode::Esc => self.overlay = None,
                KeyCode::Enter => {
                    if let Some(Overlay::Search { query }) = &self.overlay {
                        let query = query.clone();
                        self.perform_search(query);
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Overlay::Search { query }) = &mut self.overlay {
                        query.pop();
                    }
                }
                KeyCode::Char(character) => {
                    if let Some(Overlay::Search { query }) = &mut self.overlay {
                        query.push(character);
                    }
                }
                _ => {}
            },
            Some(Overlay::Login { .. }) => match key.code {
                KeyCode::Esc => self.overlay = None,
                KeyCode::Tab => {
                    if let Some(Overlay::Login { field, .. }) = &mut self.overlay {
                        *field = if *field == 0 { 1 } else { 0 };
                    }
                }
                KeyCode::Enter => self.submit_login(),
                KeyCode::Backspace => {
                    if let Some(Overlay::Login {
                        username,
                        password,
                        field,
                        ..
                    }) = &mut self.overlay
                    {
                        if *field == 0 {
                            username.pop();
                        } else {
                            password.pop();
                        }
                    }
                }
                KeyCode::Char(character) => {
                    if let Some(Overlay::Login {
                        username,
                        password,
                        field,
                        ..
                    }) = &mut self.overlay
                    {
                        if *field == 0 {
                            username.push(character);
                        } else {
                            password.push(character);
                        }
                    }
                }
                _ => {}
            },
            Some(Overlay::Confirm { .. }) => match key.code {
                KeyCode::Char('y') | KeyCode::Char('Y') => self.confirm_yes(),
                KeyCode::Esc | KeyCode::Char('n') | KeyCode::Char('N') => self.overlay = None,
                _ => {}
            },
            Some(Overlay::Submit(_)) => {
                if control && key.code == KeyCode::Char('s') {
                    self.submit_story_form();
                    return;
                }
                if key.code == KeyCode::Esc {
                    self.cancel_submit();
                    return;
                }
                let Some(Overlay::Submit(form)) = self.overlay.as_mut() else {
                    return;
                };
                if form.submitting {
                    return;
                }
                match key.code {
                    KeyCode::Tab => form.next_field(1),
                    KeyCode::BackTab => form.next_field(-1),
                    KeyCode::Enter => {
                        if form.focus == SubmitField::Text {
                            form.text.insert("\n");
                        } else {
                            form.next_field(1);
                        }
                    }
                    KeyCode::Backspace => form.editor_mut().backspace(),
                    KeyCode::Delete => form.editor_mut().delete_forward(),
                    KeyCode::Left => form.editor_mut().move_left(),
                    KeyCode::Right => form.editor_mut().move_right(),
                    KeyCode::Up => form.editor_mut().move_up(),
                    KeyCode::Down => form.editor_mut().move_down(),
                    KeyCode::Home => form.editor_mut().move_home(),
                    KeyCode::End => form.editor_mut().move_end(),
                    KeyCode::PageUp => form.editor_mut().page(true),
                    KeyCode::PageDown => form.editor_mut().page(false),
                    KeyCode::Char(character) => {
                        form.error = None;
                        if form.focus == SubmitField::Text {
                            form.text.insert(&character.to_string());
                        } else {
                            form.editor_mut().insert_single_line(&character.to_string());
                        }
                    }
                    _ => {}
                }
            }
            Some(Overlay::Compose(_)) => {
                if control && key.code == KeyCode::Char('s') {
                    self.submit_compose();
                    return;
                }
                match key.code {
                    KeyCode::Esc => self.cancel_compose(),
                    KeyCode::Enter => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.insert("\n");
                        }
                    }
                    KeyCode::Tab => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.insert("  ");
                        }
                    }
                    KeyCode::Backspace => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.backspace();
                        }
                    }
                    KeyCode::Delete => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.delete_forward();
                        }
                    }
                    KeyCode::Left => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.move_left();
                        }
                    }
                    KeyCode::Right => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.move_right();
                        }
                    }
                    KeyCode::Up => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.move_up();
                        }
                    }
                    KeyCode::Down => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.move_down();
                        }
                    }
                    KeyCode::Home => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.move_home();
                        }
                    }
                    KeyCode::End => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.move_end();
                        }
                    }
                    KeyCode::PageUp => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.page(true);
                        }
                    }
                    KeyCode::PageDown => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.page(false);
                        }
                    }
                    KeyCode::Char(character) => {
                        if let Some(Overlay::Compose(compose)) = &mut self.overlay {
                            compose.editor.insert(&character.to_string());
                        }
                    }
                    _ => {}
                }
            }
            None => {}
        }
    }
}

fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();
    if area.height < 8 || area.width < 20 {
        return;
    }
    let chunks = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .split(area);
    draw_header(frame, app, chunks[0]);
    frame.render_widget(
        Paragraph::new("─".repeat(area.width as usize)).style(muted()),
        chunks[1],
    );
    draw_body(frame, app, chunks[2]);
    frame.render_widget(
        Paragraph::new("─".repeat(area.width as usize)).style(muted()),
        chunks[3],
    );
    draw_footer(frame, app, chunks[4]);
    draw_overlay(frame, app, chunks[2]);
}

fn draw_header(frame: &mut Frame, app: &App, area: Rect) {
    let mut spans = vec![
        Span::styled(
            "hn",
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ),
        Span::styled("  /  ", muted()),
        Span::styled(
            app.source.label(),
            Style::default().add_modifier(Modifier::BOLD),
        ),
    ];
    if let Detail::Thread(thread) = &app.detail {
        spans.push(Span::styled("  /  ", muted()));
        spans.push(Span::styled(
            format!("item {}", thread.thread.root.id),
            muted(),
        ));
    }
    let line = Line::from(spans);
    frame.render_widget(Paragraph::new(line), area);
    if area.width > 30 {
        let user = if let Some(user) = &app.user {
            format!("● {}", user.user_id)
        } else {
            "○ not logged in".into()
        };
        let style = if app.user.is_some() {
            Style::default().fg(SUCCESS)
        } else {
            muted()
        };
        let width = display_width(&user);
        let x = area.width.saturating_sub(width as u16 + 1);
        frame.render_widget(
            Paragraph::new(user)
                .style(style)
                .alignment(Alignment::Right),
            Rect::new(area.x + x, area.y, width as u16 + 1, 1),
        );
    }
}

fn draw_body(frame: &mut Frame, app: &mut App, area: Rect) {
    if area.width < 78 {
        let show_detail = app.focus == Focus::Detail;
        if show_detail {
            app.list_height = 0;
            app.detail_height = area.height as usize;
            draw_detail(frame, app, area);
        } else {
            app.list_height = area.height as usize;
            app.detail_height = 0;
            draw_list(frame, app, area);
        }
        return;
    }
    let sidebar_width = 20u16.min(area.width / 5).max(14);
    let remaining = area.width.saturating_sub(sidebar_width + 2);
    let list_width = (remaining * 2 / 5).max(24);
    let detail_width = remaining.saturating_sub(list_width);
    let columns = Layout::horizontal([
        Constraint::Length(sidebar_width),
        Constraint::Length(1),
        Constraint::Length(list_width),
        Constraint::Length(1),
        Constraint::Length(detail_width),
    ])
    .split(area);
    draw_sidebar(frame, app, columns[0]);
    draw_separator(frame, columns[1], area.height);
    app.list_height = columns[2].height as usize;
    draw_list(frame, app, columns[2]);
    draw_separator(frame, columns[3], area.height);
    app.detail_height = columns[4].height as usize;
    draw_detail(frame, app, columns[4]);
}

fn draw_separator(frame: &mut Frame, area: Rect, height: u16) {
    let lines = vec![Line::from("│"); height as usize];
    frame.render_widget(Paragraph::new(lines).style(muted()), area);
}

fn draw_sidebar(frame: &mut Frame, app: &App, area: Rect) {
    let mut lines = Vec::new();
    let sections = [("FEEDS", 0, 6), ("MORE", 6, 11), ("YOURS", 11, 13)];
    for (title, start, end) in sections {
        lines.push(Line::from(Span::styled(title, muted())));
        for index in start..end.min(app.sources.len()) {
            let source = &app.sources[index];
            let current = index == app.source_index;
            let active = app.focus == Focus::Sidebar && index == app.source_index;
            let prefix = if current { "▸ " } else { "  " };
            let style = if active {
                Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)
            } else if current {
                Style::default().fg(ACCENT)
            } else {
                Style::default()
            };
            let mut label = source.label();
            if source.requires_auth() && app.user.is_none() {
                label.push_str("  login");
            }
            lines.push(Line::from(vec![
                Span::styled(prefix, Style::default().fg(ACCENT)),
                Span::styled(label, style),
            ]));
        }
        lines.push(Line::default());
    }
    frame.render_widget(Paragraph::new(lines), area);
}

fn draw_list(frame: &mut Frame, app: &mut App, area: Rect) {
    if area.height < 2 {
        return;
    }
    let mut lines = Vec::new();
    let mut header = vec![Span::styled(
        app.source.label().to_uppercase(),
        Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
    )];
    if !app.entries.is_empty() {
        header.push(Span::styled(format!("  {}", app.entries.len()), muted()));
    }
    if app.loading_source {
        header.push(Span::styled(
            format!("  {} loading", SPINNER[app.spinner]),
            muted(),
        ));
    }
    lines.push(Line::from(header));
    lines.push(Line::from(Span::styled(
        "─".repeat(area.width as usize),
        muted(),
    )));
    let content_height = area.height.saturating_sub(2) as usize;
    app.list_height = content_height;
    if app.entries.is_empty() {
        if app.loading_source {
            lines.push(Line::from(Span::styled(
                format!("{} loading…", SPINNER[app.spinner]),
                muted(),
            )));
        } else {
            lines.push(Line::from(Span::styled("Nothing here.", muted())));
        }
        frame.render_widget(Paragraph::new(lines), area);
        return;
    }
    let visible_entries = (content_height / 2).max(1);
    if app.selected < app.list_start {
        app.list_start = app.selected;
    } else if app.selected >= app.list_start + visible_entries {
        app.list_start = app.selected - visible_entries + 1;
    }
    let start = app.list_start.min(app.entries.len().saturating_sub(1));
    let mut rendered = 0usize;
    for (index, entry) in app.entries.iter().enumerate().skip(start) {
        if rendered + 2 > content_height {
            break;
        }
        let selected = index == app.selected;
        let focused = selected && app.focus == Focus::List;
        let (title, meta) = entry_lines(entry, index + 1, area.width);
        let style = if focused {
            Style::default().add_modifier(Modifier::REVERSED)
        } else {
            Style::default()
        };
        let bar = if selected { "▌ " } else { "  " };
        lines.push(Line::from(vec![
            Span::styled(
                bar,
                Style::default().fg(if selected { ACCENT } else { Color::Reset }),
            ),
            Span::styled(title, if focused { style } else { Style::default() }),
        ]));
        lines.push(Line::from(vec![
            Span::styled("  ", Style::default()),
            Span::styled(meta, if focused { style } else { muted() }),
        ]));
        rendered += 2;
    }
    frame.render_widget(Paragraph::new(lines), area);
}

fn draw_detail(frame: &mut Frame, app: &mut App, area: Rect) {
    let mut lines = Vec::new();
    match &mut app.detail {
        Detail::Empty => {
            lines.push(Line::from(Span::styled(
                "Select a story to read it.",
                muted(),
            )));
        }
        Detail::Preview(entry) => {
            lines.extend(entry_preview_lines(entry, area.width));
            if app.thread_loading {
                lines.push(Line::from(Span::styled(
                    format!("{} loading comments…", SPINNER[app.spinner]),
                    Style::default().fg(ACCENT),
                )));
            }
        }
        Detail::Error(id, message) => {
            lines.push(Line::from(Span::styled(
                format!("Could not load item {id}"),
                Style::default().fg(ERROR),
            )));
            lines.push(Line::from(Span::styled(message.clone(), muted())));
            lines.push(Line::default());
            lines.push(Line::from(Span::styled("r to retry · esc back", muted())));
        }
        Detail::Thread(thread) => {
            let mut all_lines = Vec::new();
            let root = TuiEntry::from_item(&thread.thread.root);
            all_lines.extend(entry_preview_lines(&root, area.width));
            all_lines.push(Line::from(Span::styled(
                "─".repeat(area.width.saturating_sub(2) as usize),
                muted(),
            )));
            let mut selected_line = 0usize;
            for (index, comment) in thread.visible.iter().enumerate() {
                if index == thread.selected {
                    selected_line = all_lines.len();
                }
                let indent = "  ".repeat(comment.depth);
                let author = comment
                    .item
                    .author
                    .as_ref()
                    .map(|author| author.0.as_str())
                    .unwrap_or("[deleted]");
                let mut spans = vec![
                    Span::styled(indent.clone(), muted()),
                    Span::styled(
                        if index == thread.selected {
                            "▌ "
                        } else {
                            "  "
                        },
                        Style::default().fg(if index == thread.selected {
                            ACCENT
                        } else {
                            Color::Reset
                        }),
                    ),
                ];
                if comment.item.flags.deleted {
                    spans.push(Span::styled("[deleted]", muted()));
                } else {
                    spans.push(Span::styled(author.to_string(), Style::default().fg(LINK)));
                    spans.push(Span::styled(
                        format!(
                            " · {} · {}",
                            relative_time(comment.item.created_at),
                            comment.item.id
                        ),
                        muted(),
                    ));
                    if comment.item.flags.dead {
                        spans.push(Span::styled(" dead", Style::default().fg(WARNING)));
                    }
                }
                if comment.has_children {
                    spans.push(Span::styled(
                        if comment.collapsed { "  ▸" } else { "  ▾" },
                        muted(),
                    ));
                }
                all_lines.push(Line::from(spans));
                if comment.collapsed {
                    all_lines.push(Line::from(Span::styled(
                        format!("{indent}    collapsed replies"),
                        muted(),
                    )));
                } else if let Some(text) = comment.item.text() {
                    let text = html_to_text(&text.0, area.width as usize);
                    for line in text.lines() {
                        all_lines.push(Line::from(vec![
                            Span::styled(indent.clone(), muted()),
                            Span::styled("  ", Style::default()),
                            Span::styled(line.to_string(), Style::default()),
                        ]));
                    }
                }
                all_lines.push(Line::default());
            }
            let start = selected_line
                .saturating_sub((area.height as usize / 3).max(1))
                .min(all_lines.len());
            let end = (start + area.height as usize).min(all_lines.len());
            lines.extend(all_lines[start..end].iter().cloned());
            if !thread.thread.is_complete && lines.len() + 2 < area.height as usize {
                lines.push(Line::from(Span::styled(
                    format!(
                        "partial thread · loaded {} items",
                        thread.thread.loaded_item_count
                    ),
                    muted(),
                )));
            }
        }
    }
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), area);
}

fn draw_footer(frame: &mut Frame, app: &App, area: Rect) {
    let (mode, hints) = match &app.overlay {
        Some(Overlay::Help) => ("HELP", "esc close"),
        Some(Overlay::Commands { .. }) => ("COMMAND", "type · ↑↓ · enter · esc"),
        Some(Overlay::Search { .. }) => ("SEARCH", "enter search · esc"),
        Some(Overlay::Login { .. }) => ("LOGIN", "tab switch · enter log in · esc"),
        Some(Overlay::Confirm { .. }) => ("CONFIRM", "y confirm · n cancel"),
        Some(Overlay::Compose(_)) => ("COMPOSE", "ctrl-s post · esc save draft"),
        Some(Overlay::Submit(_)) => ("SUBMIT", "tab field · ctrl-s post · esc save draft"),
        None => match app.focus {
            Focus::Sidebar => ("FEEDS", "j/k feed · enter open · tab next"),
            Focus::Detail => (
                "THREAD",
                "j/k comments · space collapse · c reply · esc back",
            ),
            Focus::List => (
                "BROWSE",
                "j/k move · enter open · / search · : commands · ? help · q quit",
            ),
        },
    };
    let mut spans = vec![
        Span::styled(
            format!(" {mode} "),
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!(" {hints}"), muted()),
    ];
    let status = if let Some(toast) = &app.toast {
        toast.message.clone()
    } else if let Some(user) = &app.user {
        format!("● {}", user.user_id)
    } else {
        "○ not logged in".into()
    };
    let width = area.width as usize;
    let used = display_width(mode) + display_width(hints) + 4;
    let status_width = display_width(&status);
    if used + status_width + 1 < width {
        spans.push(Span::styled(
            " ".repeat(width - used - status_width - 1),
            Style::default(),
        ));
        spans.push(Span::styled(
            status,
            app.toast
                .as_ref()
                .map(|toast| Style::default().fg(toast.color))
                .unwrap_or(muted()),
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn draw_overlay(frame: &mut Frame, app: &mut App, body: Rect) {
    let Some(overlay) = app.overlay.clone() else {
        return;
    };
    frame.render_widget(Clear, body);
    let width = body.width.min(100);
    let height = body.height.min(30);
    let rect = centered(body, width, height);
    match &overlay {
        Overlay::Help => {
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(muted())
                .title(Span::styled(" Keyboard ", Style::default().fg(ACCENT)));
            let inner = block.inner(rect);
            frame.render_widget(block, rect);
            let entries = [
                ("j / k, ↑ / ↓", "move"),
                ("g / G", "top / bottom"),
                ("enter / l", "open"),
                ("tab", "next pane"),
                ("esc / h", "back"),
                ("space", "collapse comment"),
                ("/", "search"),
                (":", "commands"),
                ("r", "refresh"),
                ("o / y", "open / copy URL"),
                ("v / V / u", "upvote / downvote / unvote"),
                ("f / F", "favorite / unfavorite"),
                ("H / U", "hide / unhide"),
                ("!", "flag"),
                ("c / e / d", "comment / edit / delete"),
                ("s", "submit a story"),
                ("L", "log in"),
                ("?", "this help"),
                ("q / ctrl-c", "quit"),
            ];
            let mut lines = Vec::new();
            for (index, (key, action)) in entries.iter().enumerate() {
                let _ = index;
                lines.push(Line::from(vec![
                    Span::styled(*key, Style::default().fg(ACCENT)),
                    Span::styled(format!("  {action}"), muted()),
                ]));
            }
            frame.render_widget(Paragraph::new(lines), inner);
        }
        Overlay::Commands { .. } => {
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(muted())
                .title(Span::styled(" Commands ", Style::default().fg(ACCENT)));
            let inner = block.inner(rect);
            frame.render_widget(block, rect);
            let mut lines = Vec::new();
            let query = if let Some(Overlay::Commands { query, .. }) = &app.overlay {
                query.clone()
            } else {
                String::new()
            };
            lines.push(Line::from(vec![
                Span::styled("› ", Style::default().fg(ACCENT)),
                Span::styled(query, Style::default()),
            ]));
            lines.push(Line::from(Span::styled(
                "─".repeat(inner.width as usize),
                muted(),
            )));
            let commands = app.filtered_commands();
            let selected = if let Some(Overlay::Commands { selected, .. }) = &app.overlay {
                *selected
            } else {
                0
            };
            for (index, (title, _)) in commands.iter().enumerate() {
                let style = if index == selected {
                    Style::default().add_modifier(Modifier::REVERSED)
                } else {
                    Style::default()
                };
                lines.push(Line::from(Span::styled(title.clone(), style)));
            }
            frame.render_widget(Paragraph::new(lines), inner);
        }
        Overlay::Search { query } => {
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(muted())
                .title(Span::styled(" Search ", Style::default().fg(ACCENT)));
            let inner = block.inner(rect);
            frame.render_widget(block, rect);
            frame.render_widget(
                Paragraph::new(vec![
                    Line::from(vec![
                        Span::styled("/ ", Style::default().fg(ACCENT)),
                        Span::styled(query.clone(), Style::default()),
                    ]),
                    Line::default(),
                    Line::from(Span::styled("enter search · esc cancel", muted())),
                ]),
                inner,
            );
        }
        Overlay::Login {
            username,
            password,
            field,
            error,
            submitting,
        } => {
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(muted())
                .title(Span::styled(" Log in ", Style::default().fg(ACCENT)));
            let inner = block.inner(rect);
            frame.render_widget(block, rect);
            let mut lines = vec![
                Line::from(vec![
                    Span::styled("user  ", Style::default().fg(ACCENT)),
                    Span::styled(
                        username.clone(),
                        if *field == 0 {
                            Style::default()
                        } else {
                            muted()
                        },
                    ),
                ]),
                Line::from(vec![
                    Span::styled("pass  ", Style::default().fg(ACCENT)),
                    Span::styled(
                        "•".repeat(password.chars().count()),
                        if *field == 1 {
                            Style::default()
                        } else {
                            muted()
                        },
                    ),
                ]),
            ];
            if let Some(error) = error {
                lines.push(Line::from(Span::styled(
                    error.clone(),
                    Style::default().fg(ERROR),
                )));
            } else if *submitting {
                lines.push(Line::from(Span::styled("logging in…", muted())));
            }
            lines.push(Line::default());
            lines.push(Line::from(Span::styled(
                "tab switch · enter log in · esc cancel",
                muted(),
            )));
            frame.render_widget(Paragraph::new(lines), inner);
        }
        Overlay::Confirm { message, .. } => {
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(muted())
                .title(Span::styled(" Confirm ", Style::default().fg(ACCENT)));
            let inner = block.inner(rect);
            frame.render_widget(block, rect);
            frame.render_widget(
                Paragraph::new(vec![
                    Line::from(Span::styled(message.clone(), Style::default())),
                    Line::default(),
                    Line::from(Span::styled("y confirm · n cancel", muted())),
                ]),
                inner,
            );
        }
        Overlay::Compose(compose) => {
            draw_compose(frame, app, compose, rect);
        }
        Overlay::Submit(form) => {
            draw_submit(frame, app, form, rect);
        }
    }
}

fn single_line_field(
    label: &str,
    editor: &Editor,
    focused: bool,
    width: usize,
    placeholder: &str,
) -> Line<'static> {
    let label_style = if focused {
        Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)
    } else {
        muted()
    };
    let mut spans = vec![Span::styled(format!("{label:<8}"), label_style)];
    if editor.text.is_empty() && !focused {
        spans.push(Span::styled(placeholder.to_string(), muted()));
        return Line::from(spans);
    }
    let chars = editor.chars();
    let cursor = editor.cursor.min(chars.len());
    let width = width.max(1);
    let start = if focused {
        cursor.saturating_sub(width.saturating_sub(1))
    } else {
        0
    };
    let mut used = 0usize;
    let mut index = start;
    while index < chars.len() && used < width {
        let character = chars[index];
        let character_width = unicode_width::UnicodeWidthChar::width(character).unwrap_or(1);
        if used + character_width > width {
            break;
        }
        let style = if focused && index == cursor {
            Style::default().add_modifier(Modifier::REVERSED)
        } else {
            Style::default()
        };
        spans.push(Span::styled(character.to_string(), style));
        used += character_width;
        index += 1;
    }
    if focused && cursor >= chars.len() {
        spans.push(Span::styled(
            " ",
            Style::default().add_modifier(Modifier::REVERSED),
        ));
    }
    Line::from(spans)
}

fn draw_submit(frame: &mut Frame, app: &mut App, form: &SubmitState, rect: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(muted())
        .title(Span::styled(
            " New story ",
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    if inner.height < 4 || inner.width < 16 {
        return;
    }

    let field_width = inner.width.saturating_sub(8) as usize;
    let mut lines = Vec::new();
    lines.push(single_line_field(
        "Title",
        &form.title,
        form.focus == SubmitField::Title,
        field_width,
        "A clear, descriptive title",
    ));
    lines.push(single_line_field(
        "Link",
        &form.url,
        form.focus == SubmitField::Url,
        field_width,
        "https://example.com (optional)",
    ));
    lines.push(Line::from(Span::styled(
        "        Link posts use the link. Text posts leave it empty.",
        muted(),
    )));
    lines.push(Line::from(Span::styled(
        "─".repeat(inner.width as usize),
        muted(),
    )));
    lines.push(Line::from(vec![
        Span::styled(
            "Text    ",
            if form.focus == SubmitField::Text {
                Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)
            } else {
                muted()
            },
        ),
        Span::styled("description or context (optional)", muted()),
    ]));

    let body_height = (inner.height as usize)
        .saturating_sub(lines.len() + 2)
        .max(1);
    let layout = compose_layout(&form.text.text, inner.width as usize, form.text.cursor);
    let mut scroll = form.scroll.min(layout.lines.len().saturating_sub(1));
    if form.focus == SubmitField::Text {
        if layout.cursor_line < scroll {
            scroll = layout.cursor_line;
        } else if layout.cursor_line >= scroll + body_height {
            scroll = layout.cursor_line - body_height + 1;
        }
    }
    if let Some(Overlay::Submit(current)) = &mut app.overlay {
        current.scroll = scroll;
    }
    let chars = form.text.chars();
    if form.text.text.is_empty() && form.focus != SubmitField::Text {
        lines.push(Line::from(Span::styled(
            "        Write a description or context (optional)",
            muted(),
        )));
    } else {
        for (offset, (start, end, text)) in layout
            .lines
            .iter()
            .enumerate()
            .skip(scroll)
            .take(body_height)
        {
            let focused_line = form.focus == SubmitField::Text && offset == layout.cursor_line;
            if focused_line {
                let cursor = form.text.cursor.min(chars.len());
                let local_start = cursor.saturating_sub(*start).min(end - start);
                let prefix: String = chars[*start..*start + local_start].iter().collect();
                let mut spans = vec![
                    Span::styled("        ", Style::default()),
                    Span::styled(prefix, Style::default()),
                ];
                if cursor < chars.len() && chars[cursor] != '\n' {
                    spans.push(Span::styled(
                        chars[cursor].to_string(),
                        Style::default().add_modifier(Modifier::REVERSED),
                    ));
                    let rest: String = chars[cursor + 1..*end].iter().collect();
                    spans.push(Span::styled(rest, Style::default()));
                } else {
                    spans.push(Span::styled(
                        " ",
                        Style::default().add_modifier(Modifier::REVERSED),
                    ));
                }
                lines.push(Line::from(spans));
            } else {
                lines.push(Line::from(vec![
                    Span::styled("        ", Style::default()),
                    Span::styled(text.clone(), Style::default()),
                ]));
            }
        }
    }

    if form.submitting {
        lines.push(Line::from(Span::styled(
            format!("{} submitting…", SPINNER[app.spinner]),
            Style::default().fg(ACCENT),
        )));
    } else if let Some(error) = &form.error {
        lines.push(Line::from(Span::styled(
            error.clone(),
            Style::default().fg(ERROR),
        )));
    } else {
        let link = if form.url.trimmed().is_empty() {
            "Link empty · text post"
        } else {
            "Link set"
        };
        lines.push(Line::from(Span::styled(
            format!(
                "Title {}/80 · {} · Text {} chars",
                form.title.text.chars().count(),
                link,
                form.text.text.chars().count()
            ),
            muted(),
        )));
    }
    if form.restored {
        lines.push(Line::from(Span::styled(
            "Draft restored · tab next field · ctrl-s submit · esc save draft",
            Style::default().fg(WARNING),
        )));
    } else {
        lines.push(Line::from(Span::styled(
            "tab next field · ctrl-s submit · esc save draft",
            muted(),
        )));
    }
    frame.render_widget(Paragraph::new(lines), inner);
}

fn draw_compose(frame: &mut Frame, app: &mut App, compose: &ComposeState, rect: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(muted())
        .title(Span::styled(
            format!(" {} ", compose.kind.title()),
            Style::default().fg(ACCENT),
        ));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let mut lines = Vec::new();
    let mut context = vec![Span::styled(
        format!("{} ", compose.context.label),
        Style::default().fg(ACCENT),
    )];
    if let Some(author) = &compose.context.author {
        context.push(Span::styled(author.0.clone(), Style::default().fg(LINK)));
    }
    if let Some(title) = &compose.context.story_title {
        context.push(Span::styled(format!(" · {title}"), muted()));
    }
    lines.push(Line::from(context));
    if let Some(excerpt) = &compose.context.excerpt {
        let excerpt = excerpt.replace('\n', " ");
        if !excerpt.is_empty() {
            lines.push(Line::from(Span::styled(
                truncate(&format!("> {excerpt}"), inner.width as usize),
                muted(),
            )));
        }
    }
    if compose.restored {
        lines.push(Line::from(Span::styled(
            "draft restored",
            Style::default().fg(WARNING),
        )));
    }
    lines.push(Line::from(Span::styled(
        "─".repeat(inner.width as usize),
        muted(),
    )));

    let status_y = inner.height.saturating_sub(2) as usize;
    let text_height = status_y.saturating_sub(lines.len()).max(1);
    let layout = compose_layout(
        &compose.editor.text,
        inner.width as usize,
        compose.editor.cursor,
    );
    let mut scroll = compose.scroll.min(layout.lines.len().saturating_sub(1));
    if layout.cursor_line < scroll {
        scroll = layout.cursor_line;
    } else if layout.cursor_line >= scroll + text_height {
        scroll = layout.cursor_line - text_height + 1;
    }
    if let Some(Overlay::Compose(current)) = &mut app.overlay {
        current.scroll = scroll;
    }
    let chars = compose.editor.chars();
    for (offset, (start, end, text)) in layout
        .lines
        .iter()
        .enumerate()
        .skip(scroll)
        .take(text_height)
    {
        let _ = (start, end);
        let mut spans = Vec::new();
        if offset == layout.cursor_line {
            let cursor = compose.editor.cursor.min(chars.len());
            let line_start = *start;
            let line_end = *end;
            let local_start = cursor.saturating_sub(line_start).min(line_end - line_start);
            let prefix: String = chars[line_start..line_start + local_start].iter().collect();
            spans.push(Span::styled(prefix, Style::default()));
            if cursor < chars.len() && chars[cursor] != '\n' {
                spans.push(Span::styled(
                    chars[cursor].to_string(),
                    Style::default().add_modifier(Modifier::REVERSED),
                ));
                let rest: String = chars[cursor + 1..line_end].iter().collect();
                spans.push(Span::styled(rest, Style::default()));
            } else {
                spans.push(Span::styled(
                    " ",
                    Style::default().add_modifier(Modifier::REVERSED),
                ));
            }
        } else {
            spans.push(Span::styled(text.clone(), Style::default()));
        }
        lines.push(Line::from(spans));
    }
    while lines.len() < status_y {
        lines.push(Line::default());
    }
    if compose.submitting {
        lines.push(Line::from(Span::styled(
            format!("{} posting…", SPINNER[app.spinner]),
            Style::default().fg(ACCENT),
        )));
    } else if let Some(error) = &compose.error {
        lines.push(Line::from(Span::styled(
            error.clone(),
            Style::default().fg(ERROR),
        )));
    } else {
        lines.push(Line::from(Span::styled(
            format!("{} chars", compose.editor.text.chars().count()),
            muted(),
        )));
    }
    lines.push(Line::from(Span::styled(
        format!("ctrl-s {} · esc save draft", compose.kind.submit_label()),
        muted(),
    )));
    frame.render_widget(Paragraph::new(lines), inner);
}

fn entry_lines(entry: &TuiEntry, rank: usize, width: u16) -> (String, String) {
    let width = width.saturating_sub(2) as usize;
    match entry.kind {
        ItemKind::Comment => {
            let author = entry
                .author
                .as_ref()
                .map(|a| a.0.as_str())
                .unwrap_or("[deleted]");
            let title = truncate(
                &format!("{rank}. {author} · {}", relative_time(entry.created_at)),
                width,
            );
            let mut meta = String::new();
            if entry.is_dead {
                meta.push_str("[dead] · ");
            }
            if let Some(story) = &entry.story_title {
                meta.push_str(&format!("on {story} · "));
            }
            if let Some(text) = &entry.text {
                meta.push_str(&text.replace('\n', " "));
            }
            (title, truncate(&meta, width))
        }
        _ => {
            let title = truncate(&format!("{rank}. {}", entry.display_title()), width);
            let mut parts = Vec::new();
            if let Some(domain) = entry.domain() {
                parts.push(domain);
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
            (title, truncate(&parts.join(" · "), width))
        }
    }
}

fn entry_preview_lines(entry: &TuiEntry, width: u16) -> Vec<Line<'static>> {
    let width = width.saturating_sub(2) as usize;
    let mut lines = vec![Line::from(Span::styled(
        truncate(&entry.display_title(), width),
        Style::default().add_modifier(Modifier::BOLD),
    ))];
    if let Some(url) = &entry.url {
        lines.push(Line::from(Span::styled(
            truncate(url, width),
            Style::default().fg(LINK),
        )));
    }
    let mut parts = Vec::new();
    if entry.is_dead {
        parts.push("dead".into());
    }
    if let Some(domain) = entry.domain() {
        parts.push(domain);
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
    parts.push(format!("id {}", entry.id));
    lines.push(Line::from(Span::styled(
        truncate(&parts.join(" · "), width),
        muted(),
    )));
    if let Some(text) = &entry.text {
        let text = text.trim();
        if !text.is_empty() {
            lines.push(Line::default());
            for line in text.lines() {
                lines.push(Line::from(Span::raw(line.to_string())));
            }
        }
    }
    lines.push(Line::default());
    lines.push(Line::from(Span::styled(
        "enter open comments · o open link · y copy · c reply",
        muted(),
    )));
    lines
}

fn centered(area: Rect, width: u16, height: u16) -> Rect {
    let width = width.max(10).min(area.width);
    let height = height.max(5).min(area.height);
    Rect::new(
        area.x + (area.width.saturating_sub(width)) / 2,
        area.y + (area.height.saturating_sub(height)) / 2,
        width,
        height,
    )
}

fn muted() -> Style {
    Style::default().add_modifier(Modifier::DIM)
}

fn display_width(value: &str) -> usize {
    unicode_width::UnicodeWidthStr::width(value)
}

fn truncate(value: &str, width: usize) -> String {
    if display_width(value) <= width {
        return value.to_string();
    }
    let mut result = String::new();
    let mut used = 0;
    for character in value.chars() {
        let character_width = unicode_width::UnicodeWidthChar::width(character).unwrap_or(0);
        if used + character_width + 1 > width {
            break;
        }
        result.push(character);
        used += character_width;
    }
    result.push('…');
    result
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

#[derive(Debug)]
struct ComposeLayout {
    lines: Vec<(usize, usize, String)>,
    cursor_line: usize,
}

fn compose_layout(text: &str, width: usize, cursor: usize) -> ComposeLayout {
    let width = width.max(8);
    let chars: Vec<char> = text.chars().collect();
    let mut lines = Vec::new();
    let mut line_start = 0;
    let mut current = String::new();
    let mut current_width = 0;
    for (index, character) in chars.iter().enumerate() {
        if *character == '\n' {
            lines.push((line_start, index, current.clone()));
            current.clear();
            current_width = 0;
            line_start = index + 1;
            continue;
        }
        let character_width = unicode_width::UnicodeWidthChar::width(*character).unwrap_or(1);
        if current_width + character_width > width && !current.is_empty() {
            lines.push((line_start, index, current.clone()));
            current.clear();
            current_width = 0;
            line_start = index;
        }
        current.push(*character);
        current_width += character_width;
    }
    lines.push((line_start, chars.len(), current));
    let cursor = cursor.min(chars.len());
    let mut cursor_line = lines.len().saturating_sub(1);
    for (index, (start, end, _)) in lines.iter().enumerate() {
        if cursor >= *start && cursor <= *end {
            cursor_line = index;
            break;
        }
    }
    ComposeLayout { lines, cursor_line }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compose_layout_tracks_the_cursor_line() {
        let text = "first line\nsecond line\nthird line";
        assert_eq!(compose_layout(text, 80, 2).cursor_line, 0);
        assert_eq!(
            compose_layout(text, 80, text.chars().count()).cursor_line,
            2
        );
    }

    #[test]
    fn compose_layout_wraps_long_lines() {
        let layout = compose_layout("abcdefghij", 4, 0);
        assert!(layout.lines.len() > 1);
        assert_eq!(layout.cursor_line, 0);
    }

    #[test]
    fn editor_edits_at_the_cursor() {
        let mut editor = Editor::new("abc".into());
        editor.insert("d");
        assert_eq!(editor.text, "abcd");
        editor.move_left();
        editor.insert("X");
        assert_eq!(editor.text, "abcXd");
        editor.backspace();
        assert_eq!(editor.text, "abcd");
        editor.delete_forward();
        assert_eq!(editor.text, "abc");
    }

    #[test]
    fn single_line_editor_replaces_newlines() {
        let mut editor = Editor::default();
        editor.insert_single_line("a\nb\tc");
        assert_eq!(editor.text, "a b    c");
    }

    #[test]
    fn submit_form_cycles_fields_and_tracks_content() {
        let mut form = SubmitState::new();
        assert!(!form.has_content());
        form.next_field(1);
        assert_eq!(form.focus, SubmitField::Url);
        form.next_field(-1);
        assert_eq!(form.focus, SubmitField::Title);
        form.title.insert("hello");
        assert!(form.has_content());
    }
}
