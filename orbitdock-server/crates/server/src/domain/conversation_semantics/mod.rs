mod codex;
mod shared;

use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent};
use orbitdock_protocol::provider_normalization::shared::ProviderEventEnvelope;
use orbitdock_protocol::Provider;
use tracing::warn;

/// Server-owned semantic upgrading for provider message rows.
///
/// Shared parsing runs first, then provider-specific upgrades can refine or
/// materialize additional rows. Wrapper-like messages that still make it
/// through unchanged are logged here so parser gaps show up in `server.log`.
pub(crate) fn upgrade_row(provider: Provider, row: ConversationRow) -> ConversationRow {
  let original = row.clone();
  let upgraded = match provider {
    Provider::Codex => codex::upgrade_row(shared::upgrade_row(row)),
    Provider::Claude => shared::upgrade_row(row),
  };

  log_unhandled_wrapper(provider, &original, &upgraded);

  upgraded
}

#[allow(dead_code)] // Wired when provider event materialization is turned on for semantic rows.
pub(crate) fn materialize_provider_event(event: ProviderEventEnvelope) -> Vec<ConversationRow> {
  match event.provider {
    Provider::Codex => codex::materialize_provider_event(event),
    Provider::Claude => vec![],
  }
}

fn log_unhandled_wrapper(
  provider: Provider,
  original: &ConversationRow,
  upgraded: &ConversationRow,
) {
  let Some(message) = message_row(original) else {
    return;
  };
  let Some(wrapper_hint) = wrapper_hint(&message.content) else {
    return;
  };
  if is_known_wrapper_hint(&wrapper_hint) {
    return;
  }
  if !message_passthrough_unmodified(original, upgraded) {
    return;
  }

  warn!(
      event = "conversation_semantics.unhandled_wrapper",
      component = "conversation_semantics",
      ?provider,
      row_type = message_row_type(original),
      row_id = %message.id,
      wrapper = wrapper_hint,
      content_preview = content_preview(&message.content),
      "Wrapper-like message passed through semantic parsing unchanged"
  );
}

fn message_row(row: &ConversationRow) -> Option<&MessageRowContent> {
  match row {
    ConversationRow::User(message)
    | ConversationRow::Steer(message)
    | ConversationRow::Assistant(message)
    | ConversationRow::Thinking(message)
    | ConversationRow::System(message) => Some(message),
    _ => None,
  }
}

fn message_passthrough_unmodified(original: &ConversationRow, upgraded: &ConversationRow) -> bool {
  match (message_row(original), message_row(upgraded)) {
    (Some(original), Some(upgraded)) => original.content == upgraded.content,
    _ => false,
  }
}

fn message_row_type(row: &ConversationRow) -> &'static str {
  match row {
    ConversationRow::User(_) => "user",
    ConversationRow::Steer(_) => "steer",
    ConversationRow::Assistant(_) => "assistant",
    ConversationRow::Thinking(_) => "thinking",
    ConversationRow::System(_) => "system",
    ConversationRow::Context(_) => "context",
    ConversationRow::Notice(_) => "notice",
    ConversationRow::ShellCommand(_) => "shell_command",
    ConversationRow::Task(_) => "task",
    ConversationRow::Tool(_) => "tool",
    ConversationRow::ActivityGroup(_) => "activity_group",
    ConversationRow::Question(_) => "question",
    ConversationRow::Approval(_) => "approval",
    ConversationRow::Worker(_) => "worker",
    ConversationRow::Plan(_) => "plan",
    ConversationRow::Hook(_) => "hook",
    ConversationRow::Handoff(_) => "handoff",
  }
}

fn wrapper_hint(content: &str) -> Option<String> {
  let trimmed = content.trim();
  if trimmed.is_empty() {
    return None;
  }

  if trimmed.starts_with("# AGENTS.md instructions for ") && trimmed.contains("<INSTRUCTIONS>") {
    return Some("agents_md_instructions".to_string());
  }

  let start = trimmed.find('<')?;
  let after_start = &trimmed[start + 1..];
  let end = after_start.find('>')?;
  let inner = after_start[..end].trim().trim_start_matches('/').trim();
  if inner.is_empty() {
    return None;
  }

  let candidate = if inner.contains('=') {
    inner.split_whitespace().next().unwrap_or_default()
  } else {
    inner
  };
  let candidate = candidate.trim();
  if candidate.is_empty() {
    return None;
  }
  if candidate
    .chars()
    .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | ' '))
  {
    Some(candidate.replace(' ', "_"))
  } else {
    None
  }
}

fn is_known_wrapper_hint(wrapper_hint: &str) -> bool {
  matches!(wrapper_hint, "collaboration_mode")
}

fn content_preview(content: &str) -> String {
  const MAX_LEN: usize = 160;

  let compact = content.split_whitespace().collect::<Vec<_>>().join(" ");
  let mut preview = compact.chars().take(MAX_LEN).collect::<String>();
  if compact.chars().count() > MAX_LEN {
    preview.push_str("...");
  }
  preview
}

#[cfg(test)]
mod tests {
  use super::{is_known_wrapper_hint, wrapper_hint};

  #[test]
  fn detects_agents_instruction_wrapper_hint() {
    let content =
      "# AGENTS.md instructions for /tmp/project\n\n<INSTRUCTIONS>\nHello\n</INSTRUCTIONS>";
    assert_eq!(
      wrapper_hint(content).as_deref(),
      Some("agents_md_instructions")
    );
  }

  #[test]
  fn detects_closing_tag_wrapper_hint() {
    assert_eq!(
      wrapper_hint("</turn_aborted>").as_deref(),
      Some("turn_aborted")
    );
  }

  #[test]
  fn detects_tag_with_attributes_wrapper_hint() {
    assert_eq!(
      wrapper_hint("<image name=[Image #1]></image>").as_deref(),
      Some("image")
    );
  }

  #[test]
  fn ignores_plain_text_content() {
    assert_eq!(wrapper_hint("Hello there"), None);
  }

  #[test]
  fn ignores_known_collaboration_mode_wrapper_for_logging() {
    assert!(is_known_wrapper_hint("collaboration_mode"));
    assert!(!is_known_wrapper_hint("image"));
  }
}
