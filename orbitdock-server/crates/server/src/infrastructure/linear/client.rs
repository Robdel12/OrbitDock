use std::collections::HashMap;

use async_trait::async_trait;
use reqwest::Client;
use tracing::debug;

use super::models::{
    AttachmentCreateData, CommentCreateData, CommentUpdateData, CommentsData, CreatedIssue,
    GraphQLResponse, IssueCreateData, IssueStatesData, IssueTeamData, IssueUpdateData, IssuesData,
    LinearComment, ResolveStateData, SingleIssueData,
};
use crate::domain::mission_control::tracker::{Tracker, TrackerConfig, TrackerIssue};

pub struct LinearClient {
    http: Client,
    api_key: String,
}

impl LinearClient {
    pub fn new(api_key: String) -> Self {
        Self {
            http: Client::new(),
            api_key,
        }
    }

    async fn graphql<T: serde::de::DeserializeOwned>(
        &self,
        query: &str,
        variables: serde_json::Value,
    ) -> anyhow::Result<T> {
        let body = serde_json::json!({
            "query": query,
            "variables": variables,
        });

        let resp = self
            .http
            .post("https://api.linear.app/graphql")
            .header("Authorization", &self.api_key)
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await?;

        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("Linear API returned {status}: {text}");
        }

        let gql: GraphQLResponse<T> = resp.json().await?;

        if let Some(errors) = gql.errors {
            let msgs: Vec<_> = errors.iter().map(|e| e.message.as_str()).collect();
            anyhow::bail!("Linear GraphQL errors: {}", msgs.join("; "));
        }

