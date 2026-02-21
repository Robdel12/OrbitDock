//! `orbitdock-server install-hooks` — configure Claude Code hooks.
//!
//! Safely merges OrbitDock hook entries into `~/.claude/settings.json`.

use std::path::{Path, PathBuf};

use crate::paths;

/// All Claude Code hook types we register for.
const HOOK_TYPES: &[(&str, &str)] = &[
    ("hooks.SessionStart", "claude_session_start"),
    ("hooks.SessionEnd", "claude_session_end"),
    ("hooks.UserPromptSubmit", "claude_status_event"),
    ("hooks.Stop", "claude_status_event"),
    ("hooks.Notification", "claude_status_event"),
    ("hooks.PreCompact", "claude_status_event"),
    ("hooks.PreToolUse", "claude_tool_event"),
    ("hooks.PostToolUse", "claude_tool_event"),
    ("hooks.PostToolUseFailure", "claude_tool_event"),
    ("hooks.PermissionRequest", "claude_tool_event"),
    ("hooks.SubagentStart", "claude_subagent_event"),
    ("hooks.SubagentStop", "claude_subagent_event"),
];

pub fn run(settings_path: Option<&Path>) -> anyhow::Result<()> {
    let settings_file = settings_path.map(PathBuf::from).unwrap_or_else(|| {
        dirs::home_dir()
            .expect("HOME not found")
            .join(".claude/settings.json")
    });

    let hook_script = paths::hook_script_path();
    if !hook_script.exists() {
        anyhow::bail!(
            "Hook script not found at {}. Run `orbitdock-server init` first.",
            hook_script.display()
        );
    }

    // Read existing settings or start with empty object
    let existing = if settings_file.exists() {
        let content = std::fs::read_to_string(&settings_file)?;
        serde_json::from_str::<serde_json::Value>(&content)?
    } else {
        serde_json::json!({})
    };

    let mut settings = existing.clone();
    let obj = settings
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("settings.json is not a JSON object"))?;

    let hook_path_str = hook_script.to_string_lossy();
    let mut added = Vec::new();
    let mut updated = Vec::new();

    for &(hook_key, hook_type) in HOOK_TYPES {
        let command = format!("{} {}", hook_path_str, hook_type);

        // Navigate to the nested key (e.g. hooks.SessionStart)
        let parts: Vec<&str> = hook_key.split('.').collect();
        let parent_key = parts[0];
        let child_key = parts[1];

        let hooks_obj = obj
            .entry(parent_key)
            .or_insert_with(|| serde_json::json!({}));
        let hooks_map = hooks_obj
            .as_object_mut()
            .ok_or_else(|| anyhow::anyhow!("settings.json '{}' is not an object", parent_key))?;

        // Claude Code hook format: each array entry wraps hooks in a `hooks` array
        let hook_entry = serde_json::json!({
            "hooks": [{
                "type": "command",
                "command": command,
                "async": true
            }]
        });

        if let Some(existing_hooks) = hooks_map.get_mut(child_key) {
            if let Some(arr) = existing_hooks.as_array_mut() {
                // Check if we already have an OrbitDock hook (could be nested or bare)
                let orbitdock_idx = arr.iter().position(|entry| {
                    // Check nested format: entry.hooks[].command
                    if let Some(hooks_arr) = entry.get("hooks").and_then(|h| h.as_array()) {
                        return hooks_arr.iter().any(|h| {
                            h.get("command")
                                .and_then(|c| c.as_str())
                                .map(|c| c.contains("orbitdock") || c.contains("hook.sh"))
                                .unwrap_or(false)
                        });
                    }
                    // Check bare format (legacy/broken): entry.command
                    entry
                        .get("command")
                        .and_then(|c| c.as_str())
                        .map(|c| c.contains("orbitdock") || c.contains("hook.sh"))
                        .unwrap_or(false)
                });

                if let Some(idx) = orbitdock_idx {
                    arr[idx] = hook_entry;
                    updated.push(hook_key);
                } else {
                    arr.push(hook_entry);
                    added.push(hook_key);
                }
            }
        } else {
            hooks_map.insert(child_key.to_string(), serde_json::json!([hook_entry]));
            added.push(hook_key);
        }
    }

    // Back up original
    if settings_file.exists() {
        let backup = settings_file.with_extension("json.bak");
        std::fs::copy(&settings_file, &backup)?;
        println!(
            "  Backed up {} → {}",
            settings_file.display(),
            backup.display()
        );
    }

    // Ensure parent dir exists
    if let Some(parent) = settings_file.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Write updated settings
    let formatted = serde_json::to_string_pretty(&settings)?;
    std::fs::write(&settings_file, formatted)?;

    println!();
    if !added.is_empty() {
        println!("  Added {} hook(s):", added.len());
        for h in &added {
            println!("    + {}", h);
        }
    }
    if !updated.is_empty() {
        println!("  Updated {} hook(s):", updated.len());
        for h in &updated {
            println!("    ~ {}", h);
        }
    }
    println!();
    println!("  Settings written to {}", settings_file.display());
    println!();

    Ok(())
}
