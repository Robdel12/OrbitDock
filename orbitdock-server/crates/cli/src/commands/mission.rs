use orbitdock_protocol::{MissionSummary, WorkspaceProviderKind};
use serde::{Deserialize, Serialize};

use crate::cli::{
  MissionAction, MissionProviderAction, MissionProviderConfigAction, MissionProviderConfigKey,
};
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct MissionsListResponse {
  missions: Vec<MissionSummary>,
}

#[derive(Debug, Deserialize, Serialize)]
struct MissionDetailResponse {
  summary: MissionSummary,
  issues: Vec<orbitdock_protocol::MissionIssueItem>,
}

#[derive(Debug, Serialize)]
struct CreateMissionRequest {
  repo_root: String,
  provider: String,
  tracker_kind: String,
}

#[derive(Debug, Serialize)]
struct UpdateMissionRequest {
  #[serde(skip_serializing_if = "Option::is_none")]
  enabled: Option<bool>,
  #[serde(skip_serializing_if = "Option::is_none")]
  paused: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize)]
struct OkResponse {
  ok: bool,
}

#[derive(Debug, Serialize)]
struct MissionActionJsonResponse {
  ok: bool,
  action: &'static str,
  #[serde(skip_serializing_if = "Option::is_none")]
  mission_id: Option<String>,
}

#[derive(Debug, Serialize)]
struct MissionListJsonResponse {
  kind: &'static str,
  count: usize,
  missions: Vec<MissionSummary>,
}

#[derive(Debug, Serialize)]
struct MissionDetailJsonEnvelope {
  kind: &'static str,
  mission: MissionSummary,
  issue_count: usize,
  issues: Vec<orbitdock_protocol::MissionIssueItem>,
}

#[derive(Debug, Deserialize, Serialize)]
struct WorkspaceProviderConfigResponse {
  workspace_provider: WorkspaceProviderKind,
}

#[derive(Debug, Serialize)]
struct SetWorkspaceProviderRequest {
  workspace_provider: WorkspaceProviderKind,
}

#[derive(Debug, Serialize)]
struct MissionProviderJsonResponse {
  ok: bool,
  provider: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct MissionProviderConfigResponse {
  key: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  value: Option<String>,
  configured: bool,
  secret: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  source: Option<String>,
}

#[derive(Debug, Serialize)]
struct SetMissionProviderConfigRequest {
  value: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct MissionProviderTestResponse {
  ok: bool,
  provider: String,
  message: String,
}

#[derive(Debug, Serialize)]
struct EmptyJsonObject {}

fn provider_str(provider: &orbitdock_protocol::Provider) -> &'static str {
  match provider {
    orbitdock_protocol::Provider::Claude => "claude",
    orbitdock_protocol::Provider::Codex => "codex",
  }
}

fn mission_state(summary: &MissionSummary) -> &'static str {
  if !summary.enabled {
    "disabled"
  } else if summary.paused {
    "paused"
  } else {
    "active"
  }
}

pub async fn run(action: &MissionAction, rest: &RestClient, output: &Output) -> i32 {
  match action {
    MissionAction::Enable {
      repo_path,
      provider,
      tracker,
    } => enable(rest, output, repo_path, provider, tracker).await,
    MissionAction::List => list(rest, output).await,
    MissionAction::Status { mission_id } => status(rest, output, mission_id).await,
    MissionAction::Pause { mission_id } => pause(rest, output, mission_id).await,
    MissionAction::Resume { mission_id } => resume(rest, output, mission_id).await,
    MissionAction::Disable { mission_id } => disable(rest, output, mission_id).await,
    MissionAction::Dispatch {
      mission_id,
      issue,
      provider,
    } => dispatch(rest, output, mission_id, issue, provider.as_deref()).await,
    MissionAction::Provider { action } => provider(rest, output, action).await,
  }
}

async fn provider(rest: &RestClient, output: &Output, action: &MissionProviderAction) -> i32 {
  match action {
    MissionProviderAction::Get => provider_get(rest, output).await,
    MissionProviderAction::Set { provider } => provider_set(rest, output, *provider).await,
    MissionProviderAction::Config { action } => provider_config(rest, output, action).await,
    MissionProviderAction::Test => provider_test(rest, output).await,
  }
}

