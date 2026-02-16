//! AI-powered session naming via OpenAI API.
//!
//! Generates concise 3-7 word names from first user prompts.
//! Fire-and-forget: failures silently fall back to first_prompt display.

use std::collections::HashSet;
use std::sync::Mutex;

use orbitdock_protocol::{ServerMessage, StateChanges};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::persistence::PersistCommand;
use crate::session_actor::SessionActorHandle;
use crate::session_command::SessionCommand;

/// Dedup guard — ensures each session is only named once per server lifetime.
pub struct NamingGuard {
    claimed: Mutex<HashSet<String>>,
}

impl NamingGuard {
    pub fn new() -> Self {
        Self {
            claimed: Mutex::new(HashSet::new()),
        }
    }

    /// Try to claim naming rights for a session. Returns true if this is the first claim.
    pub fn try_claim(&self, session_id: &str) -> bool {
        self.claimed.lock().unwrap().insert(session_id.to_string())
    }
}

/// Resolve the OpenAI API key from env var or macOS Keychain.
fn resolve_api_key() -> Option<String> {
    // Check env var first
    if let Ok(key) = std::env::var("OPENAI_API_KEY") {
        if !key.is_empty() {
            return Some(key);
        }
    }

    // Fall back to macOS Keychain
    let output = std::process::Command::new("security")
        .args([
            "find-generic-password",
            "-s",
            "com.orbitdock.openai-api-key",
            "-w",
        ])
        .output()
        .ok()?;

    if output.status.success() {
        let key = String::from_utf8(output.stdout).ok()?.trim().to_string();
        if !key.is_empty() {
            return Some(key);
        }
    }

    None
}

/// Returns true if the prompt is a bootstrap/system prompt that shouldn't be named.
fn is_bootstrap_prompt(prompt: &str) -> bool {
    // Delegate to session_naming's existing bootstrap detection
    crate::session_naming::name_from_first_prompt(prompt).is_none()
}

/// Spawn a fire-and-forget task to generate an AI name for a session.
pub fn spawn_naming_task(
    session_id: String,
    first_prompt: String,
    actor: SessionActorHandle,
    persist_tx: mpsc::Sender<PersistCommand>,
) {
    tokio::spawn(async move {
        if is_bootstrap_prompt(&first_prompt) {
            return;
        }

        // Check if session already has a summary
        let snap = actor.snapshot();
        if snap.summary.is_some() {
            return;
        }

        let api_key = match resolve_api_key() {
            Some(key) => key,
            None => {
                warn!(
                    session_id = %session_id,
                    "No OpenAI API key found for AI naming (set OPENAI_API_KEY or add to Keychain)"
                );
                return;
            }
        };

        match generate_name(&api_key, &first_prompt).await {
            Ok(name) => {
                info!(
                    session_id = %session_id,
                    name = %name,
                    "AI-generated session name"
                );

                // Broadcast summary delta to UI
                let changes = StateChanges {
                    summary: Some(Some(name.clone())),
                    ..Default::default()
                };
                let _ = actor
                    .send(SessionCommand::ApplyDelta {
                        changes,
                        persist_op: None,
                    })
                    .await;

                // Also broadcast to list subscribers via session actor
                let summary_msg = ServerMessage::SessionDelta {
                    session_id: session_id.clone(),
                    changes: StateChanges {
                        summary: Some(Some(name.clone())),
                        ..Default::default()
                    },
                };
                let _ = actor
                    .send(SessionCommand::Broadcast { msg: summary_msg })
                    .await;

                // Persist to DB
                let _ = persist_tx
                    .send(PersistCommand::SetSummary {
                        session_id,
                        summary: name,
                    })
                    .await;
            }
            Err(e) => {
                warn!(
                    session_id = %session_id,
                    error = %e,
                    "Failed to generate AI session name"
                );
            }
        }
    });
}

/// Call OpenAI API to generate a session name.
async fn generate_name(api_key: &str, prompt: &str) -> Result<String, anyhow::Error> {
    let truncated = if prompt.len() > 500 {
        &prompt[..500]
    } else {
        prompt
    };

    let body = serde_json::json!({
        "model": "gpt-4.1-mini",
        "max_tokens": 30,
        "temperature": 0.3,
        "messages": [
            {
                "role": "system",
                "content": "You name coding sessions. Given a user's first message to an AI coding assistant, produce a concise 3-7 word name. Reply with ONLY the name, no quotes or punctuation."
            },
            {
                "role": "user",
                "content": truncated
            }
        ]
    });

    let client = reqwest::Client::new();

    // First attempt
    let result = call_openai(&client, api_key, &body).await;
    match result {
        Ok(name) => Ok(name),
        Err(e) => {
            // Retry once on 429 (rate limit)
            if e.to_string().contains("429") {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                call_openai(&client, api_key, &body).await
            } else {
                Err(e)
            }
        }
    }
}

async fn call_openai(
    client: &reqwest::Client,
    api_key: &str,
    body: &serde_json::Value,
) -> Result<String, anyhow::Error> {
    let resp = client
        .post("https://api.openai.com/v1/chat/completions")
        .header("Authorization", format!("Bearer {}", api_key))
        .json(body)
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("OpenAI API error {}: {}", status, text);
    }

    let json: serde_json::Value = resp.json().await?;
    let name = json["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or("")
        .trim()
        .trim_matches('"')
        .to_string();

    if name.is_empty() {
        anyhow::bail!("Empty name from OpenAI API");
    }

    Ok(name)
}
