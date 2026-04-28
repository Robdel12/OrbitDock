use reqwest::{Client, Response};

use super::models::GraphQLResponse;

pub(super) fn check_rate_limit(resp: &Response) -> anyhow::Result<()> {
  let headers = resp.headers();

  let remaining = headers
    .get("x-ratelimit-remaining")
    .and_then(|v| v.to_str().ok())
    .and_then(|v| v.parse::<u64>().ok());

  let reset = headers
    .get("x-ratelimit-reset")
    .and_then(|v| v.to_str().ok())
    .and_then(|v| v.parse::<u64>().ok());

  if let Some(rem) = remaining {
    if rem < 10 {
      tracing::warn!(
        component = "github",
        remaining = rem,
        reset_epoch = reset.unwrap_or(0),
        "GitHub API rate limit nearly exhausted"
      );
    }
  }

  if resp.status() == reqwest::StatusCode::FORBIDDEN {
    if let Some(rem) = remaining {
      if rem == 0 {
        let reset_msg = reset
          .map(|r| format!(" (resets at epoch {r})"))
          .unwrap_or_default();
        anyhow::bail!("GitHub API rate limit exceeded — 0 requests remaining{reset_msg}");
      }
    }
  }

  Ok(())
}

async fn send_json_request(
  http: &Client,
  token: &str,
  method: reqwest::Method,
  url: &str,
  body: serde_json::Value,
) -> anyhow::Result<Response> {
  let resp = http
    .request(method, url)
    .header("Authorization", format!("Bearer {}", token))
    .header("User-Agent", "OrbitDock")
    .header("Accept", "application/vnd.github+json")
    .json(&body)
    .send()
    .await?;

  check_rate_limit(&resp)?;
  Ok(resp)
}

pub(super) async fn graphql<T: serde::de::DeserializeOwned>(
  http: &Client,
  token: &str,
  query: &str,
  variables: serde_json::Value,
) -> anyhow::Result<T> {
  let body = serde_json::json!({
    "query": query,
    "variables": variables,
  });

  let resp = http
    .post("https://api.github.com/graphql")
    .header("Authorization", format!("Bearer {}", token))
    .header("User-Agent", "OrbitDock")
    .header("Content-Type", "application/json")
    .json(&body)
    .send()
    .await?;

  check_rate_limit(&resp)?;

  let status = resp.status();
  if !status.is_success() {
    let text = resp.text().await.unwrap_or_default();
    anyhow::bail!("GitHub API returned {status}: {text}");
  }

  let gql: GraphQLResponse<T> = resp.json().await?;

  if let Some(data) = gql.data {
    if let Some(ref errors) = gql.errors {
      let msgs: Vec<_> = errors.iter().map(|e| e.message.as_str()).collect();
      tracing::debug!(
        component = "github",
        errors = %msgs.join("; "),
        "GraphQL partial errors (data still returned)"
      );
    }
    return Ok(data);
  }

  if let Some(errors) = gql.errors {
    let msgs: Vec<_> = errors.iter().map(|e| e.message.as_str()).collect();
    anyhow::bail!("GitHub GraphQL errors: {}", msgs.join("; "));
  }

  anyhow::bail!("GitHub response contained no data")
}

pub(super) async fn rest_post_json(
  http: &Client,
  token: &str,
  url: &str,
  body: serde_json::Value,
) -> anyhow::Result<()> {
  let resp = send_json_request(http, token, reqwest::Method::POST, url, body).await?;

  let status = resp.status();
  if !status.is_success() {
    let text = resp.text().await.unwrap_or_default();
    anyhow::bail!("GitHub REST API returned {status}: {text}");
  }

  Ok(())
}

pub(super) async fn rest_patch_json(
  http: &Client,
  token: &str,
  url: &str,
  body: serde_json::Value,
) -> anyhow::Result<()> {
  let resp = send_json_request(http, token, reqwest::Method::PATCH, url, body).await?;

  let status = resp.status();
  if !status.is_success() {
    let text = resp.text().await.unwrap_or_default();
    anyhow::bail!("GitHub REST API returned {status}: {text}");
  }

  Ok(())
}
