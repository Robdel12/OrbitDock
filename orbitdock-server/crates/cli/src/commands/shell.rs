use std::time::Duration;

use orbitdock_protocol::{ClientMessage, ServerMessage};

use crate::cli::ShellAction;
use crate::client::config::ClientConfig;
use crate::client::ws::WsClient;
use crate::error::{
    CliError, EXIT_CLIENT_ERROR, EXIT_CONNECTION_ERROR, EXIT_SERVER_ERROR, EXIT_SUCCESS,
};
use crate::output::Output;

pub async fn run(action: &ShellAction, output: &Output, config: &ClientConfig) -> i32 {
    match action {
        ShellAction::Exec {
            session_id,
            command,
            cwd,
            timeout,
        } => {
            exec(
                config,
                output,
                session_id,
                command,
                cwd.as_deref(),
                *timeout,
            )
            .await
        }
    }
}

async fn exec(
    config: &ClientConfig,
    output: &Output,
    session_id: &str,
    command: &str,
    cwd: Option<&str>,
    timeout_secs: u64,
) -> i32 {
    let mut ws = match WsClient::connect(config).await {
        Ok(ws) => ws,
        Err(e) => {
            output.print_error(&CliError::connection(e.to_string()));
            return EXIT_CONNECTION_ERROR;
        }
    };

    if let Err(e) = ws.subscribe_session(session_id).await {
        output.print_error(&CliError::new("subscribe_error", e.to_string()));
        return EXIT_SERVER_ERROR;
    }

    if let Err(e) = ws
        .send(&ClientMessage::ExecuteShell {
            session_id: session_id.to_string(),
            command: command.to_string(),
            cwd: cwd.map(str::to_string),
            timeout_secs,
        })
        .await
    {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
    }

    // Wait for shell_started + shell_output
    let wait_timeout = Duration::from_secs(timeout_secs + 5);

    loop {
        match ws.recv_timeout(wait_timeout).await {
            Ok(Some(ServerMessage::ShellOutput {
                stdout,
                stderr,
                exit_code,
                duration_ms,
                outcome,
                ..
            })) => {
                if output.json {
                    output.print_json(&serde_json::json!({
                        "stdout": stdout,
                        "stderr": stderr,
                        "exit_code": exit_code,
                        "duration_ms": duration_ms,
                        "outcome": outcome,
                    }));
                } else {
                    if !stdout.is_empty() {
                        print!("{stdout}");
                    }
                    if !stderr.is_empty() {
                        eprint!("{stderr}");
                    }
                }
                return match exit_code {
                    Some(0) => EXIT_SUCCESS,
                    Some(_) => EXIT_CLIENT_ERROR,
                    None => EXIT_SUCCESS,
                };
            }
            Ok(Some(ServerMessage::ShellStarted { .. })) => continue,
            Ok(Some(ServerMessage::Error { code, message, .. })) => {
                output.print_error(&CliError::new(code, message));
                return EXIT_SERVER_ERROR;
            }
            Ok(Some(_)) => continue,
            Ok(None) => {
                output.print_error(&CliError::connection("Timed out waiting for shell output"));
                return EXIT_CONNECTION_ERROR;
            }
            Err(e) => {
                output.print_error(&CliError::connection(e.to_string()));
                return EXIT_CONNECTION_ERROR;
            }
        }
    }
}
