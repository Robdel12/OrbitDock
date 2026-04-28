use std::collections::HashMap;

use async_trait::async_trait;
use reqwest::Client;
use tracing::debug;

use super::models::{IssueCommentsData, ProjectItem, RepositoryIssueData, UserProjectData};
use super::{helpers, project_status, transport};
use crate::domain::mission_control::tracker::{
  Tracker, TrackerComment, TrackerConfig, TrackerCreatedIssue, TrackerIssue,
};

pub struct GitHubClient {
  http: Client,
  token: String,
}

impl GitHubClient {
  pub fn new(token: String) -> Self {
    Self {
      http: Client::new(),
      token,
    }
  }

  pub(super) fn http(&self) -> &Client {
    &self.http
  }

  pub(super) fn token(&self) -> &str {
    &self.token
  }

  async fn graphql<T: serde::de::DeserializeOwned>(
    &self,
    query: &str,
    variables: serde_json::Value,
  ) -> anyhow::Result<T> {
    transport::graphql(self.http(), self.token(), query, variables).await
  }

  /// Parse an identifier like `owner/repo#42` into (owner, repo, number).
  fn parse_identifier(identifier: &str) -> anyhow::Result<(String, String, u64)> {
    helpers::parse_identifier(identifier)
  }

  /// Fetch project items from a GitHub Projects v2 project.
  /// `owner` is the user/org login, `project_number` is the project number.
  async fn fetch_project_items_page(
    &self,
    owner: &str,
    project_number: u64,
    status_filter: &[String],
    label_filter: &[String],
    cursor: Option<&str>,
  ) -> anyhow::Result<(Vec<TrackerIssue>, bool, Option<String>)> {
    let query = r#"
            query($login: String!, $number: Int!, $after: String) {
                user(login: $login) {
                    projectV2(number: $number) {
                        items(first: 50, after: $after) {
                            nodes {
                                fieldValueByName(name: "Status") {
                                    ... on ProjectV2ItemFieldSingleSelectValue {
                                        name
                                    }
                                }
                                content {
                                    __typename
                                    ... on Issue {
                                        id
                                        number
                                        title
                                        body
                                        url
                                        createdAt
                                        state
                                        labels(first: 20) { nodes { name } }
                                        repository { name owner { login } }
                                    }
                                }
                            }
                            pageInfo {
                                hasNextPage
                                endCursor
                            }
                        }
                    }
                }
                organization(login: $login) {
                    projectV2(number: $number) {
                        items(first: 50, after: $after) {
                            nodes {
                                fieldValueByName(name: "Status") {
                                    ... on ProjectV2ItemFieldSingleSelectValue {
                                        name
                                    }
                                }
                                content {
                                    __typename
                                    ... on Issue {
                                        id
                                        number
                                        title
                                        body
                                        url
                                        createdAt
                                        state
                                        labels(first: 20) { nodes { name } }
                                        repository { name owner { login } }
                                    }
                                }
                            }
                            pageInfo {
                                hasNextPage
                                endCursor
                            }
                        }
                    }
                }
            }
        "#;

    let data: UserProjectData = self
      .graphql(
        query,
        serde_json::json!({
            "login": owner,
            "number": project_number as i64,
            "after": cursor,
        }),
      )
      .await?;

    // Take whichever resolved (user or org)
    let project = data
      .user
      .and_then(|u| u.project_v2)
      .or_else(|| data.organization.and_then(|o| o.project_v2))
      .ok_or_else(|| {
        anyhow::anyhow!("GitHub Project #{project_number} not found for owner '{owner}'")
      })?;

    let has_next = project.items.page_info.has_next_page;
    let next_cursor = project.items.page_info.end_cursor;

    let issues = self.filter_project_items(project.items.nodes, status_filter, label_filter);

    Ok((issues, has_next, next_cursor))
  }

  /// Filter and convert project items to TrackerIssues.
  fn filter_project_items(
    &self,
    items: Vec<ProjectItem>,
    status_filter: &[String],
    label_filter: &[String],
  ) -> Vec<TrackerIssue> {
    helpers::filter_project_items(items, status_filter, label_filter)
  }

