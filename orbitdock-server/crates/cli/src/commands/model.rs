use orbitdock_protocol::{ClaudeModelOption, CodexModelOption};
use serde::{Deserialize, Serialize};

use crate::cli::{ModelAction, ProviderFilter};
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct CodexModelsResponse {
    models: Vec<CodexModelOption>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ClaudeModelsResponse {
    models: Vec<ClaudeModelOption>,
}

#[derive(Debug, Serialize)]
struct CombinedModelsResponse {
    codex: Vec<CodexModelOption>,
    claude: Vec<ClaudeModelOption>,
}

pub async fn run(action: &ModelAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        ModelAction::List { provider } => list(rest, output, provider.as_ref()).await,
    }
}

async fn list(rest: &RestClient, output: &Output, provider: Option<&ProviderFilter>) -> i32 {
    match provider {
        Some(ProviderFilter::Codex) => list_codex(rest, output).await,
        Some(ProviderFilter::Claude) => list_claude(rest, output).await,
        None => list_both(rest, output).await,
    }
}

async fn list_codex(rest: &RestClient, output: &Output) -> i32 {
    match rest
        .get::<CodexModelsResponse>("/api/models/codex")
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("Codex Models:");
                for m in &resp.models {
                    let default_marker = if m.is_default { " (default)" } else { "" };
                    println!("  {} - {}{}", m.id, m.display_name, default_marker);
                    if !m.description.is_empty() {
                        println!("    {}", m.description);
                    }
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

async fn list_claude(rest: &RestClient, output: &Output) -> i32 {
    match rest
        .get::<ClaudeModelsResponse>("/api/models/claude")
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("Claude Models:");
                for m in &resp.models {
                    println!("  {} - {}", m.value, m.display_name);
                    if !m.description.is_empty() {
                        println!("    {}", m.description);
                    }
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

async fn list_both(rest: &RestClient, output: &Output) -> i32 {
    let codex = rest.get::<CodexModelsResponse>("/api/models/codex").await;
    let claude = rest.get::<ClaudeModelsResponse>("/api/models/claude").await;

    let codex_models = match codex.into_result() {
        Ok(r) => r.models,
        Err((code, err)) => {
            output.print_error(&err);
            return code;
        }
    };

    let claude_models = match claude.into_result() {
        Ok(r) => r.models,
        Err((code, err)) => {
            output.print_error(&err);
            return code;
        }
    };

    if output.json {
        output.print_json(&CombinedModelsResponse {
            codex: codex_models,
            claude: claude_models,
        });
    } else {
        println!("Codex Models:");
        for m in &codex_models {
            let default_marker = if m.is_default { " (default)" } else { "" };
            println!("  {} - {}{}", m.id, m.display_name, default_marker);
        }
        println!("\nClaude Models:");
        for m in &claude_models {
            println!("  {} - {}", m.value, m.display_name);
        }
    }
    EXIT_SUCCESS
}
