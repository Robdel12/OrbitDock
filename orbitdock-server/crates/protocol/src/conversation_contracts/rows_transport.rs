use super::ShellExecutionPayload;

pub const SHELL_TRANSPORT_PREVIEW_CHAR_LIMIT: usize = 8 * 1024;
pub const SHELL_TRANSPORT_PREVIEW_LINE_LIMIT: usize = 6;

pub fn compact_shell_execution_payload(shell: &mut ShellExecutionPayload) {
  if shell.live_output_preview.is_none() {
    shell.live_output_preview = shell
      .aggregated_output
      .as_deref()
      .map(|output| truncate_preview_text(output, SHELL_TRANSPORT_PREVIEW_CHAR_LIMIT));
  } else if let Some(preview) = shell.live_output_preview.as_mut() {
    *preview = truncate_preview_text(preview, SHELL_TRANSPORT_PREVIEW_CHAR_LIMIT);
  }

  shell.aggregated_output = None;
  shell.terminal_snapshot = None;

  if let Some(preview) = shell.preview.as_mut() {
    bound_shell_preview_lines(preview, SHELL_TRANSPORT_PREVIEW_LINE_LIMIT);
  }
}

fn truncate_preview_text(value: &str, max_chars: usize) -> String {
  if value.chars().count() <= max_chars {
    return value.to_string();
  }

  let truncated: String = value.chars().take(max_chars).collect();
  format!("{truncated}…")
}

fn bound_shell_preview_lines(preview: &mut super::ShellPreview, max_lines: usize) {
  if preview.lines.len() <= max_lines {
    return;
  }

  let overflow = preview.lines.len() - max_lines;
  let current_overflow = preview.overflow_count.unwrap_or(0) as usize;
  preview.overflow_count = Some((overflow + current_overflow) as u32);
  preview.lines.truncate(max_lines);
}
