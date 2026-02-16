//! Shared git utilities for resolving branch/repo info from a working directory.

use std::process::Stdio;
use tokio::process::Command;

/// Resolve just the git branch from a working directory.
pub async fn resolve_git_branch(path: &str) -> Option<String> {
    run_git(&["rev-parse", "--abbrev-ref", "HEAD"], path).await
}

async fn run_git(args: &[&str], cwd: &str) -> Option<String> {
    let output = Command::new("/usr/bin/git")
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let text = String::from_utf8(output.stdout).ok()?;
    let text = text.trim();
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}
