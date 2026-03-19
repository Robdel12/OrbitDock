use serde::Deserialize;

use crate::domain::mission_control::tracker::{BlockerRef, TrackerIssue};

#[derive(Debug, Deserialize)]
pub struct GraphQLResponse<T> {
    pub data: Option<T>,
    pub errors: Option<Vec<GraphQLError>>,
}

#[derive(Debug, Deserialize)]
pub struct GraphQLError {
    pub message: String,
}

#[derive(Debug, Deserialize)]
pub struct IssuesData {
    pub issues: IssueConnection,
}

#[derive(Debug, Deserialize)]
pub struct IssueConnection {
    pub nodes: Vec<LinearIssue>,
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
pub struct LinearIssue {
    pub id: String,
    pub identifier: String,
    pub title: String,
    pub description: Option<String>,
    pub priority: f64,
    pub url: String,
    #[serde(rename = "createdAt")]
    pub created_at: Option<String>,
    pub state: LinearState,
    pub labels: LabelConnection,
    pub relations: RelationConnection,
}

#[derive(Debug, Deserialize)]
pub struct LinearState {
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct LabelConnection {
    pub nodes: Vec<LinearLabel>,
}

#[derive(Debug, Deserialize)]
pub struct LinearLabel {
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct RelationConnection {
    pub nodes: Vec<LinearRelation>,
}

#[derive(Debug, Deserialize)]
pub struct LinearRelation {
    #[serde(rename = "type")]
    pub relation_type: String,
    #[serde(rename = "relatedIssue")]
    pub related_issue: RelatedIssue,
}

#[derive(Debug, Deserialize)]
pub struct RelatedIssue {
    pub id: String,
    pub identifier: String,
}

#[derive(Debug, Deserialize)]
pub struct IssueStatesData {
    pub issues: IssueStateConnection,
}

#[derive(Debug, Deserialize)]
pub struct IssueStateConnection {
    pub nodes: Vec<IssueStateNode>,
}

#[derive(Debug, Deserialize)]
pub struct IssueStateNode {
    pub id: String,
    pub state: LinearState,
}

// ── Mutation response models ────────────────────────────────────────

/// Response for state ID resolution query.
#[derive(Debug, Deserialize)]
pub struct ResolveStateData {
    pub issue: ResolveStateIssue,
}

#[derive(Debug, Deserialize)]
pub struct ResolveStateIssue {
    pub team: ResolveStateTeam,
}

#[derive(Debug, Deserialize)]
pub struct ResolveStateTeam {
    pub states: ResolveStateConnection,
}

#[derive(Debug, Deserialize)]
pub struct ResolveStateConnection {
    pub nodes: Vec<ResolveStateNode>,
}

#[derive(Debug, Deserialize)]
pub struct ResolveStateNode {
    pub id: String,
}

/// Generic response for mutations returning `{ success: bool }`.
#[derive(Debug, Deserialize)]
pub struct CommentCreateData {
    #[serde(rename = "commentCreate")]
    pub comment_create: SuccessPayload,
}

#[derive(Debug, Deserialize)]
pub struct IssueUpdateData {
    #[serde(rename = "issueUpdate")]
    pub issue_update: SuccessPayload,
}

#[derive(Debug, Deserialize)]
pub struct SuccessPayload {
    pub success: bool,
}

// ── Single-issue lookup (for manual dispatch) ──────────────────────

/// Response for the `issue(id:)` query which returns a single issue directly.
#[derive(Debug, Deserialize)]
pub struct DirectIssueData {
    pub issue: LinearIssue,
}

// ── Comment models ─────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct CommentsData {
    pub issue: CommentsIssue,
}

#[derive(Debug, Deserialize)]
pub struct CommentsIssue {
    pub comments: CommentConnection,
}

#[derive(Debug, Deserialize)]
pub struct CommentConnection {
    pub nodes: Vec<LinearComment>,
}

#[derive(Debug, Clone, Deserialize, serde::Serialize)]
pub struct LinearComment {
    pub id: String,
    pub body: String,
    #[serde(rename = "createdAt")]
    pub created_at: Option<String>,
    pub user: Option<LinearCommentUser>,
}

#[derive(Debug, Clone, Deserialize, serde::Serialize)]
pub struct LinearCommentUser {
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct CommentUpdateData {
    #[serde(rename = "commentUpdate")]
    pub comment_update: SuccessPayload,
}

// ── Issue creation models ──────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct IssueCreateData {
    #[serde(rename = "issueCreate")]
    pub issue_create: IssueCreatePayload,
}

#[derive(Debug, Deserialize)]
pub struct IssueCreatePayload {
    pub success: bool,
    pub issue: Option<CreatedIssue>,
}

#[derive(Debug, Clone, Deserialize, serde::Serialize)]
pub struct CreatedIssue {
    pub id: String,
    pub identifier: String,
    pub url: String,
}

// ── Attachment models ──────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct AttachmentCreateData {
    #[serde(rename = "attachmentCreate")]
    pub attachment_create: SuccessPayload,
}

// ── Team resolution ────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct IssueTeamData {
    pub issue: IssueTeamNode,
}

#[derive(Debug, Deserialize)]
pub struct IssueTeamNode {
    pub team: IssueTeamRef,
}

#[derive(Debug, Deserialize)]
pub struct IssueTeamRef {
    pub id: String,
}

// ── Existing models ────────────────────────────────────────────────

impl LinearIssue {
    pub fn into_tracker_issue(self) -> TrackerIssue {
        let labels = self.labels.nodes.into_iter().map(|l| l.name).collect();
        let blocked_by = self
            .relations
            .nodes
            .into_iter()
            .filter(|r| r.relation_type == "blocks")
            .map(|r| BlockerRef {
                id: r.related_issue.id,
                identifier: r.related_issue.identifier,
            })
            .collect();

        TrackerIssue {
            id: self.id,
            identifier: self.identifier,
            title: self.title,
            description: self.description,
            priority: Some(self.priority as i32),
            state: self.state.name,
            url: Some(self.url),
            labels,
            blocked_by,
            created_at: self.created_at,
        }
    }
}
