use serde::Deserialize;

use crate::domain::mission_control::tracker::TrackerIssue;

// ── GraphQL response wrappers ───────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct GraphQLResponse<T> {
    pub data: Option<T>,
    pub errors: Option<Vec<GraphQLError>>,
}

#[derive(Debug, Deserialize)]
pub struct GraphQLError {
    pub message: String,
}

// ── Project items query ─────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct UserProjectData {
    pub user: Option<ProjectOwner>,
    pub organization: Option<ProjectOwner>,
}

#[derive(Debug, Deserialize)]
pub struct ProjectOwner {
    #[serde(rename = "projectV2")]
    pub project_v2: Option<ProjectV2>,
}

#[derive(Debug, Deserialize)]
pub struct ProjectV2 {
    pub items: ProjectItemConnection,
}

#[derive(Debug, Deserialize)]
pub struct ProjectItemConnection {
    pub nodes: Vec<ProjectItem>,
    #[serde(rename = "pageInfo")]
    pub page_info: PageInfo,
}

#[derive(Debug, Deserialize)]
pub struct PageInfo {
    #[serde(rename = "hasNextPage")]
    pub has_next_page: bool,
    #[serde(rename = "endCursor")]
    pub end_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ProjectItem {
    #[serde(rename = "fieldValueByName")]
    pub field_value_by_name: Option<StatusFieldValue>,
    pub content: Option<ProjectItemContent>,
}

#[derive(Debug, Deserialize)]
pub struct StatusFieldValue {
    pub name: Option<String>,
}

/// Tagged union for project item content. GitHub Projects v2 items can be
/// Issues, Pull Requests, or Draft Issues. We only process Issues but serde
/// needs all three variants to parse the `__typename` discriminator.
#[derive(Debug, Deserialize)]
#[serde(tag = "__typename")]
pub enum ProjectItemContent {
    Issue(Box<GitHubIssueNode>),
    PullRequest(GitHubPRNode),
    DraftIssue(DraftIssueNode),
}

#[derive(Debug, Deserialize)]
pub struct GitHubIssueNode {
    pub id: String,
    pub number: u64,
    pub title: String,
    pub body: Option<String>,
    pub url: String,
    #[serde(rename = "createdAt")]
    pub created_at: Option<String>,
    pub state: String,
    pub labels: LabelConnection,
    pub repository: RepositoryRef,
}

/// Placeholder for PR items in project queries — we skip these during processing.
#[derive(Debug, Deserialize)]
pub struct GitHubPRNode {}

/// Placeholder for draft issue items in project queries — we skip these during processing.
#[derive(Debug, Deserialize)]
pub struct DraftIssueNode {}

#[derive(Debug, Deserialize)]
pub struct LabelConnection {
    pub nodes: Vec<GitHubLabel>,
}

#[derive(Debug, Deserialize)]
pub struct GitHubLabel {
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct RepositoryRef {
    pub name: String,
    pub owner: RepositoryOwner,
}

#[derive(Debug, Deserialize)]
pub struct RepositoryOwner {
    pub login: String,
}

// ── Single issue lookup ─────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct RepositoryIssueData {
    pub repository: Option<RepositoryWithIssue>,
}

#[derive(Debug, Deserialize)]
pub struct RepositoryWithIssue {
    pub issue: Option<GitHubIssueNode>,
}

// ── Issue states batch query ────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct IssueStateNode {
    pub id: String,
    pub state: String,
}

// ── Comments ────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct IssueCommentsData {
    pub node: Option<IssueWithComments>,
}

#[derive(Debug, Deserialize)]
pub struct IssueWithComments {
    pub comments: CommentConnection,
}

#[derive(Debug, Deserialize)]
pub struct CommentConnection {
    pub nodes: Vec<GitHubComment>,
}

