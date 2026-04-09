use std::path::{Path, PathBuf};
use std::process::Stdio;

const CODEX_PATH_SENTINEL: &str = "__ORBITDOCK_PATH__";

pub(crate) fn find_codex_binary() -> Option<PathBuf> {
  if let Ok(value) = std::env::var("ORBITDOCK_CODEX_PATH") {
    let path = PathBuf::from(value);
    if is_executable_file(&path) {
      return Some(path);
    }
  }

  for path in [
    "/usr/local/bin/codex",
    "/opt/homebrew/bin/codex",
    "/usr/bin/codex",
    "/bin/codex",
  ] {
    let candidate = PathBuf::from(path);
    if is_executable_file(&candidate) {
      return Some(candidate);
    }
  }

  for directory in resolve_path_entries() {
    let candidate = directory.join("codex");
    if is_executable_file(&candidate) {
      return Some(candidate);
    }
  }

  None
}

fn is_executable_file(path: &Path) -> bool {
  path.is_file()
}

pub(crate) fn resolved_path_env_for_binary(binary_path: &Path) -> Option<String> {
  let mut entries = Vec::new();
  if let Some(parent) = binary_path.parent() {
    entries.push(parent.to_string_lossy().to_string());
  }
  for path in resolve_path_entries() {
    entries.push(path.to_string_lossy().to_string());
  }
  dedup_non_empty(entries)
}

fn resolve_path_entries() -> Vec<PathBuf> {
  let mut entries = Vec::new();
  if let Some(env_path) = std::env::var_os("PATH") {
    entries.extend(std::env::split_paths(&env_path));
  }
  if let Some(shell_path) = probe_login_shell_path() {
    entries.extend(std::env::split_paths(&shell_path));
  }
  entries
}

fn probe_login_shell_path() -> Option<String> {
  let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
  let command = format!("printf '{}%s\\n' \"$PATH\"", CODEX_PATH_SENTINEL);

  for args in [
    vec!["-ilc".to_string(), command.clone()],
    vec!["-lc".to_string(), command.clone()],
    vec!["-c".to_string(), command.clone()],
  ] {
    let output = match std::process::Command::new(&shell)
      .args(args)
      .stderr(Stdio::null())
      .output()
    {
      Ok(output) => output,
      Err(_) => continue,
    };
    if !output.status.success() {
      continue;
    }
    let text = match String::from_utf8(output.stdout) {
      Ok(text) => text,
      Err(_) => continue,
    };
    if let Some(path) = extract_probe_path(&text) {
      return Some(path);
    }
  }
  None
}

fn extract_probe_path(output: &str) -> Option<String> {
  output
    .lines()
    .find_map(|line| line.strip_prefix(CODEX_PATH_SENTINEL))
    .map(str::to_string)
}

fn dedup_non_empty(entries: Vec<String>) -> Option<String> {
  let mut deduped = Vec::new();
  for entry in entries {
    let trimmed = entry.trim();
    if trimmed.is_empty() {
      continue;
    }
    if deduped.iter().any(|existing| existing == trimmed) {
      continue;
    }
    deduped.push(trimmed.to_string());
  }

  if deduped.is_empty() {
    None
  } else {
    Some(deduped.join(":"))
  }
}
