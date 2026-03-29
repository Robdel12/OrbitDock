use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn intentionally_ignored_eventmsg_variants() -> BTreeSet<&'static str> {
  BTreeSet::from([
    // Latest Codex emits these, but OrbitDock still safely drops them via the
    // top-level catch-all while we work through feature parity.
    "ImageGenerationBegin",
    "ImageGenerationEnd",
  ])
}

#[test]
fn connector_eventmsg_handlers_match_codex_protocol_variants() {
  let connector_source = connector_source_bundle();
  let connector_variants = parse_connector_eventmsg_variants(connector_source);

  let protocol_path = find_codex_protocol_rs().unwrap_or_else(|| {
    panic!(
      "Failed to locate codex protocol source file. Set ORBITDOCK_CODEX_PROTOCOL_RS \
             to a protocol.rs path if auto-discovery fails."
    )
  });
  let protocol_source = fs::read_to_string(&protocol_path).unwrap_or_else(|err| {
    panic!(
      "Failed to read codex protocol source at {}: {}",
      protocol_path.display(),
      err
    )
  });
  let protocol_variants = parse_protocol_eventmsg_variants(&protocol_source);

  let ignored_variants = intentionally_ignored_eventmsg_variants();

  let missing: Vec<String> = protocol_variants
    .difference(&connector_variants)
    .filter(|name| !ignored_variants.contains(name.as_str()))
    .cloned()
    .collect();
  let extra: Vec<String> = connector_variants
    .difference(&protocol_variants)
    .cloned()
    .collect();

  assert!(
    missing.is_empty() && extra.is_empty(),
    "EventMsg coverage mismatch.\n\
         protocol variants: {}\n\
         connector variants: {}\n\
         ignored by test: {}\n\
         missing in connector: {}\n\
         extra in connector: {}\n\
         protocol source: {}",
    protocol_variants.len(),
    connector_variants.len(),
    ignored_variants
      .iter()
      .copied()
      .collect::<Vec<_>>()
      .join(", "),
    if missing.is_empty() {
      "none".to_string()
    } else {
      missing.join(", ")
    },
    if extra.is_empty() {
      "none".to_string()
    } else {
      extra.join(", ")
    },
    protocol_path.display()
  );
}

#[test]
fn connector_plan_update_emits_tool_row_and_plan_state_update() {
  let source = include_str!("../src/event_mapping/runtime_signals.rs");
  let arm_start = source
    .find("fn handle_plan_update(")
    .expect("missing plan-update handler");
  let arm = &source[arm_start..source.len().min(arm_start + 2400)];

  assert!(
    arm.contains("ConnectorEvent::PlanUpdated(plan)"),
    "PlanUpdate handler must update session plan side-state"
  );
  assert!(
    arm.contains("ConnectorEvent::ConversationRowCreated(tool_row_entry(row))"),
    "PlanUpdate handler must emit a ConversationRowCreated event"
  );
  assert!(
    arm.contains("ToolKind::UpdatePlan"),
    "PlanUpdate timeline row must use ToolKind::UpdatePlan"
  );
}

#[test]
fn connector_hook_events_only_surface_error_runs() {
  let source = include_str!("../src/event_mapping/runtime_signals.rs");

  let started_start = source
    .find("fn handle_hook_started(")
    .expect("missing hook-started handler");
  let started_arm = &source[started_start..source.len().min(started_start + 2200)];
  assert!(
    started_arm.contains("if !hook_run_is_error(event.run.status)"),
    "HookStarted handler must suppress non-error hook runs"
  );
  assert!(
    started_arm.contains("ConnectorEvent::ConversationRowCreated(entry)"),
    "HookStarted handler must still create rows for surfaced failures"
  );

  let completed_start = source
    .find("fn handle_hook_completed(")
    .expect("missing hook-completed handler");
  let completed_arm = &source[completed_start..source.len().min(completed_start + 1800)];
  assert!(
    completed_arm.contains("ConversationRow::Hook(HookRow"),
    "HookCompleted handler must emit Hook rows for surfaced failures"
  );
  assert!(
    completed_arm.contains("ConnectorEvent::ConversationRowCreated(entry)"),
    "HookCompleted handler must create rows for surfaced failures"
  );
}

#[test]
fn connector_question_events_emit_timeline_tool_rows() {
  let source = include_str!("../src/event_mapping/approvals.rs");

  let request_start = source
    .find("fn handle_request_user_input(")
    .expect("missing request-user-input handler");
  let request_arm = &source[request_start..source.len().min(request_start + 2600)];
  assert!(
    request_arm.contains("ToolKind::AskUserQuestion"),
    "RequestUserInput handler must emit AskUserQuestion tool rows"
  );
  assert!(
    request_arm.contains("ConnectorEvent::ConversationRowCreated(tool_row_entry(row))"),
    "RequestUserInput handler must emit a ConversationRowCreated event"
  );
  assert!(
    request_arm.contains("request_id: event_id.to_string()"),
    "RequestUserInput approvals must use event.id (submission id) so Op::UserInputAnswer resolves"
  );

  let elicitation_start = source
    .find("fn handle_elicitation_request(")
    .expect("missing elicitation handler");
  let elicitation_arm = &source[elicitation_start..source.len().min(elicitation_start + 2800)];
  assert!(
    elicitation_arm.contains("ToolFamily::Mcp"),
    "ElicitationRequest handler must emit MCP tool rows"
  );
  assert!(
    elicitation_arm.contains("ConnectorEvent::ConversationRowCreated(tool_row_entry(row))"),
    "ElicitationRequest handler must emit a ConversationRowCreated event"
  );
}

