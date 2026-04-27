use orbitdock_protocol::{
  ClaudeUsageSnapshot, CodexRateLimitReachedType, CodexUsageSnapshot, UsageErrorInfo,
};
use serde::{Deserialize, Serialize};

use crate::cli::{ProviderFilter, UsageAction};
use crate::client::rest::RestClient;
use crate::error::{CliError, EXIT_SUCCESS};
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct CodexUsageResponse {
  usage: Option<CodexUsageSnapshot>,
  error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ClaudeUsageResponse {
  usage: Option<ClaudeUsageSnapshot>,
  error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
struct UsageProviderSummary {
  provider: &'static str,
  available: bool,
  has_error_info: bool,
}

#[derive(Debug, Serialize)]
struct UsageJsonResponse {
  kind: &'static str,
  #[serde(skip_serializing_if = "Option::is_none")]
  requested_provider: Option<&'static str>,
  #[serde(skip_serializing_if = "Option::is_none")]
  codex: Option<CodexUsageResponse>,
  #[serde(skip_serializing_if = "Option::is_none")]
  claude: Option<ClaudeUsageResponse>,
  summaries: Vec<UsageProviderSummary>,
}

pub async fn run(action: &UsageAction, rest: &RestClient, output: &Output) -> i32 {
  match action {
    UsageAction::Show { provider } => show(rest, output, provider.as_ref()).await,
  }
}

async fn show(rest: &RestClient, output: &Output, provider: Option<&ProviderFilter>) -> i32 {
  if output.json {
    return show_json(rest, output, provider).await;
  }

  match provider {
    Some(ProviderFilter::Codex) => show_codex(rest, output).await,
    Some(ProviderFilter::Claude) => show_claude(rest, output).await,
    None => {
      let c1 = show_codex(rest, output).await;
      println!();
      let c2 = show_claude(rest, output).await;
      std::cmp::max(c1, c2)
    }
  }
}

fn provider_str(provider: &ProviderFilter) -> &'static str {
  match provider {
    ProviderFilter::Codex => "codex",
    ProviderFilter::Claude => "claude",
  }
}

fn build_usage_json_response(
  requested_provider: Option<&ProviderFilter>,
  codex: Option<CodexUsageResponse>,
  claude: Option<ClaudeUsageResponse>,
) -> UsageJsonResponse {
  let mut summaries = Vec::new();
  if let Some(ref codex_resp) = codex {
    summaries.push(UsageProviderSummary {
      provider: "codex",
      available: codex_resp.usage.is_some(),
      has_error_info: codex_resp.error_info.is_some(),
    });
  }
  if let Some(ref claude_resp) = claude {
    summaries.push(UsageProviderSummary {
      provider: "claude",
      available: claude_resp.usage.is_some(),
      has_error_info: claude_resp.error_info.is_some(),
    });
  }

  UsageJsonResponse {
    kind: "usage",
    requested_provider: requested_provider.map(provider_str),
    codex,
    claude,
    summaries,
  }
}

async fn show_json(rest: &RestClient, output: &Output, provider: Option<&ProviderFilter>) -> i32 {
  match provider {
    Some(ProviderFilter::Codex) => match fetch_codex_usage(rest).await {
      Ok(resp) => {
        output.print_json_pretty(&build_usage_json_response(provider, Some(resp), None));
        EXIT_SUCCESS
      }
      Err((code, err)) => {
        output.print_error(&err);
        code
      }
    },
    Some(ProviderFilter::Claude) => match fetch_claude_usage(rest).await {
      Ok(resp) => {
        output.print_json_pretty(&build_usage_json_response(provider, None, Some(resp)));
        EXIT_SUCCESS
      }
      Err((code, err)) => {
        output.print_error(&err);
        code
      }
    },
    None => {
      let codex = match fetch_codex_usage(rest).await {
        Ok(resp) => resp,
        Err((code, err)) => {
          output.print_error(&err);
          return code;
        }
      };
      let claude = match fetch_claude_usage(rest).await {
        Ok(resp) => resp,
        Err((code, err)) => {
          output.print_error(&err);
          return code;
        }
      };
      output.print_json_pretty(&build_usage_json_response(None, Some(codex), Some(claude)));
      EXIT_SUCCESS
    }
  }
}

async fn fetch_codex_usage(rest: &RestClient) -> Result<CodexUsageResponse, (i32, CliError)> {
  rest
    .get::<CodexUsageResponse>("/api/usage/codex")
    .await
    .into_result()
}

async fn fetch_claude_usage(rest: &RestClient) -> Result<ClaudeUsageResponse, (i32, CliError)> {
  rest
    .get::<ClaudeUsageResponse>("/api/usage/claude")
    .await
    .into_result()
}

async fn show_codex(rest: &RestClient, output: &Output) -> i32 {
  match fetch_codex_usage(rest).await {
    Ok(resp) => {
      if let Some(ref usage) = resp.usage {
        println!("Codex Usage:");
        if let Some(ref primary) = usage.primary {
          println!(
            "  Primary: {:.1}% used (resets in {}m)",
            primary.used_percent, primary.window_duration_mins
          );
        }
        if let Some(ref secondary) = usage.secondary {
          println!(
            "  Secondary: {:.1}% used (resets in {}m)",
            secondary.used_percent, secondary.window_duration_mins
          );
        }
        if let Some(reason) = usage.rate_limit_reached_type {
          println!("  Limit reason: {}", codex_limit_reason_label(reason));
        }
      } else if let Some(ref info) = resp.error_info {
        eprintln!("Codex usage unavailable: {}", info.message);
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

fn codex_limit_reason_label(reason: CodexRateLimitReachedType) -> &'static str {
  match reason {
    CodexRateLimitReachedType::RateLimitReached => "rate limit reached",
    CodexRateLimitReachedType::WorkspaceOwnerCreditsDepleted => "workspace owner credits depleted",
    CodexRateLimitReachedType::WorkspaceMemberCreditsDepleted => {
      "workspace member credits depleted"
    }
    CodexRateLimitReachedType::WorkspaceOwnerUsageLimitReached => {
      "workspace owner usage limit reached"
    }
    CodexRateLimitReachedType::WorkspaceMemberUsageLimitReached => {
      "workspace member usage limit reached"
    }
  }
}

async fn show_claude(rest: &RestClient, output: &Output) -> i32 {
  match fetch_claude_usage(rest).await {
    Ok(resp) => {
      if let Some(ref usage) = resp.usage {
        println!("Claude Usage:");
        println!("  5h window: {:.1}%", usage.five_hour.utilization * 100.0);
        if let Some(ref seven) = usage.seven_day {
          println!("  7d window: {:.1}%", seven.utilization * 100.0);
        }
        if let Some(ref tier) = usage.rate_limit_tier {
          println!("  Tier: {tier}");
        }
      } else if let Some(ref info) = resp.error_info {
        eprintln!("Claude usage unavailable: {}", info.message);
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

#[cfg(test)]
mod tests;
