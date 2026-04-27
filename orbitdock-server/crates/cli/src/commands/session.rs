mod bootstrap;
mod http;
mod live;
mod presentation;
mod watch;

pub use http::run_managed_session_start;
#[cfg(test)]
pub(crate) use presentation::{build_session_list_json_response, session_json_overview_from_state};
#[cfg(test)]
pub(crate) use watch::stream_turn_should_exit;

use crate::cli::{resolve_stdin, SessionAction};
use crate::client::config::ClientConfig;
use crate::client::rest::RestClient;
use crate::output::Output;

pub async fn run(
  action: &SessionAction,
  rest: &RestClient,
  output: &Output,
  config: &ClientConfig,
) -> i32 {
  match action {
    SessionAction::List {
      provider,
      status,
      project,
    } => {
      http::list(
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
    } => http::get(rest, output, session_id, *messages).await,
    SessionAction::Create {
      provider,
      cwd,
      model,
      permission_mode,
      effort,
      system_prompt,
    } => {
      let resolved_cwd = match cwd {
        Some(c) => c.clone(),
        None => std::env::current_dir()
          .map(|p| p.to_string_lossy().to_string())
          .unwrap_or_else(|_| ".".to_string()),
      };
      http::create(http::CreateSessionArgs {
        rest,
        output,
        provider_filter: provider,
        cwd: &resolved_cwd,
        model: model.as_deref(),
        permission_mode: permission_mode.as_ref(),
        effort: effort.as_ref(),
        system_prompt: system_prompt.as_deref(),
      })
      .await
    }
    SessionAction::Send {
      session_id,
      content,
      model,
      effort,
      no_wait,
    } => {
      let resolved = match resolve_stdin(content) {
        Ok(c) => c,
        Err(e) => {
          output.print_error(&crate::error::CliError::new("stdin_error", e.to_string()));
          return crate::error::EXIT_CLIENT_ERROR;
        }
      };
      live::send_message(
        config,
        output,
        session_id,
        &resolved,
        model.as_deref(),
        effort.as_ref(),
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
      live::approve_tool(
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
    } => {
      let resolved = match resolve_stdin(answer) {
        Ok(a) => a,
        Err(e) => {
          output.print_error(&crate::error::CliError::new("stdin_error", e.to_string()));
          return crate::error::EXIT_CLIENT_ERROR;
        }
      };
      live::answer_question(config, output, session_id, &resolved, request_id.as_deref()).await
    }
    SessionAction::Interrupt { session_id } => live::interrupt(config, output, session_id).await,
    SessionAction::End { session_id } => live::end_session(config, output, session_id).await,
    SessionAction::Fork { session_id, model } => {
      http::fork(rest, output, session_id, model.as_deref()).await
    }
    SessionAction::Steer {
      session_id,
      content,
    } => {
      let resolved = match resolve_stdin(content) {
        Ok(c) => c,
        Err(e) => {
          output.print_error(&crate::error::CliError::new("stdin_error", e.to_string()));
          return crate::error::EXIT_CLIENT_ERROR;
        }
      };
      live::steer(config, output, session_id, &resolved).await
    }
    SessionAction::Compact { session_id } => live::compact(config, output, session_id).await,
    SessionAction::Undo { session_id } => live::undo(config, output, session_id).await,
    SessionAction::Rollback { session_id, turns } => {
      live::rollback(config, output, session_id, *turns).await
    }
    SessionAction::Watch {
      session_id,
      filter,
      timeout,
    } => watch::watch(rest, config, output, session_id, filter, *timeout).await,
    SessionAction::Rename { session_id, name } => {
      live::rename(config, output, session_id, name).await
    }
    SessionAction::Resume { session_id } => http::resume(rest, output, session_id).await,
  }
}

#[cfg(test)]
mod tests;
