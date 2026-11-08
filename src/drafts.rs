use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::domain::ItemId;
use crate::error::{HnError, Result};
use crate::site::config_dir;

pub type Drafts = HashMap<String, DraftRecord>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DraftRecord {
    pub text: String,
    pub saved_at: DateTime<Utc>,
}

pub fn key_comment(parent_id: ItemId) -> String {
    format!("comment:{}", parent_id.0)
}

pub fn key_edit(item_id: ItemId) -> String {
    format!("edit:{}", item_id.0)
}

pub fn key_submit(title: &str) -> String {
    format!("submit:{title}")
}

fn drafts_path() -> std::path::PathBuf {
    config_dir().join("drafts.json")
}

pub fn load_drafts() -> Result<Drafts> {
    let path = drafts_path();
    if !path.exists() {
        return Ok(Drafts::new());
    }
    let data = std::fs::read(path).map_err(|error| HnError::Transport(error.to_string()))?;
    serde_json::from_slice(&data).map_err(|error| HnError::Decoding(error.to_string()))
}

pub fn save_drafts(drafts: &Drafts) -> Result<()> {
    let dir = config_dir();
    std::fs::create_dir_all(&dir).map_err(|error| HnError::Transport(error.to_string()))?;
    let path = drafts_path();
    if drafts.is_empty() {
        if path.exists() {
            let _ = std::fs::remove_file(path);
        }
        return Ok(());
    }
    let data =
        serde_json::to_vec_pretty(drafts).map_err(|error| HnError::Decoding(error.to_string()))?;
    std::fs::write(&path, data).map_err(|error| HnError::Transport(error.to_string()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

pub fn excerpt(value: &str, max: usize) -> String {
    let plain = value.replace('\n', " ");
    let plain = plain.trim();
    if plain.chars().count() <= max {
        return plain.to_string();
    }
    let mut result: String = plain.chars().take(max.saturating_sub(1)).collect();
    result.push('…');
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn draft_keys_are_stable() {
        assert_eq!(key_comment(ItemId(42)), "comment:42");
        assert_eq!(key_edit(ItemId(42)), "edit:42");
        assert_eq!(key_submit("Hello"), "submit:Hello");
    }

    #[test]
    fn drafts_round_trip_through_json() {
        let mut drafts = Drafts::new();
        drafts.insert(
            key_comment(ItemId(7)),
            DraftRecord {
                text: "a draft".into(),
                saved_at: chrono::Utc.timestamp_opt(100, 0).unwrap(),
            },
        );
        let data = serde_json::to_vec(&drafts).unwrap();
        let decoded: Drafts = serde_json::from_slice(&data).unwrap();
        assert_eq!(decoded[&key_comment(ItemId(7))].text, "a draft");
    }

    #[test]
    fn excerpts_are_shortened() {
        assert_eq!(excerpt("hello", 10), "hello");
        assert_eq!(excerpt("hello\nworld", 40), "hello world");
        assert_eq!(excerpt("abcdef", 4), "abc…");
    }
}
