const SHELL_STREAM_PREVIEW_CHAR_LIMIT: usize = 8 * 1024;
pub(crate) const SHELL_STREAM_THROTTLE_MS: u128 = 120;

#[derive(Debug, Default)]
pub(crate) struct ShellStreamPreviewState {
  combined: String,
  stdout: String,
  stderr: String,
}

impl ShellStreamPreviewState {
  pub(crate) fn append_stdout(&mut self, chunk: &str) {
    self.combined.push_str(chunk);
    trim_front_to_char_limit(&mut self.combined, SHELL_STREAM_PREVIEW_CHAR_LIMIT);
    self.stdout.push_str(chunk);
    trim_front_to_char_limit(&mut self.stdout, SHELL_STREAM_PREVIEW_CHAR_LIMIT);
  }

  pub(crate) fn append_stderr(&mut self, chunk: &str) {
    self.combined.push_str(chunk);
    trim_front_to_char_limit(&mut self.combined, SHELL_STREAM_PREVIEW_CHAR_LIMIT);
    self.stderr.push_str(chunk);
    trim_front_to_char_limit(&mut self.stderr, SHELL_STREAM_PREVIEW_CHAR_LIMIT);
  }

  pub(crate) fn stdout_preview(&self) -> Option<String> {
    (!self.stdout.is_empty()).then(|| self.stdout.clone())
  }

  pub(crate) fn stderr_preview(&self) -> Option<String> {
    (!self.stderr.is_empty()).then(|| self.stderr.clone())
  }

  pub(crate) fn combined_preview(&self) -> Option<String> {
    (!self.combined.is_empty()).then(|| self.combined.clone())
  }
}

pub(crate) fn prefer_streamed_shell_output(
  stdout: &str,
  stderr: &str,
  streamed_output: Option<&str>,
) -> String {
  if stdout.is_empty() && stderr.is_empty() {
    return streamed_output.unwrap_or_default().to_string();
  }

  if !stdout.is_empty() && !stderr.is_empty() {
    if let Some(streamed_output) = streamed_output.filter(|value| !value.is_empty()) {
      return streamed_output.to_string();
    }
  }

  if stderr.is_empty() {
    stdout.to_string()
  } else if stdout.is_empty() {
    stderr.to_string()
  } else {
    format!("{stdout}\n{stderr}")
  }
}

fn trim_front_to_char_limit(value: &mut String, limit: usize) {
  if value.len() <= limit {
    return;
  }

  let mut split_at = value.len().saturating_sub(limit);
  while split_at < value.len() && !value.is_char_boundary(split_at) {
    split_at += 1;
  }
  value.drain(..split_at);
}

#[cfg(test)]
mod tests {
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
}
