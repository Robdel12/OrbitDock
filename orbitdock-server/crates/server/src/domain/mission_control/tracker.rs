use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A reference to an issue that blocks another issue.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockerRef {
    pub id: String,
    pub identifier: String,
}

/// Normalized issue from any tracker.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct TrackerIssue {
    pub id: String,
    pub identifier: String,
    pub title: String,
    pub description: Option<String>,
    pub priority: Option<i32>,
    pub state: String,
    pub url: Option<String>,
    pub labels: Vec<String>,
    pub blocked_by: Vec<BlockerRef>,
    pub created_at: Option<String>,
}

/// Configuration needed to query a tracker for candidate issues.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct TrackerConfig {
    pub project_key: Option<String>,
    pub team_key: Option<String>,
    pub label_filter: Vec<String>,
    pub state_filter: Vec<String>,
}

/// Pluggable issue tracker interface.
#[async_trait]
pub trait Tracker: Send + Sync {
    /// Fetch issues eligible for orchestration.
    async fn fetch_candidates(&self, config: &TrackerConfig) -> anyhow::Result<Vec<TrackerIssue>>;

    /// Fetch current tracker states for a batch of issue IDs.
    async fn fetch_issue_states(
        &self,
        issue_ids: &[String],
    ) -> anyhow::Result<HashMap<String, String>>;

    /// Returns the tracker kind string (e.g. "linear", "github").
    #[allow(dead_code)]
    fn kind(&self) -> &str;

    /// Post a comment on an issue. No-op for trackers without write support.
    async fn create_comment(&self, _issue_id: &str, _body: &str) -> anyhow::Result<()> {
        Ok(())
    }

    /// Move an issue to a named workflow state (e.g. "In Progress", "Done").
    /// The implementation resolves human-readable names to internal IDs.
    /// No-op for trackers without write support.
    async fn update_issue_state(&self, _issue_id: &str, _state_name: &str) -> anyhow::Result<()> {
        Ok(())
    }
}
