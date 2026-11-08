use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use futures::future::join_all;

use crate::algolia::AlgoliaClient;
use crate::domain::*;
use crate::error::{HnError, Result};
use crate::firebase::FirebaseClient;
use crate::http::{HttpTransport, ReqwestTransport};
use crate::site::{LoginCredentials, SiteClient, SiteFeedPage, UserSession};

pub struct HackerNews {
    pub firebase: FirebaseClient,
    pub algolia: AlgoliaClient,
    pub site: SiteClient,
}

impl HackerNews {
    pub fn new() -> Result<Self> {
        let transport: Arc<dyn HttpTransport> = Arc::new(ReqwestTransport::new()?);
        Self::with_transport(transport)
    }

    pub fn with_transport(transport: Arc<dyn HttpTransport>) -> Result<Self> {
        Ok(Self {
            firebase: FirebaseClient::new(transport.clone())?,
            algolia: AlgoliaClient::new(transport.clone())?,
            site: SiteClient::new(transport)?,
        })
    }

    pub async fn feed_entries(&self, feed: &Feed, page: PageRequest) -> Result<SiteFeedPage> {
        self.site.feed_entries(feed, page).await
    }

    pub async fn item(&self, id: ItemId) -> Result<Option<Item>> {
        self.firebase.item(id).await
    }

    pub async fn thread(&self, root_id: ItemId) -> Result<Thread> {
        match self.algolia.item_tree(root_id).await {
            Ok(thread) => Ok(thread),
            Err(_) => self.load_thread_firebase(root_id, 500, 16).await,
        }
    }

    pub async fn context(&self, id: ItemId, max_depth: usize) -> Result<Vec<Item>> {
        let mut chain = Vec::new();
        let mut current_id = Some(id);
        let mut seen = std::collections::HashSet::new();
        while let Some(item_id) = current_id {
            if !seen.insert(item_id) || chain.len() > max_depth {
                break;
            }
            let Some(item) = self.item(item_id).await? else {
                break;
            };
            current_id = item.parent_id();
            chain.push(item);
        }
        chain.reverse();
        Ok(chain)
    }

    pub async fn user(&self, id: &UserId) -> Result<Option<User>> {
        self.firebase.user(id).await
    }

    pub async fn search(&self, query: &SearchQuery) -> Result<SearchResults> {
        self.algolia.search(query).await
    }

    pub async fn updates(&self) -> Result<Updates> {
        self.firebase.updates().await
    }

    pub async fn max_item_id(&self) -> Result<ItemId> {
        self.firebase.max_item_id().await
    }

    pub async fn leaders(&self) -> Result<Vec<LeaderboardEntry>> {
        let entries = self.site.leaders().await?;
        let mut result = Vec::with_capacity(entries.len());
        for mut entry in entries {
            if entry.karma == 0
                && let Ok(Some(user)) = self.firebase.user(&entry.user_id).await
            {
                entry.karma = user.karma;
            }
            result.push(entry);
        }
        Ok(result)
    }

    pub async fn submissions(&self, user_id: &UserId, page: PageRequest) -> Result<ItemPage> {
        let Some(user) = self.firebase.user(user_id).await? else {
            return Err(HnError::NotFound(format!("user {user_id}")));
        };
        let ids = user.submitted_item_ids;
        self.item_page_from_ids(&ids, page).await
    }

    pub async fn activity(
        &self,
        user_id: &UserId,
        activity: UserActivityKind,
        page: PageRequest,
    ) -> Result<ItemPage> {
        if activity == UserActivityKind::Submissions {
            return self.submissions(user_id, page).await;
        }
        let site_page = self.site.activity_entries(user_id, activity, page).await?;
        let ids: Vec<ItemId> = site_page.entries.iter().map(|entry| entry.id).collect();
        let items = self.fetch_items_ordered(&ids).await?;
        Ok(ItemPage {
            items,
            offset: page.offset,
            has_more: site_page.has_more,
            total_count: site_page.total_count,
        })
    }

    pub async fn item_page_from_ids(&self, ids: &[ItemId], page: PageRequest) -> Result<ItemPage> {
        let start = (page.offset as usize).min(ids.len());
        let end = (start + page.limit as usize).min(ids.len());
        let items = self.fetch_items_ordered(&ids[start..end]).await?;
        Ok(ItemPage {
            items,
            offset: page.offset,
            has_more: end < ids.len(),
            total_count: Some(ids.len() as u64),
        })
    }

