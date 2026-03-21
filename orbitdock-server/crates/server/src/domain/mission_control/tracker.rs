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

/// Tracker-agnostic comment returned by mission tool operations.
#[derive(Debug, Clone, Serialize)]
pub struct TrackerComment {
    pub id: String,
    pub body: String,
    pub created_at: Option<String>,
    pub author: Option<String>,
}

/// Tracker-agnostic result of creating a new issue.
#[derive(Debug, Clone, Serialize)]
pub struct TrackerCreatedIssue {
    pub id: String,
    pub identifier: String,
    pub url: String,
}

/// Configuration needed to query a tracker for candidate issues.
///
/// Field semantics vary by tracker:
/// - **Linear**: `project_key` = project slug ID, `team_key` = team key (e.g. "VIZ")
/// - **GitHub**: `project_key` = project number (e.g. "1"), `team_key` = `owner/repo`
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct TrackerConfig {
    pub project_key: Option<String>,
    pub team_key: Option<String>,
    pub label_filter: Vec<String>,
    pub state_filter: Vec<String>,
}

/// Pluggable issue tracker interface.
///
/// Core methods (`fetch_candidates`, `fetch_issue_states`, `kind`) must be implemented.
/// Extended methods used by the mission tool executor have default no-op implementations
/// so trackers can incrementally add write support.
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
    fn kind(&self) -> &str;

    /// Post a comment on an issue.
    async fn create_comment(&self, _issue_id: &str, _body: &str) -> anyhow::Result<()> {
        Ok(())
    }

    /// Move an issue to a named workflow state (e.g. "In Progress", "Done").
    /// The implementation resolves human-readable names to internal IDs.
    async fn update_issue_state(&self, _issue_id: &str, _state_name: &str) -> anyhow::Result<()> {
        Ok(())
    }

    /// Fetch a single issue by its human-readable identifier (e.g. "VIZ-240" or "owner/repo#42").
    async fn fetch_issue_by_identifier(
        &self,
        _identifier: &str,
    ) -> anyhow::Result<Option<TrackerIssue>> {
        anyhow::bail!("fetch_issue_by_identifier not supported by this tracker")
    }

    /// List comments on an issue.
    async fn list_comments(
        &self,
        _issue_id: &str,
        _first: u32,
    ) -> anyhow::Result<Vec<TrackerComment>> {
        anyhow::bail!("list_comments not supported by this tracker")
    }

    /// Update an existing comment body.
    async fn update_comment(&self, _comment_id: &str, _body: &str) -> anyhow::Result<()> {
        anyhow::bail!("update_comment not supported by this tracker")
    }

    /// Create a new issue as a follow-up to the given parent issue.
    /// The implementation resolves project/team context from the parent.
    async fn create_issue(
        &self,
        _parent_id: &str,
        _title: &str,
        _description: &str,
    ) -> anyhow::Result<TrackerCreatedIssue> {
        anyhow::bail!("create_issue not supported by this tracker")
    }

    /// Attach a URL (e.g. PR link) to an issue.
    /// Linear creates an attachment; GitHub posts a comment with the link.
    async fn link_url(&self, _issue_id: &str, _url: &str, _title: &str) -> anyhow::Result<()> {
        anyhow::bail!("link_url not supported by this tracker")
    }
}
