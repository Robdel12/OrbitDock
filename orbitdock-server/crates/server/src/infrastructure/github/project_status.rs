use super::client::GitHubClient;
use super::models::{ProjectItemLookupData, ProjectStatusFieldData, UpdateFieldValueData};
use super::transport;

pub(super) async fn update_issue_state(
  client: &GitHubClient,
  issue_id: &str,
  state_name: &str,
) -> anyhow::Result<()> {
  let lower = state_name.to_lowercase();
  if lower == "open" || lower == "closed" {
    let (owner, repo, number) = client.resolve_repo_from_issue_id(issue_id).await?;
    let url = format!("https://api.github.com/repos/{owner}/{repo}/issues/{number}");

    transport::rest_patch_json(
      client.http(),
      client.token(),
      &url,
      serde_json::json!({ "state": lower }),
    )
    .await?;
    return Ok(());
  }

  update_project_status_field(client, issue_id, state_name).await
}

pub(super) async fn update_project_status_field(
  client: &GitHubClient,
  issue_id: &str,
  state_name: &str,
) -> anyhow::Result<()> {
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

  let lookup: ProjectItemLookupData = transport::graphql(
    client.http(),
    client.token(),
    lookup_query,
    serde_json::json!({ "id": issue_id }),
  )
  .await?;

  let project_items = lookup
    .node
    .ok_or_else(|| anyhow::anyhow!("Issue not found: {issue_id}"))?
    .project_items
    .nodes;

  if project_items.is_empty() {
    anyhow::bail!("Issue {issue_id} is not in any GitHub Project");
  }

  for item in &project_items {
    let project_id = &item.project.id;
    let item_id = &item.id;

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

    let field_data: ProjectStatusFieldData = transport::graphql(
      client.http(),
      client.token(),
      field_query,
      serde_json::json!({ "projectId": project_id }),
    )
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

    let result: UpdateFieldValueData = transport::graphql(
      client.http(),
      client.token(),
      mutation,
      serde_json::json!({
          "projectId": project_id,
          "itemId": item_id,
          "fieldId": status_field.id,
          "optionId": option.id,
      }),
    )
    .await?;

    tracing::debug!(
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
