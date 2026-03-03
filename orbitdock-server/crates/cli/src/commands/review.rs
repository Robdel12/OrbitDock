use orbitdock_protocol::ReviewComment;
use serde::{Deserialize, Serialize};

use crate::cli::{ReviewAction, ReviewStatusFilter, ReviewTagFilter};
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct ReviewCommentsResponse {
    session_id: String,
    comments: Vec<ReviewComment>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ReviewCommentMutationResponse {
    comment_id: String,
    ok: bool,
}

#[derive(Debug, Serialize)]
struct CreateReviewCommentRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    turn_id: Option<String>,
    file_path: String,
    line_start: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    line_end: Option<u32>,
    body: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    tag: Option<String>,
}

#[derive(Debug, Serialize)]
struct UpdateReviewCommentRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    body: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tag: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<String>,
}

pub async fn run(action: &ReviewAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        ReviewAction::List { session_id, turn } => {
            list(rest, output, session_id, turn.as_deref()).await
        }
        ReviewAction::Create {
            session_id,
            file,
            line,
            line_end,
            body,
            tag,
            turn,
        } => {
            create(
                rest,
                output,
                session_id,
                file,
                *line,
                *line_end,
                body,
                tag.as_ref(),
                turn.as_deref(),
            )
            .await
        }
        ReviewAction::Update {
            comment_id,
            body,
            tag,
            status,
        } => {
            update(
                rest,
                output,
                comment_id,
                body.as_deref(),
                tag.as_ref(),
                status.as_ref(),
            )
            .await
        }
        ReviewAction::Delete { comment_id } => delete(rest, output, comment_id).await,
    }
}

async fn list(rest: &RestClient, output: &Output, session_id: &str, turn: Option<&str>) -> i32 {
    let path = match turn {
        Some(t) => format!("/api/sessions/{session_id}/review-comments?turn_id={t}"),
        None => format!("/api/sessions/{session_id}/review-comments"),
    };

    match rest
        .get::<ReviewCommentsResponse>(&path)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else if resp.comments.is_empty() {
                println!("No review comments.");
            } else {
                for c in &resp.comments {
                    let tag = c
                        .tag
                        .as_ref()
                        .map(|t| format!("[{t:?}] "))
                        .unwrap_or_default();
                    println!(
                        "  {} {}{}:L{} — {}",
                        c.id, tag, c.file_path, c.line_start, c.body
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

#[allow(clippy::too_many_arguments)]
async fn create(
    rest: &RestClient,
    output: &Output,
    session_id: &str,
    file: &str,
    line: u32,
    line_end: Option<u32>,
    body: &str,
    tag: Option<&ReviewTagFilter>,
    turn: Option<&str>,
) -> i32 {
    let tag_str = tag.map(|t| match t {
        ReviewTagFilter::Clarity => "clarity",
        ReviewTagFilter::Scope => "scope",
        ReviewTagFilter::Risk => "risk",
        ReviewTagFilter::Nit => "nit",
    });

    let req = CreateReviewCommentRequest {
        turn_id: turn.map(|s| s.to_string()),
        file_path: file.to_string(),
        line_start: line,
        line_end,
        body: body.to_string(),
        tag: tag_str.map(|s| s.to_string()),
    };

    let path = format!("/api/sessions/{session_id}/review-comments");
    match rest
        .post_json::<_, ReviewCommentMutationResponse>(&path, &req)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("Created review comment: {}", resp.comment_id);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

async fn update(
    rest: &RestClient,
    output: &Output,
    comment_id: &str,
    body: Option<&str>,
    tag: Option<&ReviewTagFilter>,
    status: Option<&ReviewStatusFilter>,
) -> i32 {
    let tag_str = tag.map(|t| match t {
        ReviewTagFilter::Clarity => "clarity".to_string(),
        ReviewTagFilter::Scope => "scope".to_string(),
        ReviewTagFilter::Risk => "risk".to_string(),
        ReviewTagFilter::Nit => "nit".to_string(),
    });
    let status_str = status.map(|s| match s {
        ReviewStatusFilter::Open => "open".to_string(),
        ReviewStatusFilter::Resolved => "resolved".to_string(),
    });

    let req = UpdateReviewCommentRequest {
        body: body.map(|s| s.to_string()),
        tag: tag_str,
        status: status_str,
    };

    let path = format!("/api/review-comments/{comment_id}");
    match rest
        .post_json::<_, ReviewCommentMutationResponse>(&path, &req)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("Updated review comment: {}", resp.comment_id);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

async fn delete(rest: &RestClient, output: &Output, comment_id: &str) -> i32 {
    let path = format!("/api/review-comments/{comment_id}");
    match rest
        .delete::<ReviewCommentMutationResponse>(&path)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("Deleted review comment: {}", resp.comment_id);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}
