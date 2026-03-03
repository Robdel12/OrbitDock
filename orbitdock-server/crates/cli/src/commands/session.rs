use std::time::Duration;

use orbitdock_protocol::{
    ClientMessage, MessageType, Provider, ServerMessage, SessionState, SessionStatus, WorkStatus,
};
use serde::{Deserialize, Serialize};

use crate::cli::{ProviderFilter, SessionAction, StatusFilter};
use crate::client::config::ClientConfig;
use crate::client::rest::RestClient;
use crate::client::ws::WsClient;
use crate::error::{
    CliError, EXIT_CLIENT_ERROR, EXIT_CONNECTION_ERROR, EXIT_SERVER_ERROR, EXIT_SUCCESS,
};
use crate::output::{human, Output};

#[derive(Debug, Deserialize, Serialize)]
struct SessionsResponse {
    sessions: Vec<orbitdock_protocol::SessionSummary>,
}

#[derive(Debug, Deserialize, Serialize)]
struct SessionResponse {
    session: SessionState,
}

pub async fn run(
    action: &SessionAction,
    rest: &RestClient,
    output: &Output,
    config: &ClientConfig,
) -> i32 {
    match action {
        // REST commands
        SessionAction::List {
            provider,
            status,
            project,
        } => {
            list(
                rest,
                output,
                provider.as_ref(),
                status.as_ref(),
                project.as_deref(),
            )
            .await
        }
        SessionAction::Get {
            session_id,
            messages,
        } => get(rest, output, session_id, *messages).await,

        // WS commands
        SessionAction::Create {
            provider,
            cwd,
            model,
            permission_mode,
            effort,
            system_prompt,
        } => {
            create(
                config,
                output,
                provider,
                cwd,
                model.as_deref(),
                permission_mode.as_deref(),
                effort.as_deref(),
                system_prompt.as_deref(),
            )
            .await
        }
        SessionAction::Send {
            session_id,
            content,
            model,
            effort,
            no_wait,
        } => {
            send_message(
                config,
                output,
                session_id,
                content,
                model.as_deref(),
                effort.as_deref(),
                *no_wait,
            )
            .await
        }
        SessionAction::Approve {
            session_id,
            decision,
            message,
            request_id,
        } => {
            approve_tool(
                config,
                output,
                session_id,
                decision,
                message.as_deref(),
                request_id.as_deref(),
            )
            .await
        }
        SessionAction::Answer {
            session_id,
            answer,
            request_id,
        } => answer_question(config, output, session_id, answer, request_id.as_deref()).await,
        SessionAction::Interrupt { session_id } => interrupt(config, output, session_id).await,
        SessionAction::End { session_id } => end_session(config, output, session_id).await,
        SessionAction::Fork {
            session_id,
            nth_user_message,
            model,
        } => {
            fork(
                config,
                output,
                session_id,
                *nth_user_message,
                model.as_deref(),
            )
            .await
        }
        SessionAction::Steer {
            session_id,
            content,
        } => steer(config, output, session_id, content).await,
        SessionAction::Compact { session_id } => compact(config, output, session_id).await,
        SessionAction::Undo { session_id } => undo(config, output, session_id).await,
        SessionAction::Rollback { session_id, turns } => {
            rollback(config, output, session_id, *turns).await
        }
        SessionAction::Watch {
            session_id,
            filter,
            timeout,
        } => watch(config, output, session_id, filter, *timeout).await,
        SessionAction::Rename { session_id, name } => {
            rename(config, output, session_id, name).await
        }
        SessionAction::Resume { session_id } => resume(config, output, session_id).await,
    }
}

// ── Helpers ──────────────────────────────────────────────────

async fn ws_connect(config: &ClientConfig, output: &Output) -> Option<WsClient> {
    match WsClient::connect(config).await {
        Ok(ws) => Some(ws),
        Err(e) => {
            output.print_error(&CliError::connection(e.to_string()));
            None
        }
    }
}

fn pending_request_id(session: &SessionState) -> Option<&str> {
    session.pending_approval.as_ref().map(|req| req.id.as_str())
}

// ── REST Commands ────────────────────────────────────────────

