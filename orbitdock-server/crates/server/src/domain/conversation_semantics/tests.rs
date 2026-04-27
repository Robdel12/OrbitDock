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
