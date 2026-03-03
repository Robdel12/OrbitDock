use serde::{Deserialize, Serialize};

use crate::cli::ServerAction;
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct HealthResponse {
    status: String,
    #[serde(default)]
    version: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ServerRoleResponse {
    is_primary: bool,
}

#[derive(Debug, Serialize)]
struct SetServerRoleRequest {
    is_primary: bool,
}

pub async fn run(action: &ServerAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        ServerAction::Status => status(rest, output).await,
        ServerAction::Role { primary, secondary } => {
            if *primary {
                set_role(rest, output, true).await
            } else if *secondary {
                set_role(rest, output, false).await
            } else {
                // Show current role — not available via REST, just show health
                status(rest, output).await
            }
        }
    }
}

async fn status(rest: &RestClient, output: &Output) -> i32 {
    match rest.get::<HealthResponse>("/health").await.into_result() {
        Ok(health) => {
            if output.json {
                output.print_json(&health);
            } else {
                let version = health.version.as_deref().unwrap_or("unknown");
                let style = console::Style::new().green().bold();
                println!(
                    "{} Server status: {} (version: {})",
                    style.apply_to("●"),
                    health.status,
                    version
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

async fn set_role(rest: &RestClient, output: &Output, is_primary: bool) -> i32 {
    let body = SetServerRoleRequest { is_primary };
    match rest
        .put_json::<_, ServerRoleResponse>("/api/server/role", &body)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                let role = if resp.is_primary {
                    "primary"
                } else {
                    "secondary"
                };
                println!("Server role set to: {role}");
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}
