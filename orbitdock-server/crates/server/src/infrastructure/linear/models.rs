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