async fn provider_get(rest: &RestClient, output: &Output) -> i32 {
  match rest
    .get::<WorkspaceProviderConfigResponse>("/api/server/workspace-provider")
    .await
    .into_result()
  {
    Ok(response) => {
      print_provider(output, response.workspace_provider);
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn provider_set(rest: &RestClient, output: &Output, provider: WorkspaceProviderKind) -> i32 {
  match rest
    .put_json::<_, WorkspaceProviderConfigResponse>(
      "/api/server/workspace-provider",
      &SetWorkspaceProviderRequest {
        workspace_provider: provider,
      },
    )
    .await
    .into_result()
  {
    Ok(response) => {
      print_provider(output, response.workspace_provider);
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

fn print_provider(output: &Output, provider: WorkspaceProviderKind) {
  if output.json {
    output.print_json_pretty(&MissionProviderJsonResponse {
      ok: true,
      provider: provider.as_str().to_string(),
    });
  } else {
    println!("mission.provider={}", provider.as_str());
  }
}

async fn provider_config(
  rest: &RestClient,
  output: &Output,
  action: &MissionProviderConfigAction,
) -> i32 {
  match action {
    MissionProviderConfigAction::Get { key } => provider_config_get(rest, output, *key).await,
    MissionProviderConfigAction::Set { key, value } => {
      provider_config_set(rest, output, *key, value).await
    }
  }
}

async fn provider_config_get(
  rest: &RestClient,
  output: &Output,
  key: MissionProviderConfigKey,
) -> i32 {
  let path = format!(
    "/api/server/workspace-provider/config/{}",
    provider_config_key_str(key)
  );
  match rest
    .get::<MissionProviderConfigResponse>(&path)
    .await
    .into_result()
  {
    Ok(response) => {
      print_provider_config(output, &response);
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn provider_config_set(
  rest: &RestClient,
  output: &Output,
  key: MissionProviderConfigKey,
  value: &str,
) -> i32 {
  let path = format!(
    "/api/server/workspace-provider/config/{}",
    provider_config_key_str(key)
  );
  match rest
    .put_json::<_, MissionProviderConfigResponse>(
      &path,
      &SetMissionProviderConfigRequest {
        value: value.to_string(),
      },
    )
    .await
    .into_result()
  {
    Ok(response) => {
      print_provider_config(output, &response);
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn provider_test(rest: &RestClient, output: &Output) -> i32 {
  match rest
    .post_json::<_, MissionProviderTestResponse>(
      "/api/server/workspace-provider/test",
      &EmptyJsonObject {},
    )
    .await
    .into_result()
  {
    Ok(response) => {
      if output.json {
        output.print_json_pretty(&response);
      } else {
        println!(
          "mission.provider.test={} {}",
          response.provider, response.message
        );
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

fn provider_config_key_str(key: MissionProviderConfigKey) -> &'static str {
  match key {
    MissionProviderConfigKey::PublicServerUrl => "public-server-url",
    MissionProviderConfigKey::DaytonaApiUrl => "daytona-api-url",
    MissionProviderConfigKey::DaytonaApiKey => "daytona-api-key",
    MissionProviderConfigKey::DaytonaImage => "daytona-image",
    MissionProviderConfigKey::DaytonaTarget => "daytona-target",
  }
}

fn print_provider_config(output: &Output, response: &MissionProviderConfigResponse) {
  if output.json {
    output.print_json_pretty(response);
    return;
  }

  let rendered_value = match (&response.value, response.configured, response.secret) {
    (_, false, _) => "<unset>".to_string(),
    (Some(value), _, false) => value.clone(),
    (None, true, true) => "<configured>".to_string(),
    _ => "<configured>".to_string(),
  };
  match response.source.as_deref() {
    Some(source) => {
      println!(
        "mission.provider.config.{}={rendered_value} (source={source})",
        response.key
      );
    }
    None => {
      println!("mission.provider.config.{}={rendered_value}", response.key);
    }
  }
}

async fn enable(
  rest: &RestClient,
  output: &Output,
  repo_path: &str,
  provider: &str,
  tracker: &str,
) -> i32 {
  let repo_root = match std::fs::canonicalize(repo_path) {
    Ok(p) => p.to_string_lossy().to_string(),
    Err(err) => {
      output.print_error(&crate::error::CliError::new(
        "invalid_path",
        format!("Invalid path: {err}"),
      ));
      return crate::error::EXIT_CLIENT_ERROR;
    }
  };

  let body = CreateMissionRequest {
    repo_root,
    provider: provider.to_string(),
    tracker_kind: tracker.to_string(),
  };

  match rest
    .post_json::<_, MissionSummary>("/api/missions", &body)
    .await
    .into_result()
  {
    Ok(resp) => {
      if output.json {
        output.print_json_pretty(&resp);
      } else {
        println!("Mission enabled: {} ({})", resp.id, resp.repo_root);
        println!("  Name:     {}", resp.name);
        println!("  Provider: {}", provider_str(&resp.provider));
        println!("  Tracker:  {}", resp.tracker_kind);
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn list(rest: &RestClient, output: &Output) -> i32 {
  match rest
    .get::<MissionsListResponse>("/api/missions")
    .await
    .into_result()
  {
    Ok(resp) => {
      if output.json {
        output.print_json_pretty(&MissionListJsonResponse {
          kind: "mission_list",
          count: resp.missions.len(),
          missions: resp.missions,
        });
      } else if resp.missions.is_empty() {
        println!("No missions configured.");
      } else {
        println!("Missions ({}):", resp.missions.len());
        for m in &resp.missions {
          println!(
            "  {} [{}] {} ({}) — active:{} queued:{} done:{} failed:{}",
            m.id,
            mission_state(m),
            m.repo_root,
            provider_str(&m.provider),
            m.active_count,
            m.queued_count,
            m.completed_count,
            m.failed_count,
          );
        }
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn status(rest: &RestClient, output: &Output, mission_id: &str) -> i32 {
  match rest
    .get::<MissionDetailResponse>(&format!("/api/missions/{mission_id}"))
    .await
    .into_result()
  {
    Ok(resp) => {
      if output.json {
        output.print_json_pretty(&MissionDetailJsonEnvelope {
          kind: "mission_status",
          mission: resp.summary,
          issue_count: resp.issues.len(),
          issues: resp.issues,
        });
      } else {
        let m = &resp.summary;
        println!("Mission {} [{}]", m.id, mission_state(m));
        println!("  Name:     {}", m.name);
        println!("  Repo:     {}", m.repo_root);
        println!("  Provider: {}", provider_str(&m.provider));
        println!("  Tracker:  {}", m.tracker_kind);
        println!(
          "  Issues:   {} active, {} queued, {} completed, {} failed",
          m.active_count, m.queued_count, m.completed_count, m.failed_count,
        );
        if let Some(ref err) = m.parse_error {
          println!("  Parse error: {err}");
        }
        if !resp.issues.is_empty() {
          println!();
          for issue in &resp.issues {
            println!(
              "  {} {} [{:?}] — {}",
              issue.identifier, issue.title, issue.orchestration_state, issue.tracker_state,
            );
          }
        }
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn pause(rest: &RestClient, output: &Output, mission_id: &str) -> i32 {
  let body = UpdateMissionRequest {
    paused: Some(true),
    enabled: None,
  };
  match rest
    .put_json::<_, OkResponse>(&format!("/api/missions/{mission_id}"), &body)
    .await
    .into_result()
  {
    Ok(_) => {
      if output.json {
        output.print_json_pretty(&MissionActionJsonResponse {
          ok: true,
          action: "paused",
          mission_id: Some(mission_id.to_string()),
        });
      } else {
        println!("Mission {mission_id} paused.");
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn resume(rest: &RestClient, output: &Output, mission_id: &str) -> i32 {
  let body = UpdateMissionRequest {
    paused: Some(false),
    enabled: None,
  };
  match rest
    .put_json::<_, OkResponse>(&format!("/api/missions/{mission_id}"), &body)
    .await
    .into_result()
  {
    Ok(_) => {
      if output.json {
        output.print_json_pretty(&MissionActionJsonResponse {
          ok: true,
          action: "resumed",
          mission_id: Some(mission_id.to_string()),
        });
      } else {
        println!("Mission {mission_id} resumed.");
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn disable(rest: &RestClient, output: &Output, mission_id: &str) -> i32 {
  match rest
    .delete::<OkResponse>(&format!("/api/missions/{mission_id}"))
    .await
    .into_result()
  {
    Ok(_) => {
      if output.json {
        output.print_json_pretty(&MissionActionJsonResponse {
          ok: true,
          action: "disabled",
          mission_id: Some(mission_id.to_string()),
        });
      } else {
        println!("Mission {mission_id} disabled and removed.");
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

#[derive(Debug, Serialize)]
struct DispatchRequest {
  issue_identifier: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  provider: Option<String>,
}

async fn dispatch(
  rest: &RestClient,
  output: &Output,
  mission_id: &str,
  issue_identifier: &str,
  provider: Option<&str>,
) -> i32 {
  let body = DispatchRequest {
    issue_identifier: issue_identifier.to_string(),
    provider: provider.map(|p| p.to_string()),
  };

  match rest
    .post_json::<_, MissionDetailResponse>(&format!("/api/missions/{mission_id}/dispatch"), &body)
    .await
    .into_result()
  {
    Ok(resp) => {
      if output.json {
        output.print_json_pretty(&MissionDetailJsonEnvelope {
          kind: "mission_dispatch",
          mission: resp.summary,
          issue_count: resp.issues.len(),
          issues: resp.issues,
        });
      } else {
        println!("Dispatched {issue_identifier} to mission {mission_id}");
        println!(
          "  Issues: {} active, {} queued, {} completed, {} failed",
          resp.summary.active_count,
          resp.summary.queued_count,
          resp.summary.completed_count,
          resp.summary.failed_count,
        );
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}
