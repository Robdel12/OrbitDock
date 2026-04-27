use super::name_from_first_prompt;

#[test]
fn filters_bootstrap_prompt_messages() {
  assert!(name_from_first_prompt("# AGENTS.md instructions for /tmp/repo").is_none());
  assert!(name_from_first_prompt("<environment_context>...</environment_context>").is_none());
  assert!(
    name_from_first_prompt("<permissions instructions>...</permissions instructions>").is_none()
  );
  assert!(name_from_first_prompt(
    "<turn_aborted>The user interrupted the previous turn on purpose.</turn_aborted>"
  )
  .is_none());
  assert!(name_from_first_prompt("<skill><name>testing-philosophy</name></skill>").is_none());
  assert_eq!(
    name_from_first_prompt("Fix naming in rollout watcher").as_deref(),
    Some("Fix naming in rollout watcher")
  );
}

#[test]
fn truncates_and_normalizes_prompt() {
  let prompt = "  Please investigate auth race conditions and propose a safe migration plan.  ";
  let name = name_from_first_prompt(prompt).expect("expected name");
  assert_eq!(
    name,
    "Please investigate auth race conditions and propose a safe migration pla…"
  );
}
