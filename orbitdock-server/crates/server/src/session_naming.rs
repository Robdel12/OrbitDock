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
    message.contains("<environment_context>")
        || message.contains("<permissions instructions>")
        || message.contains("AGENTS.md instructions for")
}

#[cfg(test)]
mod tests {
    use super::name_from_first_prompt;

    #[test]
    fn filters_bootstrap_prompt_messages() {
        assert!(name_from_first_prompt("# AGENTS.md instructions for /tmp/repo").is_none());
        assert!(name_from_first_prompt("<environment_context>...</environment_context>").is_none());
        assert!(
            name_from_first_prompt("<permissions instructions>...</permissions instructions>")
                .is_none()
        );
        assert_eq!(
            name_from_first_prompt("Fix naming in rollout watcher").as_deref(),
            Some("Fix naming in rollout watcher")
        );
    }

    #[test]
    fn truncates_and_normalizes_prompt() {
        let prompt =
            "  Please investigate auth race conditions and propose a safe migration plan.  ";
        let name = name_from_first_prompt(prompt).expect("expected name");
        assert_eq!(
            name,
            "Please investigate auth race conditions and propose a safe migration pla…"
        );
    }
}
