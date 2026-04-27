pub fn name_from_first_prompt(prompt: &str) -> Option<String> {
  let normalized = prompt.split_whitespace().collect::<Vec<_>>().join(" ");
  if normalized.is_empty() || is_bootstrap_prompt(&normalized) {
    return None;
  }

  let max_chars = 72;
  let mut out = String::new();
  for ch in normalized.chars().take(max_chars) {
    out.push(ch);
  }
  if normalized.chars().count() > max_chars {
    out.push('…');
  }
  Some(out)
}

fn is_bootstrap_prompt(message: &str) -> bool {
  let lower = message.to_ascii_lowercase();
  lower.contains("<environment_context>")
    || lower.contains("<permissions instructions>")
    || lower.contains("<collaboration_mode>")
    || lower.contains("<skill>")
    || lower.contains("<turn_aborted>")
    || lower.contains("the user interrupted the previous turn on purpose")
    || lower.contains("agents.md instructions for")
}

#[cfg(test)]
#[path = "session_naming_tests.rs"]
mod session_naming_tests;