        gql.data
            .ok_or_else(|| anyhow::anyhow!("Linear response contained no data"))
    }

    async fn fetch_page(
        &self,
        config: &TrackerConfig,
        cursor: Option<&str>,
    ) -> anyhow::Result<IssuesData> {
        let mut filter_parts = Vec::new();

        if let Some(ref project) = config.project_key {
            filter_parts.push(format!(r#"project: {{ slugId: {{ eq: "{project}" }} }}"#));
        }

        if let Some(ref team) = config.team_key {
            filter_parts.push(format!(r#"team: {{ key: {{ eq: "{team}" }} }}"#));
        }

        if !config.state_filter.is_empty() {
            let states: Vec<String> = config
                .state_filter
                .iter()
                .map(|s| format!(r#""{s}""#))
                .collect();
            filter_parts.push(format!(
                r#"state: {{ name: {{ in: [{}] }} }}"#,
                states.join(", ")
            ));
        }

        if !config.label_filter.is_empty() {
            let labels: Vec<String> = config
                .label_filter
                .iter()
                .map(|l| format!(r#""{l}""#))
                .collect();
            filter_parts.push(format!(
                r#"labels: {{ name: {{ in: [{}] }} }}"#,
                labels.join(", ")
            ));
        }

        let filter = if filter_parts.is_empty() {
            "{}".to_string()
        } else {
            format!("{{ {} }}", filter_parts.join(", "))
        };

        let after = cursor
            .map(|c| format!(r#", after: "{c}""#))
            .unwrap_or_default();

        let query = format!(
            r#"query {{
                issues(first: 50, filter: {filter}{after}) {{
                    nodes {{
                        id
                        identifier
                        title
                        description
                        priority
                        url
                        createdAt
                        state {{ name }}
                        labels {{ nodes {{ name }} }}
                        relations {{ nodes {{ type relatedIssue {{ id identifier }} }} }}
                    }}
                    pageInfo {{
                        hasNextPage
                        endCursor
                    }}
                }}
            }}"#
        );

        self.graphql(&query, serde_json::json!({})).await
    }

    /// Resolve a human-readable state name to the Linear internal state ID.
    async fn resolve_state_id(&self, issue_id: &str, state_name: &str) -> anyhow::Result<String> {
        let query = r#"
            query OrbitDockResolveStateId($issueId: String!, $stateName: String!) {
                issue(id: $issueId) {
                    team {
                        states(filter: {name: {eq: $stateName}}, first: 1) {
                            nodes { id }
                        }
                    }
                }
            }
        "#;

        let data: ResolveStateData = self
            .graphql(
                query,
                serde_json::json!({ "issueId": issue_id, "stateName": state_name }),
            )
            .await?;

        data.issue
            .team
            .states
            .nodes
            .into_iter()
            .next()
            .map(|n| n.id)
            .ok_or_else(|| {
                anyhow::anyhow!("Linear state '{state_name}' not found for issue {issue_id}")
            })
    }

    // ── Mission tool methods ───────────────────────────────────────────

    /// List comments on an issue.
    pub async fn list_comments(
        &self,
        issue_id: &str,
        first: u32,
    ) -> anyhow::Result<Vec<LinearComment>> {
        let query = r#"
            query OrbitDockListComments($issueId: String!, $first: Int!) {
                issue(id: $issueId) {
                    comments(first: $first) {
                        nodes { id body createdAt user { name } }
                    }
                }
            }
        "#;

        let data: CommentsData = self
            .graphql(
                query,
                serde_json::json!({ "issueId": issue_id, "first": first }),
            )
            .await?;

        Ok(data.issue.comments.nodes)
    }

    /// Update an existing comment body.
    pub async fn update_comment(&self, comment_id: &str, body: &str) -> anyhow::Result<()> {
        let query = r#"
            mutation OrbitDockUpdateComment($id: String!, $body: String!) {
                commentUpdate(id: $id, input: {body: $body}) {
                    success
                }
            }
        "#;

        let data: CommentUpdateData = self
            .graphql(query, serde_json::json!({ "id": comment_id, "body": body }))
            .await?;

        if !data.comment_update.success {
            anyhow::bail!("Linear commentUpdate returned success=false for comment {comment_id}");
        }
        Ok(())
    }

    /// Create a new issue in the given team.
    pub async fn create_issue(
        &self,
        team_id: &str,
        title: &str,
        description: &str,
        parent_id: Option<&str>,
    ) -> anyhow::Result<CreatedIssue> {
        let query = r#"
            mutation OrbitDockCreateIssue($teamId: String!, $title: String!, $description: String!, $parentId: String) {
                issueCreate(input: {teamId: $teamId, title: $title, description: $description, parentId: $parentId}) {
                    success
                    issue { id identifier url }
                }
            }
        "#;

        let data: IssueCreateData = self
            .graphql(
                query,
                serde_json::json!({
                    "teamId": team_id,
                    "title": title,
                    "description": description,
                    "parentId": parent_id,
                }),
            )
            .await?;

        if !data.issue_create.success {
            anyhow::bail!("Linear issueCreate returned success=false");
        }

        data.issue_create
            .issue
            .ok_or_else(|| anyhow::anyhow!("Linear issueCreate returned no issue"))
    }

    /// Attach a URL (e.g. PR link) to an issue.
    pub async fn create_attachment(
        &self,
        issue_id: &str,
        url: &str,
        title: &str,
    ) -> anyhow::Result<()> {
        let query = r#"
            mutation OrbitDockCreateAttachment($issueId: String!, $url: String!, $title: String!) {
                attachmentCreate(input: {issueId: $issueId, url: $url, title: $title}) {
                    success
                }
            }
        "#;

        let data: AttachmentCreateData = self
            .graphql(
                query,
                serde_json::json!({ "issueId": issue_id, "url": url, "title": title }),
            )
            .await?;

        if !data.attachment_create.success {
            anyhow::bail!("Linear attachmentCreate returned success=false for issue {issue_id}");
        }
        Ok(())
    }

    /// Resolve the team ID for an issue (needed for creating follow-up issues).
    pub async fn resolve_team_id(&self, issue_id: &str) -> anyhow::Result<String> {
        let query = r#"
            query OrbitDockResolveTeam($issueId: String!) {
                issue(id: $issueId) {
                    team { id }
                }
            }
        "#;

        let data: IssueTeamData = self
            .graphql(query, serde_json::json!({ "issueId": issue_id }))
            .await?;

        Ok(data.issue.team.id)
    }

    /// Fetch a single issue by its human-readable identifier (e.g. "VIZ-240").
    pub async fn fetch_issue_by_identifier(
        &self,
        identifier: &str,
    ) -> anyhow::Result<Option<TrackerIssue>> {
        let query = format!(
            r#"query {{
                issues(filter: {{ identifier: {{ eq: "{identifier}" }} }}, first: 1) {{
                    nodes {{
                        id
                        identifier
                        title
                        description
                        priority
                        url
                        createdAt
                        state {{ name }}
                        labels {{ nodes {{ name }} }}
                        relations {{ nodes {{ type relatedIssue {{ id identifier }} }} }}
                    }}
                }}
            }}"#
        );

        let data: SingleIssueData = self.graphql(&query, serde_json::json!({})).await?;
        Ok(data
            .issues
            .nodes
            .into_iter()
            .next()
            .map(|n| n.into_tracker_issue()))
    }
}

#[async_trait]
impl Tracker for LinearClient {
    async fn fetch_candidates(&self, config: &TrackerConfig) -> anyhow::Result<Vec<TrackerIssue>> {
        let mut all_issues = Vec::new();
        let mut cursor: Option<String> = None;

        loop {
            let data = self.fetch_page(config, cursor.as_deref()).await?;
            let has_next = data.issues.page_info.has_next_page;
            let next_cursor = data.issues.page_info.end_cursor;

            for node in data.issues.nodes {
                all_issues.push(node.into_tracker_issue());
            }

            debug!(
                component = "linear",
                fetched = all_issues.len(),
                has_next = has_next,
                "Fetched issues page"
            );

            if !has_next {
                break;
            }
            cursor = next_cursor;
        }

        Ok(all_issues)
    }

    async fn fetch_issue_states(
        &self,
        issue_ids: &[String],
    ) -> anyhow::Result<HashMap<String, String>> {
        if issue_ids.is_empty() {
            return Ok(HashMap::new());
        }

        let ids: Vec<String> = issue_ids.iter().map(|id| format!(r#""{id}""#)).collect();
        let filter = format!(r#"{{ id: {{ in: [{}] }} }}"#, ids.join(", "));

        let query = format!(
            r#"query {{
                issues(filter: {filter}) {{
                    nodes {{
                        id
                        state {{ name }}
                    }}
                }}
            }}"#
        );

        let data: IssueStatesData = self.graphql(&query, serde_json::json!({})).await?;

        let map = data
            .issues
            .nodes
            .into_iter()
            .map(|node| (node.id, node.state.name))
            .collect();

        Ok(map)
    }

    fn kind(&self) -> &str {
        "linear"
    }

    async fn create_comment(&self, issue_id: &str, body: &str) -> anyhow::Result<()> {
        let query = r#"
            mutation OrbitDockCreateComment($issueId: String!, $body: String!) {
                commentCreate(input: {issueId: $issueId, body: $body}) {
                    success
                }
            }
        "#;

        let data: CommentCreateData = self
            .graphql(
                query,
                serde_json::json!({ "issueId": issue_id, "body": body }),
            )
            .await?;

        if !data.comment_create.success {
            anyhow::bail!("Linear commentCreate returned success=false for issue {issue_id}");
        }
        Ok(())
    }

    async fn update_issue_state(&self, issue_id: &str, state_name: &str) -> anyhow::Result<()> {
        let state_id = self.resolve_state_id(issue_id, state_name).await?;

        let query = r#"
            mutation OrbitDockUpdateIssueState($issueId: String!, $stateId: String!) {
                issueUpdate(id: $issueId, input: {stateId: $stateId}) {
                    success
                }
            }
        "#;

        let data: IssueUpdateData = self
            .graphql(
                query,
                serde_json::json!({ "issueId": issue_id, "stateId": state_id }),
            )
            .await?;

        if !data.issue_update.success {
            anyhow::bail!("Linear issueUpdate returned success=false for issue {issue_id}");
        }
        Ok(())
    }
}
