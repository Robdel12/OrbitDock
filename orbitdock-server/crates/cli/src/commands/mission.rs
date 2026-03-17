use orbitdock_protocol::MissionSummary;
use serde::{Deserialize, Serialize};

use crate::cli::MissionAction;
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
                output.print_json(&resp);
            } else {
                println!("Mission enabled: {} ({})", resp.id, resp.repo_root);
                println!("  Provider: {:?}", resp.provider);
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
                output.print_json(&resp);
            } else if resp.missions.is_empty() {
                println!("No missions configured.");
            } else {
                for m in &resp.missions {
                    let state = if !m.enabled {
                        "disabled"
                    } else if m.paused {
                        "paused"
                    } else {
                        "active"
                    };
                    println!(
                        "  {} [{}] {} ({:?}) — active:{} queued:{} done:{} failed:{}",
                        m.id,
                        state,
                        m.repo_root,
                        m.provider,
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
                output.print_json(&resp);
            } else {
                let m = &resp.summary;
                let state = if !m.enabled {
                    "disabled"
                } else if m.paused {
                    "paused"
                } else {
                    "active"
                };
                println!("Mission {} [{}]", m.id, state);
                println!("  Repo:     {}", m.repo_root);
                println!("  Provider: {:?}", m.provider);
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
                            issue.identifier,
                            issue.title,
                            issue.orchestration_state,
                            issue.tracker_state,
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
                output.print_json(&serde_json::json!({ "ok": true, "action": "paused" }));
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
                output.print_json(&serde_json::json!({ "ok": true, "action": "resumed" }));
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
                output.print_json(&serde_json::json!({ "ok": true, "action": "disabled" }));
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
        .post_json::<_, MissionDetailResponse>(
            &format!("/api/missions/{mission_id}/dispatch"),
            &body,
        )
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
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