fn connector_source_bundle() -> &'static str {
  concat!(
    include_str!("../src/lib.rs"),
    "\n",
    include_str!("../src/event_mapping/lifecycle.rs"),
    "\n",
    include_str!("../src/event_mapping/messages.rs"),
    "\n",
    include_str!("../src/event_mapping/tools.rs"),
    "\n",
    include_str!("../src/event_mapping/collab.rs"),
    "\n",
    include_str!("../src/event_mapping/approvals.rs"),
    "\n",
    include_str!("../src/event_mapping/capabilities.rs"),
    "\n",
    include_str!("../src/event_mapping/runtime_signals.rs"),
    "\n",
    include_str!("../src/event_mapping/streaming.rs"),
  )
}

fn parse_protocol_eventmsg_variants(source: &str) -> BTreeSet<String> {
  let marker = "pub enum EventMsg {";
  let start = source
    .find(marker)
    .unwrap_or_else(|| panic!("Could not find `pub enum EventMsg` in codex protocol source"));

  let mut variants = BTreeSet::new();
  for line in source[start + marker.len()..].lines() {
    let trimmed = line.trim();
    if trimmed == "}" {
      break;
    }
    if trimmed.is_empty() || trimmed.starts_with("///") || trimmed.starts_with("#[") {
      continue;
    }

    if let Some(name) = leading_identifier(trimmed) {
      variants.insert(name.to_string());
    }
  }

  assert!(
    !variants.is_empty(),
    "Parsed zero EventMsg variants from codex protocol source"
  );
  variants
}

fn parse_connector_eventmsg_variants(source: &str) -> BTreeSet<String> {
  let mut variants = BTreeSet::new();
  let needle = "EventMsg::";
  let mut remaining = source;

  while let Some(idx) = remaining.find(needle) {
    remaining = &remaining[idx + needle.len()..];
    if let Some(name) = leading_identifier(remaining) {
      variants.insert(name.to_string());
    }
  }

  assert!(
    !variants.is_empty(),
    "Parsed zero EventMsg references from connector source"
  );
  variants
}

fn leading_identifier(input: &str) -> Option<&str> {
  let end = input
    .char_indices()
    .take_while(|(_, ch)| ch.is_ascii_alphanumeric() || *ch == '_')
    .last()
    .map(|(i, ch)| i + ch.len_utf8())?;
  Some(&input[..end])
}

fn find_codex_protocol_rs() -> Option<PathBuf> {
  if let Ok(path) = env::var("ORBITDOCK_CODEX_PROTOCOL_RS") {
    let candidate = PathBuf::from(path);
    if candidate.is_file() {
      return Some(candidate);
    }
  }

  if let Some(path) = find_pinned_protocol_in_cargo_home() {
    return Some(path);
  }

  find_protocol_in_cargo_home()
}

fn find_protocol_in_cargo_home() -> Option<PathBuf> {
  let cargo_home = cargo_home_dir()?;
  let checkouts = cargo_home.join("git").join("checkouts");
  if !checkouts.is_dir() {
    return None;
  }

  let repos = fs::read_dir(checkouts).ok()?;
  for repo_entry in repos.flatten() {
    let repo_path = repo_entry.path();
    if !repo_path.is_dir() {
      continue;
    }

    let revs = match fs::read_dir(&repo_path) {
      Ok(entries) => entries,
      Err(_) => continue,
    };

    for rev_entry in revs.flatten() {
      let rev_path = rev_entry.path();
      if !rev_path.is_dir() {
        continue;
      }
      let candidate = rev_path
        .join("codex-rs")
        .join("protocol")
        .join("src")
        .join("protocol.rs");
      if candidate.is_file() {
        return Some(candidate);
      }
    }
  }

  None
}

fn find_pinned_protocol_in_cargo_home() -> Option<PathBuf> {
  let rev = codex_git_revision_from_workspace_lockfile()?;
  let short_rev: String = rev.chars().take(7).collect();

  let cargo_home = cargo_home_dir()?;
  let checkouts = cargo_home.join("git").join("checkouts");
  if !checkouts.is_dir() {
    return None;
  }

  let repos = fs::read_dir(checkouts).ok()?;
  for repo_entry in repos.flatten() {
    let repo_path = repo_entry.path();
    if !repo_path.is_dir() {
      continue;
    }

    let candidate = repo_path
      .join(&short_rev)
      .join("codex-rs")
      .join("protocol")
      .join("src")
      .join("protocol.rs");
    if candidate.is_file() {
      return Some(candidate);
    }
  }

  None
}

fn codex_git_revision_from_workspace_lockfile() -> Option<String> {
  let lockfile = workspace_lockfile_path()?;
  let source = fs::read_to_string(lockfile).ok()?;

  for line in source.lines() {
    let trimmed = line.trim();
    if !trimmed.starts_with("source = \"git+https://github.com/openai/codex?") {
      continue;
    }

    let hash_start = trimmed.rfind('#')?;
    let quoted = trimmed[hash_start + 1..].trim_end_matches('"');
    let rev: String = quoted
      .chars()
      .take_while(|ch| ch.is_ascii_hexdigit())
      .collect();
    if rev.len() >= 7 {
      return Some(rev);
    }
  }

  None
}

fn workspace_lockfile_path() -> Option<PathBuf> {
  let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
  let workspace_root = manifest_dir.parent()?.parent()?;
  Some(workspace_root.join("Cargo.lock"))
}

fn cargo_home_dir() -> Option<PathBuf> {
  if let Ok(path) = env::var("CARGO_HOME") {
    let cargo_home = PathBuf::from(path);
    if cargo_home.is_dir() {
      return Some(cargo_home);
    }
  }

  let home = env::var("HOME").ok()?;
  let default_home = Path::new(&home).join(".cargo");
  if default_home.is_dir() {
    Some(default_home)
  } else {
    None
  }
}
