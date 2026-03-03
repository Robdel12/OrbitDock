use orbitdock_protocol::CodexAccountStatus;
use serde::{Deserialize, Serialize};

use crate::cli::CodexAction;
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct CodexAccountResponse {
    status: CodexAccountStatus,
}

#[derive(Debug, Deserialize, Serialize)]
struct CodexLoginStartedResponse {
    login_id: String,
    auth_url: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct CodexLogoutResponse {
    status: CodexAccountStatus,
}

pub async fn run(action: &CodexAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        CodexAction::Account => account(rest, output).await,
        CodexAction::Login => login(rest, output).await,
        CodexAction::Logout => logout(rest, output).await,
    }
}

async fn account(rest: &RestClient, output: &Output) -> i32 {
    match rest
        .get::<CodexAccountResponse>("/api/codex/account")
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("Codex Account: {:?}", resp.status);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

async fn login(rest: &RestClient, output: &Output) -> i32 {
    // Empty body for POST
    let body = serde_json::json!({});
    match rest
        .post_json::<_, CodexLoginStartedResponse>("/api/codex/login/start", &body)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("Login started. Open this URL to authenticate:");
                println!("  {}", resp.auth_url);
                println!("\nLogin ID: {}", resp.login_id);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

async fn logout(rest: &RestClient, output: &Output) -> i32 {
    let body = serde_json::json!({});
    match rest
        .post_json::<_, CodexLogoutResponse>("/api/codex/logout", &body)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("Logged out. Status: {:?}", resp.status);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}
