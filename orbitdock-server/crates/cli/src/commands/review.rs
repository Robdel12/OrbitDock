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

#[derive(Debug, Serialize)]
struct ReviewCommentsJsonResponse {
  kind: &'static str,
  session_id: String,
  count: usize,
  comments: Vec<ReviewComment>,
}

#[derive(Debug, Serialize)]
struct ReviewCommentActionJsonResponse {
  ok: bool,
  action: &'static str,
  comment_id: String,
}

fn review_tag_label(tag: &orbitdock_protocol::ReviewCommentTag) -> &'static str {
  match tag {
    orbitdock_protocol::ReviewCommentTag::Clarity => "clarity",
    orbitdock_protocol::ReviewCommentTag::Scope => "scope",
    orbitdock_protocol::ReviewCommentTag::Risk => "risk",
    orbitdock_protocol::ReviewCommentTag::Nit => "nit",
  }
}

fn review_status_label(status: &orbitdock_protocol::ReviewCommentStatus) -> &'static str {
  match status {
    orbitdock_protocol::ReviewCommentStatus::Open => "open",
    orbitdock_protocol::ReviewCommentStatus::Resolved => "resolved",
  }
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
      create(CreateReviewArgs {
        rest,
        output,
        session_id,
        file,
        line: *line,
        line_end: *line_end,
        body,
        tag: tag.as_ref(),
        turn: turn.as_deref(),
      })
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
    Some(t) => format!("/api/sessions/{session_id}/review/comments?turn_id={t}"),
    None => format!("/api/sessions/{session_id}/review/comments"),
  };

  match rest
    .get::<ReviewCommentsResponse>(&path)
    .await
    .into_result()
  {
    Ok(resp) => {
      if output.json {
        output.print_json_pretty(&ReviewCommentsJsonResponse {
          kind: "review_comments",
          session_id: resp.session_id,
          count: resp.comments.len(),
          comments: resp.comments,
        });
      } else if resp.comments.is_empty() {
        println!("No review comments.");
      } else {
        println!("Review comments ({}):", resp.comments.len());
        for c in &resp.comments {
          let tag = c
            .tag
            .as_ref()
            .map(|t| format!("[{}] ", review_tag_label(t)))
            .unwrap_or_default();
          let line_end = c
            .line_end
            .map(|line_end| format!("-L{line_end}"))
            .unwrap_or_default();
          println!(
            "  {} [{}] {}{}:L{}{} — {}",
            c.id,
            review_status_label(&c.status),
            tag,
            c.file_path,
            c.line_start,
            line_end,
            c.body
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

struct CreateReviewArgs<'a> {
  rest: &'a RestClient,
  output: &'a Output,
  session_id: &'a str,
  file: &'a str,
  line: u32,
  line_end: Option<u32>,
  body: &'a str,
  tag: Option<&'a ReviewTagFilter>,
  turn: Option<&'a str>,
}

async fn create(args: CreateReviewArgs<'_>) -> i32 {
  let CreateReviewArgs {
    rest,
    output,
    session_id,
    file,
    line,
    line_end,
    body,
    tag,
    turn,
  } = args;

  let tag_str = tag.map(ReviewTagFilter::as_str);

  let req = CreateReviewCommentRequest {
    turn_id: turn.map(|s| s.to_string()),
    file_path: file.to_string(),
    line_start: line,
    line_end,
    body: body.to_string(),
    tag: tag_str.map(|s| s.to_string()),
  };

  let path = format!("/api/sessions/{session_id}/review/comments");
  match rest
    .post_json::<_, ReviewCommentMutationResponse>(&path, &req)
    .await
    .into_result()
  {
    Ok(resp) => {
      if output.json {
        output.print_json_pretty(&ReviewCommentActionJsonResponse {
          ok: resp.ok,
          action: "created",
          comment_id: resp.comment_id,
        });
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
  let tag_str = tag.map(|t| t.as_str().to_string());
  let status_str = status.map(|s| s.as_str().to_string());

  let req = UpdateReviewCommentRequest {
    body: body.map(|s| s.to_string()),
    tag: tag_str,
    status: status_str,
  };

  let path = format!("/api/review/comments/{comment_id}");
  match rest
    .patch_json::<_, ReviewCommentMutationResponse>(&path, &req)
    .await
    .into_result()
  {
    Ok(resp) => {
      if output.json {
        output.print_json_pretty(&ReviewCommentActionJsonResponse {
          ok: resp.ok,
          action: "updated",
          comment_id: resp.comment_id,
        });
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
  let path = format!("/api/review/comments/{comment_id}");
  match rest
    .delete::<ReviewCommentMutationResponse>(&path)
    .await
    .into_result()
  {
    Ok(resp) => {
      if output.json {
        output.print_json_pretty(&ReviewCommentActionJsonResponse {
          ok: resp.ok,
          action: "deleted",
          comment_id: resp.comment_id,
        });
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