  /// Resolve owner/repo from a GitHub node ID by querying the issue.
  pub(super) async fn resolve_repo_from_issue_id(
    &self,
    issue_id: &str,
  ) -> anyhow::Result<(String, String, u64)> {
    let query = r#"
            query($id: ID!) {
                node(id: $id) {
                    ... on Issue {
                        number
                        repository {
                            name
                            owner { login }
                        }
                    }
                }
            }
        "#;

    #[derive(serde::Deserialize)]
    struct NodeResp {
      node: Option<IssueRepoNode>,
    }

    #[derive(serde::Deserialize)]
    struct IssueRepoNode {
      number: u64,
      repository: super::models::RepositoryRef,
    }

    let data: NodeResp = self
      .graphql(query, serde_json::json!({ "id": issue_id }))
      .await?;

    let node = data
      .node
      .ok_or_else(|| anyhow::anyhow!("Issue node not found: {issue_id}"))?;

    Ok((
      node.repository.owner.login,
      node.repository.name,
      node.number,
    ))
  }
}

#[async_trait]
impl Tracker for GitHubClient {
  async fn fetch_candidates(&self, config: &TrackerConfig) -> anyhow::Result<Vec<TrackerIssue>> {
    let owner = config
      .team_key
      .as_deref()
      .ok_or_else(|| anyhow::anyhow!("team_key (owner) is required for GitHub tracker"))?;

    // For GitHub, team_key can be "owner" or "owner/repo"
    // project_key is the project number
    let project_number: u64 = config
      .project_key
      .as_deref()
      .ok_or_else(|| {
        anyhow::anyhow!("project_key (project number) is required for GitHub tracker")
      })?
      .parse()
      .map_err(|_| anyhow::anyhow!("project_key must be a project number (e.g. '1')"))?;

    // Parse owner — strip /repo if present (project is at the user/org level)
    let owner_login = owner.split('/').next().unwrap_or(owner);

    let mut all_issues = Vec::new();
    let mut cursor: Option<String> = None;

    loop {
      let (issues, has_next, next_cursor) = self
        .fetch_project_items_page(
          owner_login,
          project_number,
          &config.state_filter,
          &config.label_filter,
          cursor.as_deref(),
        )
        .await?;

      all_issues.extend(issues);

      debug!(
        component = "github",
        fetched = all_issues.len(),
        has_next = has_next,
        "Fetched project items page"
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

    // Batch query each issue's state via their node IDs
    let mut map = HashMap::new();

    for id in issue_ids {
      let query = r#"
                query($id: ID!) {
                    node(id: $id) {
                        ... on Issue {
                            id
                            state
                        }
                    }
                }
            "#;

      #[derive(serde::Deserialize)]
      struct NodeResp {
        node: Option<super::models::IssueStateNode>,
      }

      match self
        .graphql::<NodeResp>(query, serde_json::json!({ "id": id }))
        .await
      {
        Ok(data) => {
          if let Some(node) = data.node {
            map.insert(node.id, node.state);
          }
        }
        Err(e) => {
          tracing::warn!(
              component = "github",
              issue_id = %id,
              error = %e,
              "Failed to fetch issue state"
          );
        }
      }
    }

    Ok(map)
  }

  fn kind(&self) -> &str {
    "github"
  }

  async fn create_comment(&self, issue_id: &str, body: &str) -> anyhow::Result<()> {
    let (owner, repo, number) = self.resolve_repo_from_issue_id(issue_id).await?;
    let url = format!("https://api.github.com/repos/{owner}/{repo}/issues/{number}/comments");
    transport::rest_post_json(
      self.http(),
      self.token(),
      &url,
      serde_json::json!({ "body": body }),
    )
    .await
  }

  async fn update_issue_state(&self, issue_id: &str, state_name: &str) -> anyhow::Result<()> {
    // For GitHub, "state" could mean:
    // 1. Issue open/closed state
    // 2. Project Status field value (e.g. "Todo", "In Progress", "Done")
    //
    // We handle both: if the state_name is "open"/"closed", update the issue state.
    // Otherwise, treat it as a project Status field update.
    project_status::update_issue_state(self, issue_id, state_name).await
  }

  async fn fetch_issue_by_identifier(
    &self,
    identifier: &str,
  ) -> anyhow::Result<Option<TrackerIssue>> {
    let (owner, repo, number) = Self::parse_identifier(identifier)?;

    let query = r#"
            query($owner: String!, $repo: String!, $number: Int!) {
                repository(owner: $owner, name: $repo) {
                    issue(number: $number) {
                        id
                        number
                        title
                        body
                        url
                        createdAt
                        state
                        labels(first: 20) { nodes { name } }
                        repository { name owner { login } }
                    }
                }
            }
        "#;

    let result: Result<RepositoryIssueData, _> = self
      .graphql(
        query,
        serde_json::json!({
            "owner": owner,
            "repo": repo,
            "number": number as i64,
        }),
      )
      .await;

    match result {
      Ok(data) => Ok(
        data
          .repository
          .and_then(|r| r.issue)
          .map(|issue| issue.into_tracker_issue(None)),
      ),
      Err(e) if e.to_string().contains("not found") => Ok(None),
      Err(e) => Err(e),
    }
  }

  async fn list_comments(&self, issue_id: &str, first: u32) -> anyhow::Result<Vec<TrackerComment>> {
    let query = r#"
            query($id: ID!, $first: Int!) {
                node(id: $id) {
                    ... on Issue {
                        comments(first: $first) {
                            nodes {
                                id
                                body
                                createdAt
                                author { login }
                            }
                        }
                    }
                }
            }
        "#;

    let data: IssueCommentsData = self
      .graphql(
        query,
        serde_json::json!({ "id": issue_id, "first": first as i64 }),
      )
      .await?;

    let comments = data.node.map(|n| n.comments.nodes).unwrap_or_default();

    // Use the GraphQL node ID so update_comment can use it directly
    Ok(
      comments
        .into_iter()
        .map(|c| TrackerComment {
          id: c.id,
          body: c.body,
          created_at: c.created_at,
          author: c.author.map(|a| a.login),
        })
        .collect(),
    )
  }

  async fn update_comment(&self, comment_id: &str, body: &str) -> anyhow::Result<()> {
    // comment_id is a GraphQL node ID (returned by list_comments)
    let query = r#"
            mutation($id: ID!, $body: String!) {
                updateIssueComment(input: {id: $id, body: $body}) {
                    issueComment { id }
                }
            }
        "#;

    let _: serde_json::Value = self
      .graphql(query, serde_json::json!({ "id": comment_id, "body": body }))
      .await?;

    Ok(())
  }

  async fn create_issue(
    &self,
    parent_id: &str,
    title: &str,
    description: &str,
  ) -> anyhow::Result<TrackerCreatedIssue> {
    // Resolve the repository from the parent issue
    let (owner, repo, _parent_number) = self.resolve_repo_from_issue_id(parent_id).await?;

    // First get the repository node ID
    let repo_query = r#"
            query($owner: String!, $repo: String!) {
                repository(owner: $owner, name: $repo) { id }
            }
        "#;

    #[derive(serde::Deserialize)]
    struct RepoData {
      repository: Option<super::models::RepositoryIdNode>,
    }

    let repo_data: RepoData = self
      .graphql(
        repo_query,
        serde_json::json!({ "owner": owner, "repo": repo }),
      )
      .await?;

    let repo_id = repo_data
      .repository
      .ok_or_else(|| anyhow::anyhow!("Repository {owner}/{repo} not found"))?
      .id;

    // Create the issue via GraphQL
    let query = r#"
            mutation($repositoryId: ID!, $title: String!, $body: String!) {
                createIssue(input: {repositoryId: $repositoryId, title: $title, body: $body}) {
                    issue {
                        id
                        number
                        url
                    }
                }
            }
        "#;

    let data: super::models::CreateIssueData = self
      .graphql(
        query,
        serde_json::json!({
            "repositoryId": repo_id,
            "title": title,
            "body": description,
        }),
      )
      .await?;

    let created = data
      .create_issue
      .and_then(|p| p.issue)
      .ok_or_else(|| anyhow::anyhow!("GitHub createIssue returned no issue"))?;

    Ok(TrackerCreatedIssue {
      id: created.id,
      identifier: format!("{owner}/{repo}#{}", created.number),
      url: created.url,
    })
  }

  async fn link_url(&self, issue_id: &str, url: &str, title: &str) -> anyhow::Result<()> {
    // GitHub doesn't have first-class attachments — post a comment with the link
    let body = format!("**{title}**: {url}");
    self.create_comment(issue_id, &body).await
  }
}

#[cfg(test)]
#[path = "client_tests.rs"]
mod tests;