async fn list(
    rest: &RestClient,
    output: &Output,
    provider: Option<&ProviderFilter>,
    status: Option<&StatusFilter>,
    project: Option<&str>,
) -> i32 {
    match rest
        .get::<SessionsResponse>("/api/sessions")
        .await
        .into_result()
    {
        Ok(mut resp) => {
            if let Some(p) = provider {
                let target = match p {
                    ProviderFilter::Claude => Provider::Claude,
                    ProviderFilter::Codex => Provider::Codex,
                };
                resp.sessions.retain(|s| s.provider == target);
            }
            if let Some(s) = status {
                let target = match s {
                    StatusFilter::Active => SessionStatus::Active,
                    StatusFilter::Ended => SessionStatus::Ended,
                };
                resp.sessions.retain(|s| s.status == target);
            }
            if let Some(proj) = project {
                resp.sessions.retain(|s| s.project_path.contains(proj));
            }

            if output.json {
                output.print_json(&resp);
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

async fn get(rest: &RestClient, output: &Output, session_id: &str, messages: bool) -> i32 {
    let path = format!("/api/sessions/{session_id}");
    match rest.get::<SessionResponse>(&path).await.into_result() {
        Ok(mut resp) => {
            if !messages {
                resp.session.messages.clear();
            }
            if output.json {
                output.print_json(&resp);
            } else {
                print_session_detail(&resp.session, messages);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

// ── WS Commands ──────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
async fn create(
    config: &ClientConfig,
    output: &Output,
    provider_filter: &ProviderFilter,
    cwd: &str,
    model: Option<&str>,
    permission_mode: Option<&str>,
    effort: Option<&str>,
    system_prompt: Option<&str>,
) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    let provider = match provider_filter {
        ProviderFilter::Claude => Provider::Claude,
        ProviderFilter::Codex => Provider::Codex,
    };

    if let Err(e) = ws
        .send(&ClientMessage::CreateSession {
            provider,
            cwd: cwd.to_string(),
            model: model.map(str::to_string),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: permission_mode.map(str::to_string),
            allowed_tools: vec![],
            disallowed_tools: vec![],
            effort: effort.map(str::to_string),
            system_prompt: system_prompt.map(str::to_string),
            append_system_prompt: None,
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(30)).await {
            Ok(Some(ServerMessage::SessionSnapshot { session })) => {
                if output.json {
                    output.print_json(&serde_json::json!({
                        "session_id": session.id,
                        "provider": session.provider,
                        "project_path": session.project_path,
                        "status": session.status,
                        "work_status": session.work_status,
                    }));
                } else {
                    let bold = console::Style::new().bold();
                    println!("{} {}", bold.apply_to("Created session:"), session.id);
                    println!("{} {:?}", bold.apply_to("Provider:"), session.provider);
                    println!("{} {}", bold.apply_to("Project:"), session.project_path);
                }
                return EXIT_SUCCESS;
            }
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                output.print_error(&CliError::connection(
                    "Timed out waiting for session creation",
                ));
                return EXIT_CONNECTION_ERROR;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn send_message(
    config: &ClientConfig,
    output: &Output,
    session_id: &str,
    content: &str,
    model: Option<&str>,
    effort: Option<&str>,
    no_wait: bool,
) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws.subscribe_session(session_id).await {
        output.print_error(&CliError::new("subscribe_error", e.to_string()));
        return EXIT_SERVER_ERROR;
    }

    if let Err(e) = ws
        .send(&ClientMessage::SendMessage {
            session_id: session_id.to_string(),
            content: content.to_string(),
            model: model.map(str::to_string),
            effort: effort.map(str::to_string),
            skills: vec![],
            images: vec![],
            mentions: vec![],
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    if no_wait {
        if output.json {
            output.print_json(&serde_json::json!({"sent": true, "session_id": session_id}));
        } else {
            println!("Message sent.");
        }
        return EXIT_SUCCESS;
    }

    stream_turn_events(&mut ws, output).await
}

async fn approve_tool(
    config: &ClientConfig,
    output: &Output,
    session_id: &str,
    decision: &str,
    message: Option<&str>,
    request_id: Option<&str>,
) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    let session = match ws.subscribe_session(session_id).await {
        Ok(s) => s,
        Err(e) => {
            output.print_error(&CliError::new("subscribe_error", e.to_string()));
            return EXIT_SERVER_ERROR;
        }
    };

    let resolved_id = match request_id {
        Some(id) => id.to_string(),
        None => match pending_request_id(&session) {
            Some(id) => id.to_string(),
            None => {
                output.print_error(&CliError::new(
                    "no_pending_approval",
                    "No pending approval. Use --request-id to specify one.",
                ));
                return EXIT_CLIENT_ERROR;
            }
        },
    };

    if let Err(e) = ws
        .send(&ClientMessage::ApproveTool {
            session_id: session_id.to_string(),
            request_id: resolved_id.clone(),
            decision: decision.to_string(),
            message: message.map(str::to_string),
            interrupt: None,
            updated_input: None,
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(10)).await {
            Ok(Some(ServerMessage::ApprovalDecisionResult {
                ref request_id,
                ref outcome,
                ..
            })) if *request_id == resolved_id => {
                if output.json {
                    output.print_json(&serde_json::json!({
                        "request_id": request_id,
                        "outcome": outcome,
                    }));
                } else {
                    let bold = console::Style::new().bold();
                    println!(
                        "{} {} ({})",
                        bold.apply_to("Approval:"),
                        outcome,
                        request_id
                    );
                }
                return EXIT_SUCCESS;
            }
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                output.print_error(&CliError::connection(
                    "Timed out waiting for approval result",
                ));
                return EXIT_CONNECTION_ERROR;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

async fn answer_question(
    config: &ClientConfig,
    output: &Output,
    session_id: &str,
    answer: &str,
    request_id: Option<&str>,
) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    let session = match ws.subscribe_session(session_id).await {
        Ok(s) => s,
        Err(e) => {
            output.print_error(&CliError::new("subscribe_error", e.to_string()));
            return EXIT_SERVER_ERROR;
        }
    };

    let resolved_id = match request_id {
        Some(id) => id.to_string(),
        None => match pending_request_id(&session) {
            Some(id) => id.to_string(),
            None => {
                output.print_error(&CliError::new(
                    "no_pending_question",
                    "No pending question. Use --request-id to specify one.",
                ));
                return EXIT_CLIENT_ERROR;
            }
        },
    };

    if let Err(e) = ws
        .send(&ClientMessage::AnswerQuestion {
            session_id: session_id.to_string(),
            request_id: resolved_id.clone(),
            answer: answer.to_string(),
            question_id: None,
            answers: None,
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(10)).await {
            Ok(Some(ServerMessage::ApprovalDecisionResult {
                ref request_id,
                ref outcome,
                ..
            })) if *request_id == resolved_id => {
                if output.json {
                    output.print_json(&serde_json::json!({
                        "request_id": request_id,
                        "outcome": outcome,
                    }));
                } else {
                    println!("Answer submitted ({outcome})");
                }
                return EXIT_SUCCESS;
            }
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                output.print_error(&CliError::connection("Timed out"));
                return EXIT_CONNECTION_ERROR;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

async fn interrupt(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws.subscribe_session(session_id).await {
        output.print_error(&CliError::new("subscribe_error", e.to_string()));
        return EXIT_SERVER_ERROR;
    }

    if let Err(e) = ws
        .send(&ClientMessage::InterruptSession {
            session_id: session_id.to_string(),
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(5)).await {
            Ok(Some(ServerMessage::SessionDelta { changes, .. })) => {
                if let Some(ref status) = changes.work_status {
                    if *status != WorkStatus::Working {
                        if output.json {
                            output.print_json(
                                &serde_json::json!({"interrupted": true, "work_status": status}),
                            );
                        } else {
                            println!("Session interrupted. Status: {status:?}");
                        }
                        return EXIT_SUCCESS;
                    }
                }
            }
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                if output.json {
                    output.print_json(&serde_json::json!({"interrupted": true}));
                } else {
                    println!("Interrupt sent.");
                }
                return EXIT_SUCCESS;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

async fn end_session(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws
        .send(&ClientMessage::EndSession {
            session_id: session_id.to_string(),
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(10)).await {
            Ok(Some(ServerMessage::SessionEnded { reason, .. })) => {
                if output.json {
                    output.print_json(&serde_json::json!({"ended": true, "reason": reason}));
                } else {
                    println!("Session ended: {reason}");
                }
                return EXIT_SUCCESS;
            }
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                if output.json {
                    output.print_json(&serde_json::json!({"ended": true}));
                } else {
                    println!("End request sent.");
                }
                return EXIT_SUCCESS;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

async fn fork(
    config: &ClientConfig,
    output: &Output,
    session_id: &str,
    nth_user_message: Option<u32>,
    model: Option<&str>,
) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws
        .send(&ClientMessage::ForkSession {
            source_session_id: session_id.to_string(),
            nth_user_message,
            model: model.map(str::to_string),
            approval_policy: None,
            sandbox_mode: None,
            cwd: None,
            permission_mode: None,
            allowed_tools: vec![],
            disallowed_tools: vec![],
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(30)).await {
            Ok(Some(ServerMessage::SessionForked {
                new_session_id,
                source_session_id,
                ..
            })) => {
                if output.json {
                    output.print_json(&serde_json::json!({
                        "forked": true,
                        "source_session_id": source_session_id,
                        "new_session_id": new_session_id,
                    }));
                } else {
                    let bold = console::Style::new().bold();
                    println!(
                        "{} {} (from {source_session_id})",
                        bold.apply_to("Forked:"),
                        new_session_id,
                    );
                }
                return EXIT_SUCCESS;
            }
            Ok(Some(ServerMessage::SessionSnapshot { session })) => {
                if output.json {
                    output.print_json(&serde_json::json!({
                        "forked": true,
                        "new_session_id": session.id,
                    }));
                } else {
                    let bold = console::Style::new().bold();
                    println!("{} {}", bold.apply_to("Forked session:"), session.id);
                }
                return EXIT_SUCCESS;
            }
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                output.print_error(&CliError::connection("Timed out waiting for fork"));
                return EXIT_CONNECTION_ERROR;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

async fn steer(config: &ClientConfig, output: &Output, session_id: &str, content: &str) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws.subscribe_session(session_id).await {
        output.print_error(&CliError::new("subscribe_error", e.to_string()));
        return EXIT_SERVER_ERROR;
    }

    if let Err(e) = ws
        .send(&ClientMessage::SteerTurn {
            session_id: session_id.to_string(),
            content: content.to_string(),
            images: vec![],
            mentions: vec![],
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    if output.json {
        output.print_json(&serde_json::json!({"steered": true, "session_id": session_id}));
    } else {
        println!("Guidance injected.");
    }
    EXIT_SUCCESS
}

async fn compact(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws.subscribe_session(session_id).await {
        output.print_error(&CliError::new("subscribe_error", e.to_string()));
        return EXIT_SERVER_ERROR;
    }

    if let Err(e) = ws
        .send(&ClientMessage::CompactContext {
            session_id: session_id.to_string(),
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(60)).await {
            Ok(Some(ServerMessage::ContextCompacted { .. })) => {
                if output.json {
                    output.print_json(&serde_json::json!({"compacted": true}));
                } else {
                    println!("Context compacted.");
                }
                return EXIT_SUCCESS;
            }
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                output.print_error(&CliError::connection("Timed out waiting for compaction"));
                return EXIT_CONNECTION_ERROR;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

async fn undo(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws.subscribe_session(session_id).await {
        output.print_error(&CliError::new("subscribe_error", e.to_string()));
        return EXIT_SERVER_ERROR;
    }

    if let Err(e) = ws
        .send(&ClientMessage::UndoLastTurn {
            session_id: session_id.to_string(),
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(30)).await {
            Ok(Some(ServerMessage::UndoCompleted {
                success, message, ..
            })) => {
                if output.json {
                    output.print_json(&serde_json::json!({"undone": success, "message": message}));
                } else if success {
                    println!(
                        "Undo complete.{}",
                        message.map(|m| format!(" {m}")).unwrap_or_default()
                    );
                } else {
                    eprintln!(
                        "Undo failed.{}",
                        message.map(|m| format!(" {m}")).unwrap_or_default()
                    );
                }
                return if success {
                    EXIT_SUCCESS
                } else {
                    EXIT_SERVER_ERROR
                };
            }
            Ok(Some(ServerMessage::UndoStarted { .. })) => continue,
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                output.print_error(&CliError::connection("Timed out waiting for undo"));
                return EXIT_CONNECTION_ERROR;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

async fn rollback(config: &ClientConfig, output: &Output, session_id: &str, turns: u32) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws.subscribe_session(session_id).await {
        output.print_error(&CliError::new("subscribe_error", e.to_string()));
        return EXIT_SERVER_ERROR;
    }

    if let Err(e) = ws
        .send(&ClientMessage::RollbackTurns {
            session_id: session_id.to_string(),
            num_turns: turns,
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(30)).await {
            Ok(Some(ServerMessage::ThreadRolledBack { num_turns, .. })) => {
                if output.json {
                    output.print_json(&serde_json::json!({"rolled_back": num_turns}));
                } else {
                    println!("Rolled back {num_turns} turn(s).");
                }
                return EXIT_SUCCESS;
            }
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                output.print_error(&CliError::connection("Timed out"));
                return EXIT_CONNECTION_ERROR;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

async fn watch(
    config: &ClientConfig,
    output: &Output,
    session_id: &str,
    filter: &[String],
    timeout_secs: Option<u64>,
) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    let session = match ws.subscribe_session(session_id).await {
        Ok(s) => s,
        Err(e) => {
            output.print_error(&CliError::new("subscribe_error", e.to_string()));
            return EXIT_SERVER_ERROR;
        }
    };

    if output.json {
        println!(
            "{}",
            serde_json::to_string(&ServerMessage::SessionSnapshot {
                session: session.clone()
            })
            .unwrap_or_default()
        );
    } else {
        let bold = console::Style::new().bold();
        println!(
            "{} {} ({:?} / {:?})",
            bold.apply_to("Watching:"),
            session_id,
            session.status,
            session.work_status
        );
        println!("Press Ctrl+C to stop.\n");
    }

    let timeout = timeout_secs
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(3600));

    loop {
        match ws.recv_timeout(timeout).await {
            Ok(Some(ref msg)) => {
                if !filter.is_empty() {
                    let event_type = event_type_name(msg);
                    if !filter.iter().any(|f| event_type.contains(f.as_str())) {
                        continue;
                    }
                }

                if output.json {
                    println!("{}", serde_json::to_string(msg).unwrap_or_default());
                } else {
                    print_watch_event(msg);
                }

                if matches!(msg, ServerMessage::SessionEnded { .. }) {
                    return EXIT_SUCCESS;
                }
            }
            Ok(None) => {
                if !output.json {
                    println!("\nConnection closed.");
                }
                return EXIT_SUCCESS;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

async fn rename(config: &ClientConfig, output: &Output, session_id: &str, name: &str) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws
        .send(&ClientMessage::RenameSession {
            session_id: session_id.to_string(),
            name: Some(name.to_string()),
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    match ws.recv_timeout(Duration::from_secs(5)).await {
        Ok(Some(ServerMessage::Error { code, message, .. })) => {
            output.print_error(&CliError::new(code, message));
            return EXIT_SERVER_ERROR;
        }
        Err(e) => {
            output.print_error(&CliError::connection(e.to_string()));
            return EXIT_CONNECTION_ERROR;
        }
        _ => {}
    }

    if output.json {
        output.print_json(&serde_json::json!({"renamed": true, "name": name}));
    } else {
        println!("Session renamed to: {name}");
    }
    EXIT_SUCCESS
}

async fn resume(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
    let Some(mut ws) = ws_connect(config, output).await else {
        return EXIT_CONNECTION_ERROR;
    };

    if let Err(e) = ws
        .send(&ClientMessage::ResumeSession {
            session_id: session_id.to_string(),
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    loop {
        match ws.recv_timeout(Duration::from_secs(30)).await {
            Ok(Some(ServerMessage::SessionSnapshot { session })) => {
                if output.json {
                    output.print_json(&serde_json::json!({
                        "resumed": true,
                        "session_id": session.id,
                        "work_status": session.work_status,
                    }));
                } else {
                    println!("Session resumed. Status: {:?}", session.work_status);
                }
                return EXIT_SUCCESS;
            }
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                if output.json {
                    output.print_json(&serde_json::json!({"resumed": true}));
                } else {
                    println!("Resume request sent.");
                }
                return EXIT_SUCCESS;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

// ── Streaming Helpers ────────────────────────────────────────

async fn stream_turn_events(ws: &mut WsClient, output: &Output) -> i32 {
    let timeout = Duration::from_secs(300);

    loop {
        match ws.recv_timeout(timeout).await {
            Ok(Some(ref msg)) => {
                if output.json {
                    println!("{}", serde_json::to_string(msg).unwrap_or_default());
                }
                match msg {
                    ServerMessage::MessageAppended { message, .. } => {
                        if !output.json && !message.content.is_empty() {
                            let role = format_role(message.message_type);
                            println!("[{role}] {}", message.content);
                        }
                    }
                    ServerMessage::ApprovalRequested { request, .. } => {
                        if !output.json {
                            let tool = request.tool_name.as_deref().unwrap_or("unknown");
                            let preview = request
                                .command
                                .as_deref()
                                .or(request.tool_input.as_deref())
                                .unwrap_or("(see request)");
                            println!("\nApproval needed: {tool} — {preview}");
                        }
                        return EXIT_SUCCESS;
                    }
                    ServerMessage::SessionDelta { changes, .. } => {
                        if let Some(status) = &changes.work_status {
                            match status {
                                WorkStatus::Working | WorkStatus::Waiting => {}
                                _ => {
                                    if !output.json {
                                        println!("\nTurn complete. Status: {status:?}");
                                    }
                                    return EXIT_SUCCESS;
                                }
                            }
                        }
                    }
                    ServerMessage::SessionEnded { reason, .. } => {
                        if !output.json {
                            println!("Session ended: {reason}");
                        }
                        return EXIT_SUCCESS;
                    }
                    ServerMessage::Error { code, message, .. } => {
                        output.print_error(&CliError::new(code.clone(), message.clone()));
                        return EXIT_SERVER_ERROR;
                    }
                    _ => {}
                }
            }
            Ok(None) => {
                if !output.json {
                    eprintln!("Connection closed or timed out.");
                }
                return EXIT_CONNECTION_ERROR;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}

fn format_role(msg_type: MessageType) -> &'static str {
    match msg_type {
        MessageType::User => "user",
        MessageType::Assistant => "assistant",
        MessageType::Tool => "tool",
        MessageType::ToolResult => "tool-result",
        _ => "system",
    }
}

fn event_type_name(msg: &ServerMessage) -> &'static str {
    match msg {
        ServerMessage::SessionsList { .. } => "sessions_list",
        ServerMessage::SessionSnapshot { .. } => "session_snapshot",
        ServerMessage::SessionDelta { .. } => "session_delta",
        ServerMessage::MessageAppended { .. } => "message_appended",
        ServerMessage::MessageUpdated { .. } => "message_updated",
        ServerMessage::ApprovalRequested { .. } => "approval_requested",
        ServerMessage::TokensUpdated { .. } => "tokens_updated",
        ServerMessage::SessionCreated { .. } => "session_created",
        ServerMessage::SessionEnded { .. } => "session_ended",
        ServerMessage::SessionForked { .. } => "session_forked",
        ServerMessage::ApprovalDecisionResult { .. } => "approval_decision_result",
        ServerMessage::ContextCompacted { .. } => "context_compacted",
        ServerMessage::UndoStarted { .. } => "undo_started",
        ServerMessage::UndoCompleted { .. } => "undo_completed",
        ServerMessage::ThreadRolledBack { .. } => "thread_rolled_back",
        ServerMessage::ShellStarted { .. } => "shell_started",
        ServerMessage::ShellOutput { .. } => "shell_output",
        ServerMessage::TurnDiffSnapshot { .. } => "turn_diff_snapshot",
        ServerMessage::RateLimitEvent { .. } => "rate_limit_event",
        ServerMessage::PromptSuggestion { .. } => "prompt_suggestion",
        ServerMessage::Error { .. } => "error",
        _ => "other",
    }
}

fn print_watch_event(msg: &ServerMessage) {
    let dim = console::Style::new().dim();
    let bold = console::Style::new().bold();

    match msg {
        ServerMessage::SessionDelta { changes, .. } => {
            if let Some(status) = &changes.work_status {
                println!("{} work_status -> {status:?}", dim.apply_to("delta"));
            }
            if let Some(Some(name)) = &changes.custom_name {
                println!("{} name -> {name}", dim.apply_to("delta"));
            }
            if let Some(Some(summary)) = &changes.summary {
                println!("{} summary -> {summary}", dim.apply_to("delta"));
            }
        }
        ServerMessage::MessageAppended { message, .. } => {
            let role = format_role(message.message_type);
            let content = if message.content.len() > 120 {
                format!("{}...", &message.content[..117])
            } else {
                message.content.clone()
            };
            println!("{} [{role}] {content}", bold.apply_to("+msg"));
        }
        ServerMessage::ApprovalRequested { request, .. } => {
            let coral = console::Style::new().red().bold();
            println!(
                "{} {} — {}",
                coral.apply_to("approval"),
                request.tool_name.as_deref().unwrap_or("unknown"),
                request.id
            );
        }
        ServerMessage::ApprovalDecisionResult {
            outcome,
            request_id,
            ..
        } => {
            println!("{} {outcome} ({request_id})", dim.apply_to("decision"));
        }
        ServerMessage::TokensUpdated { usage, .. } => {
            let fill = usage.context_fill_percent();
            println!(
                "{} {fill:.0}% ({} in / {} out)",
                dim.apply_to("tokens"),
                usage.input_tokens,
                usage.output_tokens
            );
        }
        ServerMessage::SessionEnded { reason, .. } => {
            println!("{} {reason}", bold.apply_to("ended"));
        }
        ServerMessage::ContextCompacted { .. } => {
            println!("{}", dim.apply_to("context compacted"));
        }
        ServerMessage::UndoCompleted { success, .. } => {
            println!("{} success={success}", dim.apply_to("undo"));
        }
        ServerMessage::ShellStarted { command, .. } => {
            println!("{} {command}", bold.apply_to("shell"));
        }
        ServerMessage::ShellOutput {
            stdout,
            stderr,
            exit_code,
            ..
        } => {
            if !stdout.is_empty() {
                print!("{stdout}");
            }
            if !stderr.is_empty() {
                eprint!("{stderr}");
            }
            if let Some(code) = exit_code {
                println!("{} exit {code}", dim.apply_to("shell"));
            }
        }
        ServerMessage::Error { code, message, .. } => {
            let red = console::Style::new().red();
            println!("{} [{code}] {message}", red.apply_to("error"));
        }
        _ => {
            println!("{} {}", dim.apply_to("event"), event_type_name(msg));
        }
    }
}

// ── Human Output ─────────────────────────────────────────────

fn print_session_detail(session: &SessionState, show_messages: bool) {
    let bold = console::Style::new().bold();

    println!("{} {}", bold.apply_to("Session:"), session.id);
    println!("{} {:?}", bold.apply_to("Provider:"), session.provider);
    println!("{} {}", bold.apply_to("Project:"), session.project_path);
    println!(
        "{} {:?} / {:?}",
        bold.apply_to("Status:"),
        session.status,
        session.work_status
    );

    if let Some(ref model) = session.model {
        println!("{} {}", bold.apply_to("Model:"), model);
    }
    if let Some(ref name) = session.custom_name {
        println!("{} {}", bold.apply_to("Name:"), name);
    }
    if let Some(ref summary) = session.summary {
        println!("{} {}", bold.apply_to("Summary:"), summary);
    }
    if let Some(ref branch) = session.git_branch {
        println!("{} {}", bold.apply_to("Branch:"), branch);
    }

    let usage = &session.token_usage;
    if usage.context_window > 0 {
        let fill = usage.context_fill_percent();
        println!(
            "{} {:.0}% ({} in / {} out / {} cached / {} window)",
            bold.apply_to("Context:"),
            fill,
            usage.input_tokens,
            usage.output_tokens,
            usage.cached_tokens,
            usage.context_window,
        );
    }

    if show_messages && !session.messages.is_empty() {
        println!("\n{}", bold.apply_to("Messages:"));
        for msg in &session.messages {
            let role_style = match msg.message_type {
                MessageType::User => console::Style::new().cyan().bold(),
                MessageType::Assistant => console::Style::new().green(),
                MessageType::Tool | MessageType::ToolResult => console::Style::new().yellow(),
                _ => console::Style::new().dim(),
            };

            let role = format!("{:?}", msg.message_type).to_lowercase();
            let content_preview = if msg.content.len() > 200 {
                format!("{}...", &msg.content[..197])
            } else {
                msg.content.clone()
            };

            println!(
                "  {} {}",
                role_style.apply_to(format!("[{role}]")),
                content_preview
            );
        }
    }
}
