use std::collections::HashMap;

use async_trait::async_trait;
use reqwest::Client;
use tracing::debug;

use super::models::{
    GraphQLResponse, IssueCommentsData, ProjectItem, ProjectItemContent, ProjectItemLookupData,
    ProjectStatusFieldData, RepositoryIssueData, UpdateFieldValueData, UserProjectData,
};
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
            .post("https://api.github.com/graphql")
            .header("Authorization", format!("Bearer {}", self.token))
            .header("User-Agent", "OrbitDock")
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await?;

        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("GitHub API returned {status}: {text}");
        }

        let gql: GraphQLResponse<T> = resp.json().await?;

        // Return data even with partial errors — the dual user/org project
        // query always produces one error branch for personal accounts.
        if let Some(data) = gql.data {
            if let Some(ref errors) = gql.errors {
                let msgs: Vec<_> = errors.iter().map(|e| e.message.as_str()).collect();
                tracing::debug!(
                    component = "github",
                    errors = %msgs.join("; "),
                    "GraphQL partial errors (data still returned)"
                );
            }
            return Ok(data);
        }

        if let Some(errors) = gql.errors {
            let msgs: Vec<_> = errors.iter().map(|e| e.message.as_str()).collect();
            anyhow::bail!("GitHub GraphQL errors: {}", msgs.join("; "));
        }

        anyhow::bail!("GitHub response contained no data")
    }

    /// Parse an identifier like `owner/repo#42` into (owner, repo, number).
    fn parse_identifier(identifier: &str) -> anyhow::Result<(String, String, u64)> {
        // Accept: "owner/repo#42" or "#42" (but the latter needs repo context)
        let parts: Vec<&str> = identifier.splitn(2, '#').collect();
        if parts.len() != 2 {
            anyhow::bail!(
                "Invalid GitHub identifier format: {identifier}. Expected owner/repo#number"
            );
        }

        let number: u64 = parts[1]
            .parse()
            .map_err(|_| anyhow::anyhow!("Invalid issue number in identifier: {identifier}"))?;

        let repo_parts: Vec<&str> = parts[0].splitn(2, '/').collect();
        if repo_parts.len() != 2 || repo_parts[0].is_empty() || repo_parts[1].is_empty() {
            anyhow::bail!(
                "Invalid GitHub identifier format: {identifier}. Expected owner/repo#number"
            );
        }

        Ok((repo_parts[0].to_string(), repo_parts[1].to_string(), number))
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
        let mut result = Vec::new();

        for item in items {
            let status = item
                .field_value_by_name
                .as_ref()
                .and_then(|v| v.name.clone());

            // Filter by status if filter is specified
            if !status_filter.is_empty() {
                if let Some(ref s) = status {
                    if !status_filter.iter().any(|f| f.eq_ignore_ascii_case(s)) {
                        continue;
                    }
                } else {
                    continue; // No status set, skip
                }
            }

            // Only process Issues (not PRs or DraftIssues)
            let content = match item.content {
                Some(ProjectItemContent::Issue(issue)) => *issue,
                _ => continue,
            };

            // Filter by labels if filter is specified
            if !label_filter.is_empty() {
                let has_label = content
                    .labels
                    .nodes
                    .iter()
                    .any(|l| label_filter.iter().any(|f| f.eq_ignore_ascii_case(&l.name)));
                if !has_label {
                    continue;
                }
            }

            result.push(content.into_tracker_issue(status));
        }

        result
    }

    /// POST a comment on a GitHub issue via REST API.
    async fn rest_create_comment(
        &self,
        owner: &str,
        repo: &str,
        number: u64,
        body: &str,
    ) -> anyhow::Result<()> {
        let url = format!("https://api.github.com/repos/{owner}/{repo}/issues/{number}/comments");

        let resp = self
            .http
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .header("User-Agent", "OrbitDock")
            .header("Accept", "application/vnd.github+json")
            .json(&serde_json::json!({ "body": body }))
            .send()
            .await?;

        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("GitHub REST API returned {status}: {text}");
        }

        Ok(())
    }

    /// Update a project Status field value for an issue.
    ///
    /// This involves three GraphQL operations:
    /// 1. Look up the issue's project items to find the project ID and item ID
    /// 2. Query the project's Status field to find the field ID and target option ID
    /// 3. Call updateProjectV2ItemFieldValue to set the new value
    async fn update_project_status_field(
        &self,
        issue_id: &str,
        state_name: &str,
    ) -> anyhow::Result<()> {
        // Step 1: Find which project(s) this issue belongs to and get item IDs
        let lookup_query = r#"
            query($id: ID!) {
                node(id: $id) {
                    ... on Issue {
                        projectItems(first: 10) {
                            nodes {
                                id
                                project { id }
                            }
                        }
                    }
                }
            }
        "#;

        let lookup: ProjectItemLookupData = self
            .graphql(lookup_query, serde_json::json!({ "id": issue_id }))
            .await?;

        let project_items = lookup
            .node
            .ok_or_else(|| anyhow::anyhow!("Issue not found: {issue_id}"))?
            .project_items
            .nodes;

        if project_items.is_empty() {
            anyhow::bail!("Issue {issue_id} is not in any GitHub Project");
        }

        // Update status on all projects the issue belongs to
        for item in &project_items {
            let project_id = &item.project.id;
            let item_id = &item.id;

            // Step 2: Get the Status field ID and option IDs for this project
            let field_query = r#"
                query($projectId: ID!) {
                    node(id: $projectId) {
                        ... on ProjectV2 {
                            field(name: "Status") {
                                ... on ProjectV2SingleSelectField {
                                    id
                                    options { id name }
                                }
                            }
                        }
                    }
                }
            "#;

            let field_data: ProjectStatusFieldData = self
                .graphql(field_query, serde_json::json!({ "projectId": project_id }))
                .await?;

            let status_field = field_data
                .node
                .and_then(|n| n.field)
                .ok_or_else(|| anyhow::anyhow!("Status field not found on project {project_id}"))?;

            let option = status_field
                .options
                .iter()
                .find(|o| o.name.eq_ignore_ascii_case(state_name))
                .ok_or_else(|| {
                    let available: Vec<_> = status_field
                        .options
                        .iter()
                        .map(|o| o.name.as_str())
                        .collect();
                    anyhow::anyhow!(
                        "Status option '{state_name}' not found. Available: {}",
                        available.join(", ")
                    )
                })?;

            // Step 3: Update the field value
            let mutation = r#"
                mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
                    updateProjectV2ItemFieldValue(input: {
                        projectId: $projectId,
                        itemId: $itemId,
                        fieldId: $fieldId,
                        value: { singleSelectOptionId: $optionId }
                    }) {
                        projectV2Item { id }
                    }
                }
            "#;

            let result: UpdateFieldValueData = self
                .graphql(
                    mutation,
                    serde_json::json!({
                        "projectId": project_id,
                        "itemId": item_id,
                        "fieldId": status_field.id,
                        "optionId": option.id,
                    }),
                )
                .await?;

            debug!(
                component = "github",
                project_id = project_id,
                item_id = item_id,
                updated_item = result.updated_item_id().unwrap_or("unknown"),
                state = state_name,
                "Updated project Status field"
            );
        }

        Ok(())
    }

    /// Resolve owner/repo from a GitHub node ID by querying the issue.
    async fn resolve_repo_from_issue_id(
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
        self.rest_create_comment(&owner, &repo, number, body).await
    }

    async fn update_issue_state(&self, issue_id: &str, state_name: &str) -> anyhow::Result<()> {
        // For GitHub, "state" could mean:
        // 1. Issue open/closed state
        // 2. Project Status field value (e.g. "Todo", "In Progress", "Done")
        //
        // We handle both: if the state_name is "open"/"closed", update the issue state.
        // Otherwise, treat it as a project Status field update.
        let lower = state_name.to_lowercase();
        if lower == "open" || lower == "closed" {
            let (owner, repo, number) = self.resolve_repo_from_issue_id(issue_id).await?;
            let url = format!("https://api.github.com/repos/{owner}/{repo}/issues/{number}");

            let resp = self
                .http
                .patch(&url)
                .header("Authorization", format!("Bearer {}", self.token))
                .header("User-Agent", "OrbitDock")
                .header("Accept", "application/vnd.github+json")
                .json(&serde_json::json!({ "state": lower }))
                .send()
                .await?;

            let status = resp.status();
            if !status.is_success() {
                let text = resp.text().await.unwrap_or_default();
                anyhow::bail!("GitHub REST API returned {status}: {text}");
            }
            return Ok(());
        }

        // Project Status field update (e.g. "In Progress", "Done")
        self.update_project_status_field(issue_id, state_name).await
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
            Ok(data) => Ok(data
                .repository
                .and_then(|r| r.issue)
                .map(|issue| issue.into_tracker_issue(None))),
            Err(e) if e.to_string().contains("not found") => Ok(None),
            Err(e) => Err(e),
        }
    }

    async fn list_comments(
        &self,
        issue_id: &str,
        first: u32,
    ) -> anyhow::Result<Vec<TrackerComment>> {
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
        Ok(comments
            .into_iter()
            .map(|c| TrackerComment {
                id: c.id,
                body: c.body,
                created_at: c.created_at,
                author: c.author.map(|a| a.login),
            })
            .collect())
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
mod tests {
    use super::super::models::*;
    use super::*;

    fn make_client() -> GitHubClient {
        GitHubClient::new("fake-token".to_string())
    }

    fn issue_item(status: Option<&str>, labels: &[&str]) -> ProjectItem {
        ProjectItem {
            field_value_by_name: status.map(|s| StatusFieldValue {
                name: Some(s.to_string()),
            }),
            content: Some(ProjectItemContent::Issue(Box::new(GitHubIssueNode {
                id: "I_1".to_string(),
                number: 1,
                title: "Test issue".to_string(),
                body: None,
                url: "https://github.com/test/repo/issues/1".to_string(),
                created_at: None,
                state: "OPEN".to_string(),
                labels: LabelConnection {
                    nodes: labels
                        .iter()
                        .map(|l| GitHubLabel {
                            name: l.to_string(),
                        })
                        .collect(),
                },
                repository: RepositoryRef {
                    name: "repo".to_string(),
                    owner: RepositoryOwner {
                        login: "test".to_string(),
                    },
                },
            }))),
        }
    }

    fn pr_item() -> ProjectItem {
        ProjectItem {
            field_value_by_name: Some(StatusFieldValue {
                name: Some("Todo".to_string()),
            }),
            content: Some(ProjectItemContent::PullRequest(GitHubPRNode {})),
        }
    }

    fn draft_item() -> ProjectItem {
        ProjectItem {
            field_value_by_name: Some(StatusFieldValue {
                name: Some("Todo".to_string()),
            }),
            content: Some(ProjectItemContent::DraftIssue(DraftIssueNode {})),
        }
    }

    #[test]
    fn no_filters_returns_all_issues() {
        let client = make_client();
        let items = vec![issue_item(Some("Todo"), &[]), issue_item(None, &["bug"])];
        let result = client.filter_project_items(items, &[], &[]);
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn status_filter_case_insensitive() {
        let client = make_client();
        let items = vec![
            issue_item(Some("In Progress"), &[]),
            issue_item(Some("in progress"), &[]),
            issue_item(Some("IN PROGRESS"), &[]),
            issue_item(Some("Todo"), &[]),
        ];
        let filter = vec!["in progress".to_string()];
        let result = client.filter_project_items(items, &filter, &[]);
        assert_eq!(result.len(), 3);
    }

    #[test]
    fn status_filter_skips_items_without_status() {
        let client = make_client();
        let items = vec![issue_item(Some("Todo"), &[]), issue_item(None, &[])];
        let filter = vec!["Todo".to_string()];
        let result = client.filter_project_items(items, &filter, &[]);
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn status_filter_skips_items_with_empty_field_value() {
        let client = make_client();
        // field_value_by_name is Some but name is None
        let mut item = issue_item(None, &[]);
        item.field_value_by_name = Some(StatusFieldValue { name: None });
        let items = vec![item, issue_item(Some("Todo"), &[])];
        let filter = vec!["Todo".to_string()];
        let result = client.filter_project_items(items, &filter, &[]);
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn label_filter_case_insensitive() {
        let client = make_client();
        let items = vec![
            issue_item(None, &["Bug"]),
            issue_item(None, &["bug"]),
            issue_item(None, &["BUG"]),
            issue_item(None, &["feature"]),
        ];
        let filter = vec!["bug".to_string()];
        let result = client.filter_project_items(items, &[], &filter);
        assert_eq!(result.len(), 3);
    }

    #[test]
    fn label_filter_requires_at_least_one_match() {
        let client = make_client();
        let items = vec![
            issue_item(None, &["enhancement", "p1"]),
            issue_item(None, &["docs"]),
        ];
        let filter = vec!["p1".to_string()];
        let result = client.filter_project_items(items, &[], &filter);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].title, "Test issue");
    }

    #[test]
    fn skips_pull_request_items() {
        let client = make_client();
        let items = vec![pr_item(), issue_item(Some("Todo"), &[])];
        let filter = vec!["Todo".to_string()];
        let result = client.filter_project_items(items, &filter, &[]);
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn skips_draft_issue_items() {
        let client = make_client();
        let items = vec![draft_item(), issue_item(Some("Todo"), &[])];
        let filter = vec!["Todo".to_string()];
        let result = client.filter_project_items(items, &filter, &[]);
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn combined_status_and_label_filter() {
        let client = make_client();
        let items = vec![
            issue_item(Some("Todo"), &["bug"]),     // matches both
            issue_item(Some("Todo"), &["feature"]), // status matches, label doesn't
            issue_item(Some("Done"), &["bug"]),     // label matches, status doesn't
        ];
        let result =
            client.filter_project_items(items, &["Todo".to_string()], &["bug".to_string()]);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].state, "Todo");
    }

    #[test]
    fn status_propagated_to_tracker_issue_state() {
        let client = make_client();
        let items = vec![issue_item(Some("In Review"), &[])];
        let result = client.filter_project_items(items, &[], &[]);
        assert_eq!(result[0].state, "In Review");
    }

    #[test]
    fn no_status_uses_issue_state_when_no_filter() {
        let client = make_client();
        let items = vec![issue_item(None, &[])];
        let result = client.filter_project_items(items, &[], &[]);
        assert_eq!(result[0].state, "OPEN");
    }
}
