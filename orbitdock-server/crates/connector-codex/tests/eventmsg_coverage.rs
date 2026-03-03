use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

#[test]
fn connector_eventmsg_handlers_match_codex_protocol_variants() {
    let connector_source = include_str!("../src/lib.rs");
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

    let missing: Vec<String> = protocol_variants
        .difference(&connector_variants)
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
         missing in connector: {}\n\
         extra in connector: {}\n\
         protocol source: {}",
        protocol_variants.len(),
        connector_variants.len(),
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
fn connector_plan_update_emits_tool_message_and_plan_state_update() {
    let source = include_str!("../src/lib.rs");
    let arm_start = source
        .find("EventMsg::PlanUpdate(e) => {")
        .expect("missing EventMsg::PlanUpdate handler");
    let arm = &source[arm_start..source.len().min(arm_start + 2400)];

    assert!(
        arm.contains("ConnectorEvent::PlanUpdated(plan)"),
        "PlanUpdate handler must update session plan side-state"
    );
    assert!(
        arm.contains("ConnectorEvent::MessageCreated(message)"),
        "PlanUpdate handler must emit a timeline tool message"
    );
    assert!(
        arm.contains("tool_name: Some(\"update_plan\".to_string())"),
        "PlanUpdate timeline message must use canonical tool name `update_plan`"
    );
}

#[test]
fn connector_question_events_emit_timeline_tool_messages() {
    let source = include_str!("../src/lib.rs");

    let request_start = source
        .find("EventMsg::RequestUserInput(e) => {")
        .expect("missing EventMsg::RequestUserInput handler");
    let request_arm = &source[request_start..source.len().min(request_start + 2600)];
    assert!(
        request_arm.contains("tool_name: Some(\"askuserquestion\".to_string())"),
        "RequestUserInput handler must emit askuserquestion tool rows"
    );
    assert!(
        request_arm.contains("ConnectorEvent::MessageCreated(message)"),
        "RequestUserInput handler must emit a timeline message"
    );
    assert!(
        request_arm.contains("request_id: event.id.clone()"),
        "RequestUserInput approvals must use event.id (submission id) so Op::UserInputAnswer resolves"
    );

    let elicitation_start = source
        .find("EventMsg::ElicitationRequest(e) => {")
        .expect("missing EventMsg::ElicitationRequest handler");
    let elicitation_arm = &source[elicitation_start..source.len().min(elicitation_start + 2800)];
    assert!(
        elicitation_arm.contains("tool_name: Some(\"mcp_approval\".to_string())"),
        "ElicitationRequest handler must emit mcp_approval tool rows"
    );
    assert!(
        elicitation_arm.contains("ConnectorEvent::MessageCreated(message)"),
        "ElicitationRequest handler must emit a timeline message"
    );
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

    if let Some(path) = local_openai_codex_protocol_path() {
        return Some(path);
    }

    find_protocol_in_cargo_home()
}

fn local_openai_codex_protocol_path() -> Option<PathBuf> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let orbitdock_root = manifest_dir.parent()?.parent()?.parent()?;
    let candidate = orbitdock_root
        .parent()?
        .join("openai-codex")
        .join("codex-rs")
        .join("protocol")
        .join("src")
        .join("protocol.rs");
    if candidate.is_file() {
        Some(candidate)
    } else {
        None
    }
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
