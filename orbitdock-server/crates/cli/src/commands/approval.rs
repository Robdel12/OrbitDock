use orbitdock_protocol::ApprovalHistoryItem;
use serde::{Deserialize, Serialize};

use crate::cli::ApprovalAction;
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::{human, Output};

#[derive(Debug, Deserialize, Serialize)]
struct ApprovalsResponse {
    session_id: Option<String>,
    approvals: Vec<ApprovalHistoryItem>,
}

#[derive(Debug, Deserialize, Serialize)]
struct DeleteApprovalResponse {
    approval_id: i64,
    deleted: bool,
}

pub async fn run(action: &ApprovalAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        ApprovalAction::List { session, limit } => {
            list(rest, output, session.as_deref(), *limit).await
        }
        ApprovalAction::Delete { approval_id } => delete(rest, output, *approval_id).await,
    }
}

async fn list(
    rest: &RestClient,
    output: &Output,
    session: Option<&str>,
    limit: Option<u32>,
) -> i32 {
    let mut query_parts = Vec::new();
    if let Some(s) = session {
        query_parts.push(format!("session_id={s}"));
    }
    if let Some(l) = limit {
        query_parts.push(format!("limit={l}"));
    }

    let path = if query_parts.is_empty() {
        "/api/approvals".to_string()
    } else {
        format!("/api/approvals?{}", query_parts.join("&"))
    };

    match rest.get::<ApprovalsResponse>(&path).await.into_result() {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                human::approvals_table(&resp.approvals);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

async fn delete(rest: &RestClient, output: &Output, approval_id: i64) -> i32 {
    let path = format!("/api/approvals/{approval_id}");
    match rest
        .delete::<DeleteApprovalResponse>(&path)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else if resp.deleted {
                println!("Approval {} deleted.", approval_id);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}
