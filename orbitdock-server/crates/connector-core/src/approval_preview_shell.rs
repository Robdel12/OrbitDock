use orbitdock_protocol::ApprovalPreviewSegment;

pub(super) fn shell_operator_prefix(leading_operator: Option<&str>) -> String {
  let Some(op) = leading_operator
    .map(|value| value.trim())
    .filter(|value| !value.is_empty())
  else {
    return String::new();
  };

  let meaning = match op {
    "||" => "if previous fails",
    "&&" => "if previous succeeds",
    "|" => "pipe output from previous",
    _ => "then",
  };
  format!("({op}, {meaning}) ")
}

pub(super) fn shell_segments_for_preview(command: &str) -> Vec<ApprovalPreviewSegment> {
  let chars: Vec<char> = command.chars().collect();
  let mut segments: Vec<ApprovalPreviewSegment> = Vec::new();
  let mut buffer = String::new();
  let mut pending_operator: Option<String> = None;

  let mut in_single_quote = false;
  let mut in_double_quote = false;
  let mut in_backtick = false;
  let mut escaped = false;
  let mut paren_depth: usize = 0;
  let mut heredoc_delimiter: Option<String> = None;

  let mut index = 0;
  while index < chars.len() {
    let ch = chars[index];

    if let Some(ref delimiter) = heredoc_delimiter {
      buffer.push(ch);
      if ch == '\n' {
        let remaining: String = chars[index + 1..].iter().collect();
        let next_line = remaining.split('\n').next().unwrap_or("");
        if next_line.trim() == delimiter.as_str() {
          for &dc in &chars[index + 1..] {
            buffer.push(dc);
            if dc == '\n' {
              break;
            }
          }
          let delim_line_len = next_line.len();
          index += 1 + delim_line_len;
          if index < chars.len() && chars[index] == '\n' {
            index += 1;
          }
          heredoc_delimiter = None;
          flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
          pending_operator = Some(";".to_string());
          continue;
        }
      } else if index + 1 == chars.len() {
        heredoc_delimiter = None;
      }
      index += 1;
      continue;
    }

    if escaped {
      buffer.push(ch);
      escaped = false;
      index += 1;
      continue;
    }

    if ch == '\\' {
      if !in_single_quote {
        escaped = true;
      }
      buffer.push(ch);
      index += 1;
      continue;
    }

    if !in_double_quote && !in_backtick && ch == '\'' {
      in_single_quote = !in_single_quote;
      buffer.push(ch);
      index += 1;
      continue;
    }

    if !in_single_quote && !in_backtick && ch == '"' {
      in_double_quote = !in_double_quote;
      buffer.push(ch);
      index += 1;
      continue;
    }

    if !in_single_quote && !in_double_quote && ch == '`' {
      in_backtick = !in_backtick;
      buffer.push(ch);
      index += 1;
      continue;
    }

    let can_split = !in_single_quote && !in_double_quote && !in_backtick && paren_depth == 0;

    if !in_single_quote && !in_double_quote && !in_backtick {
      if ch == '(' {
        paren_depth += 1;
      } else if ch == ')' {
        paren_depth = paren_depth.saturating_sub(1);
      }
    }

    if can_split && ch == '<' && index + 1 < chars.len() && chars[index + 1] == '<' {
      buffer.push(ch);
      buffer.push(chars[index + 1]);
      let mut hd_index = index + 2;

      if hd_index < chars.len() && chars[hd_index] == '-' {
        buffer.push(chars[hd_index]);
        hd_index += 1;
      }

      while hd_index < chars.len() && chars[hd_index] == ' ' {
        buffer.push(chars[hd_index]);
        hd_index += 1;
      }

      let quote_char =
        if hd_index < chars.len() && (chars[hd_index] == '\'' || chars[hd_index] == '"') {
          let q = Some(chars[hd_index]);
          buffer.push(chars[hd_index]);
          hd_index += 1;
          q
        } else {
          None
        };

      let delim_start = hd_index;
      while hd_index < chars.len() {
        let c = chars[hd_index];
        if let Some(q) = quote_char {
          if c == q {
            break;
          }
        } else if !c.is_alphanumeric() && c != '_' {
          break;
        }
        buffer.push(c);
        hd_index += 1;
      }

      let delim: String = chars[delim_start..hd_index].iter().collect();

      if let Some(q) = quote_char {
        if hd_index < chars.len() && chars[hd_index] == q {
          buffer.push(chars[hd_index]);
          hd_index += 1;
        }
      }

      if !delim.is_empty() {
        heredoc_delimiter = Some(delim);
      }
      index = hd_index;
      continue;
    }

    if can_split {
      if ch == '|' {
        let is_double = (index + 1) < chars.len() && chars[index + 1] == '|';
        flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
        pending_operator = Some(if is_double { "||" } else { "|" }.to_string());
        index += if is_double { 2 } else { 1 };
        continue;
      }

      if ch == '&' && (index + 1) < chars.len() && chars[index + 1] == '&' {
        flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
        pending_operator = Some("&&".to_string());
        index += 2;
        continue;
      }

      if ch == ';' || ch == '\n' {
        flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
        pending_operator = Some(";".to_string());
        index += 1;
        continue;
      }
    }

    buffer.push(ch);
    index += 1;
  }

  flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
  segments
}

fn flush_shell_segment(
  buffer: &mut String,
  segments: &mut Vec<ApprovalPreviewSegment>,
  pending_operator: &mut Option<String>,
) {
  let trimmed = buffer.trim();
  if trimmed.is_empty() {
    buffer.clear();
    return;
  }

  let leading_operator = if segments.is_empty() {
    None
  } else {
    pending_operator.clone()
  };
  segments.push(ApprovalPreviewSegment {
    command: trimmed.to_string(),
    leading_operator,
  });
  buffer.clear();
  *pending_operator = None;
}
