use base64::Engine;
use orbitdock_protocol::{LibrarySnapshot, Provider, SessionSummary};
use serde::{Deserialize, Serialize};

use crate::cli::{Effort, PermissionMode, ProviderFilter, StatusFilter};
use crate::client::config::ClientConfig;
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::{human, Output};

use super::presentation::{
  build_session_detail_json_response, build_session_list_json_response,
  conversation_snapshot_from_session, print_conversation_snapshot, print_session_detail,
  session_json_overview_from_summary, SessionActionJsonResponse,
};

#[derive(Debug, Deserialize, Serialize)]
struct SessionsResponse {
  sessions: Vec<orbitdock_protocol::SessionListItem>,
}

#[derive(Debug, Deserialize, Serialize)]
struct CreateSessionRequest {
  session_id: Option<String>,
  provider: Provider,
  cwd: String,
  model: Option<String>,
  approval_policy: Option<String>,
  approval_policy_details: Option<orbitdock_protocol::CodexApprovalPolicy>,
  sandbox_mode: Option<String>,
  permission_mode: Option<String>,
  allowed_tools: Vec<String>,
  disallowed_tools: Vec<String>,
  effort: Option<String>,
  collaboration_mode: Option<String>,
  multi_agent: Option<bool>,
  personality: Option<String>,
  service_tier: Option<String>,
  developer_instructions: Option<String>,
  system_prompt: Option<String>,
  append_system_prompt: Option<String>,
  allow_bypass_permissions: bool,
  codex_config_mode: Option<orbitdock_protocol::CodexConfigMode>,
  codex_config_profile: Option<String>,
  codex_model_provider: Option<String>,
  codex_config_source: Option<orbitdock_protocol::CodexConfigSource>,
  mission_id: Option<String>,
  issue_id: Option<String>,
  issue_identifier: Option<String>,
  workspace_id: Option<String>,
  initial_prompt: Option<String>,
  skills: Vec<String>,
  tracker_kind: Option<String>,
  tracker_api_key: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct CreateSessionResponse {
  session_id: String,
  session: SessionSummary,
}

#[derive(Debug, Deserialize, Serialize)]
struct ResumeSessionResponse {
  session_id: String,
  session: SessionSummary,
}

#[derive(Debug, Deserialize, Serialize)]
struct ForkSessionRequest {
  model: Option<String>,
  approval_policy: Option<String>,
  sandbox_mode: Option<String>,
  cwd: Option<String>,
  permission_mode: Option<String>,
  allowed_tools: Vec<String>,
  disallowed_tools: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ForkSessionResponse {
  source_session_id: String,
  new_session_id: String,
  session: SessionSummary,
}

pub(crate) struct CreateSessionArgs<'a> {
  pub(crate) rest: &'a RestClient,
  pub(crate) output: &'a Output,
  pub(crate) provider_filter: &'a ProviderFilter,
  pub(crate) cwd: &'a str,
  pub(crate) model: Option<&'a str>,
  pub(crate) permission_mode: Option<&'a PermissionMode>,
  pub(crate) effort: Option<&'a Effort>,
  pub(crate) system_prompt: Option<&'a str>,
}

pub(crate) async fn list(
  rest: &RestClient,
  output: &Output,
  provider: Option<&ProviderFilter>,
  status: Option<&StatusFilter>,
  project: Option<&str>,
) -> i32 {
  match rest
    .get::<LibrarySnapshot>("/api/sessions/archive")
    .await
    .into_result()
  {
    Ok(snapshot) => {
      let mut resp = SessionsResponse {
        sessions: snapshot.sessions,
      };
      if let Some(p) = provider {
        let target = match p {
          ProviderFilter::Claude => Provider::Claude,
          ProviderFilter::Codex => Provider::Codex,
        };
        resp.sessions.retain(|s| s.provider == target);
      }
      if let Some(s) = status {
        let target = match s {
          StatusFilter::Active => orbitdock_protocol::SessionStatus::Active,
          StatusFilter::Ended => orbitdock_protocol::SessionStatus::Ended,
        };
        resp.sessions.retain(|s| s.status == target);
      }
      if let Some(proj) = project {
        resp.sessions.retain(|s| s.project_path.contains(proj));
      }

      if output.json {
        output.print_json_pretty(&build_session_list_json_response(resp.sessions));
      } else {
        human::sessions_table(&resp.sessions);
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

pub(crate) async fn get(
  rest: &RestClient,
  output: &Output,
  session_id: &str,
  messages: bool,
) -> i32 {
  let path = if messages {
    format!("/api/sessions/{session_id}/detail?include_messages=true")
  } else {
    format!("/api/sessions/{session_id}/detail")
  };
  match rest
    .get::<orbitdock_protocol::SessionDetailSnapshot>(&path)
    .await
    .into_result()
  {
    Ok(snapshot) => {
      if output.json {
        output.print_json_pretty(&build_session_detail_json_response(snapshot, messages));
      } else {
        let conversation = if messages {
          if let Some(snapshot_page) = conversation_snapshot_from_session(&snapshot.session) {
            Some(snapshot_page)
          } else if snapshot.session.total_row_count == 0 {
            None
          } else {
            let limit = snapshot.session.total_row_count.min(200) as usize;
            match rest
              .get::<orbitdock_protocol::ConversationSnapshotPage>(&format!(
                "/api/sessions/{session_id}/conversation?limit={limit}"
              ))
              .await
              .into_result()
            {
              Ok(snapshot) => Some(snapshot),
              Err((code, err)) => {
                output.print_error(&err);
                return code;
              }
            }
          }
        } else {
          None
        };

        print_session_detail(&snapshot.session);
        if messages {
          print_conversation_snapshot(conversation.as_ref());
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

pub(crate) async fn create(args: CreateSessionArgs<'_>) -> i32 {
  let CreateSessionArgs {
    rest,
    output,
    provider_filter,
    cwd,
    model,
    permission_mode,
    effort,
    system_prompt,
  } = args;

  let provider = match provider_filter {
    ProviderFilter::Claude => Provider::Claude,
    ProviderFilter::Codex => Provider::Codex,
  };

  let request = CreateSessionRequest {
    provider,
    cwd: cwd.to_string(),
    model: model.map(str::to_string),
    approval_policy: None,
    approval_policy_details: None,
    sandbox_mode: None,
    permission_mode: permission_mode.map(|m| m.as_str().to_string()),
    allowed_tools: vec![],
    disallowed_tools: vec![],
    effort: effort.map(|e| e.as_str().to_string()),
    collaboration_mode: None,
    multi_agent: None,
    personality: None,
    service_tier: None,
    developer_instructions: None,
    system_prompt: system_prompt.map(str::to_string),
    append_system_prompt: None,
    allow_bypass_permissions: false,
    codex_config_mode: None,
    codex_config_profile: None,
    codex_model_provider: None,
    codex_config_source: None,
    session_id: None,
    mission_id: None,
    issue_id: None,
    issue_identifier: None,
    workspace_id: None,
    initial_prompt: None,
    skills: vec![],
    tracker_kind: None,
    tracker_api_key: None,
  };

  match rest
    .post_json::<_, CreateSessionResponse>("/api/sessions", &request)
    .await
    .into_result()
  {
    Ok(resp) => {
      let session = resp.session;
      if output.json {
        output.print_json_pretty(&SessionActionJsonResponse {
          ok: true,
          action: "created",
          session_id: session.id.clone(),
          source_session_id: None,
          summary: session_json_overview_from_summary(&session),
          session,
        });
      } else {
        let bold = console::Style::new().bold();
        println!("{} {}", bold.apply_to("Created session:"), session.id);
        println!(
          "{} {}",
          bold.apply_to("Provider:"),
          super::presentation::provider_str(&session.provider)
        );
        println!("{} {}", bold.apply_to("Project:"), session.project_path);
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

pub fn run_managed_session_start(
  server_url: Option<&str>,
  request_base64: &str,
) -> anyhow::Result<()> {
  let request_bytes = base64::engine::general_purpose::STANDARD
    .decode(request_base64)
    .map_err(|error| anyhow::anyhow!("decode managed session request: {error}"))?;
  let request: CreateSessionRequest = serde_json::from_slice(&request_bytes)
    .map_err(|error| anyhow::anyhow!("parse managed session request: {error}"))?;

  let config = ClientConfig::from_sources(server_url, None, true, None);
  let rest = RestClient::new(&config);
  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .map_err(|error| anyhow::anyhow!("build Tokio runtime: {error}"))?;

  let result = runtime.block_on(async move {
    rest
      .post_json::<_, CreateSessionResponse>("/api/sessions", &request)
      .await
      .into_result()
  });

  match result {
    Ok(_) => Ok(()),
    Err((code, error)) => Err(anyhow::anyhow!(
      "managed session start failed (exit {code}): {}",
      error.message
    )),
  }
}

pub(crate) async fn fork(
  rest: &RestClient,
  output: &Output,
  session_id: &str,
  model: Option<&str>,
) -> i32 {
  let request = ForkSessionRequest {
    model: model.map(str::to_string),
    approval_policy: None,
    sandbox_mode: None,
    cwd: None,
    permission_mode: None,
    allowed_tools: vec![],
    disallowed_tools: vec![],
  };

  match rest
    .post_json::<_, ForkSessionResponse>(
      &format!("/api/sessions/{session_id}/lifecycle/fork"),
      &request,
    )
    .await
    .into_result()
  {
    Ok(resp) => {
      let session = resp.session;
      if output.json {
        output.print_json_pretty(&SessionActionJsonResponse {
          ok: true,
          action: "forked",
          session_id: resp.new_session_id,
          source_session_id: Some(resp.source_session_id),
          summary: session_json_overview_from_summary(&session),
          session,
        });
      } else {
        let bold = console::Style::new().bold();
        println!(
          "{} {} (from {})",
          bold.apply_to("Forked:"),
          resp.new_session_id,
          resp.source_session_id
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

pub(crate) async fn resume(rest: &RestClient, output: &Output, session_id: &str) -> i32 {
  match rest
    .post_json::<_, ResumeSessionResponse>(
      &format!("/api/sessions/{session_id}/lifecycle/resume"),
      &serde_json::json!({}),
    )
    .await
    .into_result()
  {
    Ok(resp) => {
      let session = resp.session;
      if output.json {
        output.print_json_pretty(&SessionActionJsonResponse {
          ok: true,
          action: "resumed",
          session_id: session.id.clone(),
          source_session_id: None,
          summary: session_json_overview_from_summary(&session),
          session,
        });
      } else {
        println!(
          "Session resumed. Status: {}",
          super::presentation::work_status_str(&session.work_status)
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