#[derive(Debug, Deserialize)]
pub struct GitHubComment {
    pub id: String,
    pub body: String,
    #[serde(rename = "createdAt")]
    pub created_at: Option<String>,
    pub author: Option<GitHubActor>,
}

#[derive(Debug, Deserialize)]
pub struct GitHubActor {
    pub login: String,
}

// ── Issue creation ──────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct CreateIssueData {
    #[serde(rename = "createIssue")]
    pub create_issue: Option<CreateIssuePayload>,
}

#[derive(Debug, Deserialize)]
pub struct CreateIssuePayload {
    pub issue: Option<CreatedIssueNode>,
}

#[derive(Debug, Deserialize)]
pub struct CreatedIssueNode {
    pub id: String,
    pub number: u64,
    pub url: String,
}

// ── Repository ID lookup ────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct RepositoryIdNode {
    pub id: String,
}

// ── Project Status field mutation ───────────────────────────────────

/// Response for looking up the Status field and its options on a project.
#[derive(Debug, Deserialize)]
pub struct ProjectStatusFieldData {
    pub node: Option<ProjectStatusFieldNode>,
}

#[derive(Debug, Deserialize)]
pub struct ProjectStatusFieldNode {
    pub field: Option<StatusField>,
}

#[derive(Debug, Deserialize)]
pub struct StatusField {
    pub id: String,
    pub options: Vec<StatusOption>,
}

#[derive(Debug, Deserialize)]
pub struct StatusOption {
    pub id: String,
    pub name: String,
}

/// Response for looking up a project item by issue node ID.
#[derive(Debug, Deserialize)]
pub struct ProjectItemLookupData {
    pub node: Option<ProjectItemLookupNode>,
}

#[derive(Debug, Deserialize)]
pub struct ProjectItemLookupNode {
    #[serde(rename = "projectItems")]
    pub project_items: ProjectItemIdConnection,
}

#[derive(Debug, Deserialize)]
pub struct ProjectItemIdConnection {
    pub nodes: Vec<ProjectItemIdNode>,
}

#[derive(Debug, Deserialize)]
pub struct ProjectItemIdNode {
    pub id: String,
    pub project: ProjectIdRef,
}

#[derive(Debug, Deserialize)]
pub struct ProjectIdRef {
    pub id: String,
}

/// Response for the updateProjectV2ItemFieldValue mutation.
#[derive(Debug, Deserialize)]
pub struct UpdateFieldValueData {
    #[serde(rename = "updateProjectV2ItemFieldValue")]
    pub update: Option<UpdateFieldValuePayload>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateFieldValuePayload {
    #[serde(rename = "projectV2Item")]
    pub project_v2_item: Option<UpdatedItemRef>,
}

#[derive(Debug, Deserialize)]
pub struct UpdatedItemRef {
    pub id: String,
}

impl UpdateFieldValueData {
    /// Returns the updated project item ID, if the mutation succeeded.
    pub fn updated_item_id(&self) -> Option<&str> {
        self.update
            .as_ref()
            .and_then(|u| u.project_v2_item.as_ref())
            .map(|item| item.id.as_str())
    }
}

// ── Conversions ─────────────────────────────────────────────────────

impl GitHubIssueNode {
    /// Convert a GitHub issue node into the tracker-agnostic `TrackerIssue`.
    /// `status_override` is the project Status field value (if available).
    pub fn into_tracker_issue(self, status_override: Option<String>) -> TrackerIssue {
        let owner = &self.repository.owner.login;
        let repo = &self.repository.name;
        let labels = self.labels.nodes.into_iter().map(|l| l.name).collect();
        let state = status_override.unwrap_or_else(|| self.state.clone());
        let identifier = format!("{owner}/{repo}#{}", self.number);

        TrackerIssue {
            id: self.id,
            identifier,
            title: self.title,
            description: self.body,
            priority: None,
            state,
            url: Some(self.url),
            labels,
            blocked_by: vec![],
            created_at: self.created_at,
        }
    }
}
