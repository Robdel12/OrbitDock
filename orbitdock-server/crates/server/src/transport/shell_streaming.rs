const SHELL_STREAM_PREVIEW_CHAR_LIMIT: usize = 8 * 1024;
pub(crate) const SHELL_STREAM_THROTTLE_MS: u128 = 120;

#[derive(Debug, Default)]
pub(crate) struct ShellStreamPreviewState {
  stdout: String,
  stderr: String,
}

impl ShellStreamPreviewState {
  pub(crate) fn append_stdout(&mut self, chunk: &str) {
    self.stdout.push_str(chunk);
    trim_front_to_char_limit(&mut self.stdout, SHELL_STREAM_PREVIEW_CHAR_LIMIT);
  }

  pub(crate) fn append_stderr(&mut self, chunk: &str) {
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
    match (self.stdout.is_empty(), self.stderr.is_empty()) {
      (true, true) => None,
      (false, true) => Some(self.stdout.clone()),
      (true, false) => Some(self.stderr.clone()),
      (false, false) => Some(format!("{}\n{}", self.stdout, self.stderr)),
    }
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
  use super::ShellStreamPreviewState;

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
}