    pub async fn fetch_items_ordered(&self, ids: &[ItemId]) -> Result<Vec<Item>> {
        let mut result = Vec::new();
        for chunk in ids.chunks(16) {
            let futures = chunk.iter().map(|id| self.item(*id));
            let items = join_all(futures).await;
            for item in items {
                if let Ok(Some(item)) = item {
                    result.push(item);
                }
            }
        }
        Ok(result)
    }

    pub async fn current_session(&self) -> Option<UserSession> {
        self.site.current_session().await
    }

    pub async fn validate_session(&self) -> Result<Option<UserSession>> {
        self.site.validate_session().await
    }

    pub async fn login(&self, credentials: &LoginCredentials) -> Result<UserSession> {
        self.site.login(credentials).await
    }

    pub async fn signup(&self, credentials: &LoginCredentials) -> Result<UserSession> {
        self.site.signup(credentials).await
    }

    pub async fn logout(&self) -> Result<()> {
        self.site.logout().await
    }

    pub async fn vote(&self, id: ItemId, direction: VoteDirection) -> Result<()> {
        self.site.vote(id, direction).await
    }

    pub async fn submit_story(&self, submission: &StorySubmission) -> Result<Option<ItemId>> {
        self.site.submit_story(submission).await
    }

    pub async fn submit_comment(&self, submission: &CommentSubmission) -> Result<Option<ItemId>> {
        self.site.submit_comment(submission).await
    }

    pub async fn edit_item(&self, id: ItemId, text: &str) -> Result<()> {
        self.site.edit_item(id, text).await
    }

    pub async fn delete_item(&self, id: ItemId) -> Result<()> {
        self.site.delete_item(id).await
    }

    pub async fn set_favorite(&self, id: ItemId, favorite: bool) -> Result<()> {
        self.site.set_favorite(id, favorite).await
    }

    pub async fn set_hidden(&self, id: ItemId, hidden: bool) -> Result<()> {
        self.site.set_hidden(id, hidden).await
    }

    pub async fn flag(&self, id: ItemId, reason: &str) -> Result<()> {
        self.site.flag(id, reason).await
    }

    pub async fn unflag(&self, id: ItemId) -> Result<()> {
        self.site.unflag(id).await
    }

    async fn load_thread_firebase(
        &self,
        root_id: ItemId,
        max_nodes: usize,
        concurrency: usize,
    ) -> Result<Thread> {
        let Some(root) = self.item(root_id).await? else {
            return Err(HnError::NotFound(format!("item {root_id}")));
        };
        let mut items: HashMap<ItemId, Item> = HashMap::new();
        items.insert(root.id, root.clone());
        let mut children: HashMap<ItemId, Vec<ItemId>> = HashMap::new();
        let mut queue = VecDeque::new();
        queue.push_back(root.id);
        let mut missing = 0usize;

        while let Some(parent_id) = queue.pop_front() {
            let Some(parent) = items.get(&parent_id).cloned() else {
                continue;
            };
            let child_ids = parent.child_ids().to_vec();
            if child_ids.is_empty() {
                continue;
            }
            let mut loaded_children = Vec::new();
            for chunk in child_ids.chunks(concurrency.max(1)) {
                let futures = chunk.iter().map(|id| self.item(*id));
                let fetched = join_all(futures).await;
                for (requested_id, item) in chunk.iter().zip(fetched) {
                    match item {
                        Ok(Some(item)) => {
                            if items.len() < max_nodes && !items.contains_key(&item.id) {
                                items.insert(item.id, item.clone());
                                queue.push_back(item.id);
                                loaded_children.push(item.id);
                            }
                        }
                        _ => missing += 1,
                    }
                    let _ = requested_id;
                }
            }
            children.insert(parent_id, loaded_children);
        }

        fn build(
            id: ItemId,
            items: &HashMap<ItemId, Item>,
            children: &HashMap<ItemId, Vec<ItemId>>,
        ) -> Option<ThreadNode> {
            let item = items.get(&id)?.clone();
            let replies = children
                .get(&id)
                .into_iter()
                .flatten()
                .filter_map(|child| build(*child, items, children))
                .collect();
            Some(ThreadNode { item, replies })
        }

        let replies = children
            .get(&root_id)
            .into_iter()
            .flatten()
            .filter_map(|child| build(*child, &items, &children))
            .collect();
        let loaded = items.len();
        let truncated = loaded >= max_nodes;
        Ok(Thread {
            root,
            replies,
            loaded_item_count: loaded,
            missing_item_count: missing,
            is_complete: missing == 0 && !truncated,
        })
    }
}
