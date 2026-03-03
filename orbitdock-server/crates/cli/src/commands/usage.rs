use orbitdock_protocol::{ClaudeUsageSnapshot, CodexUsageSnapshot, UsageErrorInfo};
use serde::{Deserialize, Serialize};

use crate::cli::{ProviderFilter, UsageAction};
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
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

pub async fn run(action: &UsageAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        UsageAction::Show { provider } => show(rest, output, provider.as_ref()).await,
    }
}

async fn show(rest: &RestClient, output: &Output, provider: Option<&ProviderFilter>) -> i32 {
    match provider {
        Some(ProviderFilter::Codex) => show_codex(rest, output).await,
        Some(ProviderFilter::Claude) => show_claude(rest, output).await,
        None => {
            let c1 = show_codex(rest, output).await;
            if !output.json {
                println!();
            }
            let c2 = show_claude(rest, output).await;
            std::cmp::max(c1, c2)
        }
    }
}

async fn show_codex(rest: &RestClient, output: &Output) -> i32 {
    match rest
        .get::<CodexUsageResponse>("/api/usage/codex")
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else if let Some(ref usage) = resp.usage {
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

async fn show_claude(rest: &RestClient, output: &Output) -> i32 {
    match rest
        .get::<ClaudeUsageResponse>("/api/usage/claude")
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else if let Some(ref usage) = resp.usage {
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
