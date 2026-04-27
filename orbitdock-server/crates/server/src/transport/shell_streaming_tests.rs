use super::{prefer_streamed_shell_output, ShellStreamPreviewState};

#[test]
fn combined_preview_retains_recent_tail() {
  let mut state = ShellStreamPreviewState::default();
  state.append_stdout(&"a".repeat(9000));
  state.append_stderr("stderr");

  let stdout = state.stdout_preview().expect("stdout preview");
  assert!(stdout.len() <= 8 * 1024);
  assert!(stdout.ends_with(&"a".repeat(128)));

  let combined = state.combined_preview().expect("combined preview");
  assert!(combined.contains("stderr"));
}

#[test]
fn combined_preview_preserves_stream_order_without_injected_newlines() {
  let mut state = ShellStreamPreviewState::default();
  state.append_stdout("stdout-1");
  state.append_stderr("stderr-1");
  state.append_stdout("stdout-2");

  assert_eq!(
    state.combined_preview().as_deref(),
    Some("stdout-1stderr-1stdout-2")
  );
}

#[test]
fn prefers_streamed_output_when_both_streams_are_present() {
  let final_output = prefer_streamed_shell_output(
    "stdout-1stdout-2",
    "stderr-1",
    Some("stdout-1stderr-1stdout-2"),
  );

  assert_eq!(final_output, "stdout-1stderr-1stdout-2");
}

#[test]
fn falls_back_to_non_empty_stream_when_only_one_is_present() {
  assert_eq!(
    prefer_streamed_shell_output("stdout-only", "", Some("ignored")),
    "stdout-only"
  );
  assert_eq!(
    prefer_streamed_shell_output("", "stderr-only", Some("ignored")),
    "stderr-only"
  );
}
