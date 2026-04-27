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
#[path = "shell_streaming_tests.rs"]
mod tests;
