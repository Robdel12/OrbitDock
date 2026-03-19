use orbitdock_protocol::conversation_contracts::{
    ContextRow, ContextRowKind, ConversationRow, MessageRowContent, NoticeRow, NoticeRowKind,
    NoticeRowSeverity, RenderHints, ShellCommandRow, ShellCommandRowKind, TaskRow, TaskRowKind,
    TaskRowStatus,
};

#[cfg(test)]
const HANDLED_WRAPPERS: &[&str] = &[
    "agents_md_instructions",
    "environment_context",
    "skill",
    "permissions_instructions",
    "user_instructions",
    "system_reminder",
    "personality_spec",
    "turn_aborted",
    "local_command_caveat",
    "user_shell_command",
    "command_name",
    "bash_input",
    "bash_stdout",
    "bash_stderr",
    "local_command_stdout",
    "local_command_stderr",
    "shell_context",
    "task_notification",
    "image_marker",
];

#[cfg(test)]
pub(crate) fn handled_wrappers() -> &'static [&'static str] {
    HANDLED_WRAPPERS
}

pub(crate) fn upgrade_row(row: ConversationRow) -> ConversationRow {
    match row {
        ConversationRow::User(message) => upgrade_message_row(message, ConversationRow::User),
        ConversationRow::Assistant(message) => {
            upgrade_message_row(message, ConversationRow::Assistant)
        }
        ConversationRow::Thinking(message) => {
            upgrade_message_row(message, ConversationRow::Thinking)
        }
        ConversationRow::System(message) => upgrade_message_row(message, ConversationRow::System),
        other => other,
    }
}

fn upgrade_message_row(
    message: MessageRowContent,
    fallback: impl FnOnce(MessageRowContent) -> ConversationRow,
) -> ConversationRow {
    if let Some(row) = parse_wrapper_message(&message) {
        return row;
    }

    let cleaned = strip_image_markers(&message.content);
    if cleaned != message.content {
        return fallback(MessageRowContent {
            content: cleaned,
            ..message
        });
    }

    fallback(message)
}

fn parse_wrapper_message(message: &MessageRowContent) -> Option<ConversationRow> {
    let trimmed = message.content.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Some(context) = parse_agents_instructions(message, trimmed) {
        return Some(ConversationRow::Context(context));
    }
    if let Some(context) = parse_environment_context(message, trimmed) {
        return Some(ConversationRow::Context(context));
    }
    if let Some(context) = parse_skill(message, trimmed) {
        return Some(ConversationRow::Context(context));
    }
    if let Some(context) = parse_simple_context(
        message,
        trimmed,
        "permissions instructions",
        ContextRowKind::Reminder,
        "Permissions instructions",
    ) {
        return Some(ConversationRow::Context(context));
    }
    if let Some(context) = parse_simple_context(
        message,
        trimmed,
        "user_instructions",
        ContextRowKind::UserInstructions,
        "User instructions",
    ) {
        return Some(ConversationRow::Context(context));
    }
    if let Some(context) = parse_simple_context(
        message,
        trimmed,
        "system-reminder",
        ContextRowKind::Reminder,
        "System reminder",
    ) {
        return Some(ConversationRow::Context(context));
    }
    if let Some(context) = parse_simple_context(
        message,
        trimmed,
        "personality_spec",
        ContextRowKind::Personality,
        "Personality spec",
    ) {
        return Some(ConversationRow::Context(context));
    }
    if let Some(notice) = parse_notice(message, trimmed) {
        return Some(ConversationRow::Notice(notice));
    }
    if let Some(shell) = parse_user_shell_command(message, trimmed) {
        return Some(ConversationRow::ShellCommand(shell));
    }
    if let Some(shell) = parse_slash_command(message, trimmed) {
        return Some(ConversationRow::ShellCommand(shell));
    }
    if let Some(shell) = parse_bash_block(message, trimmed) {
        return Some(ConversationRow::ShellCommand(shell));
    }
    if let Some(shell) = parse_local_command_output(message, trimmed) {
        return Some(ConversationRow::ShellCommand(shell));
    }
    if let Some(shell) = parse_shell_context(message, trimmed) {
        return Some(ConversationRow::ShellCommand(shell));
    }
    if let Some(task) = parse_task_notification(message, trimmed) {
        return Some(ConversationRow::Task(task));
    }

    None
}

fn parse_agents_instructions(message: &MessageRowContent, trimmed: &str) -> Option<ContextRow> {
    if !trimmed.starts_with("# AGENTS.md instructions for ") && !trimmed.contains("<INSTRUCTIONS>")
    {
        return None;
    }

    let source_path = trimmed
        .lines()
        .next()
        .and_then(|line| line.strip_prefix("# AGENTS.md instructions for "))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    let body = extract_tag(trimmed, "INSTRUCTIONS");
    let summary = body
        .as_deref()
        .map(first_non_empty_line)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);

    Some(ContextRow {
        id: message.id.clone(),
        kind: ContextRowKind::AgentInstructions,
        title: "AGENTS.md instructions".to_string(),
        subtitle: source_path.clone(),
        summary,
        body,
        source_path,
        cwd: extract_tag(trimmed, "cwd"),
        shell: extract_tag(trimmed, "shell"),
        render_hints: compact_context_hints(),
    })
}

fn parse_environment_context(message: &MessageRowContent, trimmed: &str) -> Option<ContextRow> {
    if !trimmed.contains("<environment_context>") {
        return None;
    }

    let cwd = extract_tag(trimmed, "cwd");
    let shell = extract_tag(trimmed, "shell");
    let current_date = extract_tag(trimmed, "current_date");
    let timezone = extract_tag(trimmed, "timezone");
    let mut summary_parts = Vec::new();
    if let Some(cwd) = cwd.as_deref() {
        summary_parts.push(cwd.to_string());
    }
    if let Some(shell) = shell.as_deref() {
        summary_parts.push(format!("shell: {shell}"));
    }
    if let Some(current_date) = current_date.as_deref() {
        summary_parts.push(format!("date: {current_date}"));
    }
    if let Some(timezone) = timezone.as_deref() {
        summary_parts.push(format!("tz: {timezone}"));
    }
    let body = extract_tag(trimmed, "environment_context");

    Some(ContextRow {
        id: message.id.clone(),
        kind: ContextRowKind::Environment,
        title: "Environment context".to_string(),
        subtitle: cwd.clone(),
        summary: (!summary_parts.is_empty()).then(|| summary_parts.join(" • ")),
        body,
        source_path: None,
        cwd,
        shell,
        render_hints: compact_context_hints(),
    })
}

fn parse_skill(message: &MessageRowContent, trimmed: &str) -> Option<ContextRow> {
    if !trimmed.starts_with("<skill>") {
        return None;
    }

    let name = extract_tag(trimmed, "name");
    let path = extract_tag(trimmed, "path");
    let body = extract_tag(trimmed, "skill").map(|value| strip_nested_tag(&value, "name", "path"));

    Some(ContextRow {
        id: message.id.clone(),
        kind: ContextRowKind::Skill,
        title: name.clone().unwrap_or_else(|| "Skill".to_string()),
        subtitle: path.clone(),
        summary: body
            .as_deref()
            .map(first_non_empty_line)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string),
        body,
        source_path: path,
        cwd: None,
        shell: None,
        render_hints: compact_context_hints(),
    })
}

fn parse_simple_context(
    message: &MessageRowContent,
    trimmed: &str,
    tag: &str,
    kind: ContextRowKind,
    title: &str,
) -> Option<ContextRow> {
    let body = extract_tag(trimmed, tag)?;
    let summary = first_non_empty_line(&body);

    Some(ContextRow {
        id: message.id.clone(),
        kind,
        title: title.to_string(),
        subtitle: None,
        summary: (!summary.is_empty()).then(|| summary.to_string()),
        body: Some(body),
        source_path: None,
        cwd: None,
        shell: None,
        render_hints: compact_context_hints(),
    })
}

fn parse_notice(message: &MessageRowContent, trimmed: &str) -> Option<NoticeRow> {
    if let Some(body) = extract_tag(trimmed, "turn_aborted") {
        return Some(NoticeRow {
            id: message.id.clone(),
            kind: NoticeRowKind::TurnAborted,
            severity: NoticeRowSeverity::Warning,
            title: "Turn aborted".to_string(),
            summary: (!body.trim().is_empty()).then(|| first_non_empty_line(&body).to_string()),
            body: Some(body),
            render_hints: compact_notice_hints(),
        });
    }

    if let Some(body) = extract_tag(trimmed, "local-command-caveat") {
        return Some(NoticeRow {
            id: message.id.clone(),
            kind: NoticeRowKind::LocalCommandCaveat,
            severity: NoticeRowSeverity::Info,
            title: "Local command caveat".to_string(),
            summary: (!body.trim().is_empty()).then(|| first_non_empty_line(&body).to_string()),
            body: Some(body),
            render_hints: compact_notice_hints(),
        });
    }

    None
}

fn parse_user_shell_command(message: &MessageRowContent, trimmed: &str) -> Option<ShellCommandRow> {
    if !trimmed.starts_with("<user_shell_command>") {
        return None;
    }

    let command = extract_tag(trimmed, "command");
    let result = extract_tag(trimmed, "result");
    let exit_code =
        parse_line_value(result.as_deref(), "Exit code:").and_then(|value| value.parse().ok());
    let duration_seconds =
        parse_line_value(result.as_deref(), "Duration:").and_then(parse_duration_seconds);
    let stdout = parse_output_block(result.as_deref());

    Some(ShellCommandRow {
        id: message.id.clone(),
        kind: ShellCommandRowKind::UserShellCommand,
        title: command
            .clone()
            .unwrap_or_else(|| "Shell command".to_string()),
        summary: exit_code.map(|code| format!("Exit code {code}")),
        command,
        args: vec![],
        stdout,
        stderr: None,
        exit_code,
        duration_seconds,
        cwd: None,
        render_hints: expandable_shell_hints(),
    })
}

fn parse_slash_command(message: &MessageRowContent, trimmed: &str) -> Option<ShellCommandRow> {
    let command_name = extract_tag(trimmed, "command-name")?;
    let summary = extract_tag(trimmed, "command-message");
    let args = extract_tag(trimmed, "command-args")
        .map(|value| {
            value
                .lines()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    Some(ShellCommandRow {
        id: message.id.clone(),
        kind: ShellCommandRowKind::SlashCommand,
        title: format!("/{command_name}"),
        summary,
        command: Some(command_name),
        args,
        stdout: None,
        stderr: None,
        exit_code: None,
        duration_seconds: None,
        cwd: None,
        render_hints: expandable_shell_hints(),
    })
}

fn parse_bash_block(message: &MessageRowContent, trimmed: &str) -> Option<ShellCommandRow> {
    let command = extract_tag(trimmed, "bash-input")?;
    let stdout = extract_tag(trimmed, "bash-stdout");
    let stderr = extract_tag(trimmed, "bash-stderr");

    Some(ShellCommandRow {
        id: message.id.clone(),
        kind: ShellCommandRowKind::Bash,
        title: command.clone(),
        summary: None,
        command: Some(command),
        args: vec![],
        stdout,
        stderr,
        exit_code: None,
        duration_seconds: None,
        cwd: None,
        render_hints: expandable_shell_hints(),
    })
}

fn parse_local_command_output(
    message: &MessageRowContent,
    trimmed: &str,
) -> Option<ShellCommandRow> {
    let stdout = extract_tag(trimmed, "local-command-stdout");
    let stderr = extract_tag(trimmed, "local-command-stderr");
    let summary = extract_tag(trimmed, "local-command-caveat");
    if stdout.is_none() && stderr.is_none() {
        return None;
    }

    Some(ShellCommandRow {
        id: message.id.clone(),
        kind: ShellCommandRowKind::LocalCommandOutput,
        title: "Local command output".to_string(),
        summary,
        command: None,
        args: vec![],
        stdout,
        stderr,
        exit_code: None,
        duration_seconds: None,
        cwd: None,
        render_hints: expandable_shell_hints(),
    })
}

fn parse_shell_context(message: &MessageRowContent, trimmed: &str) -> Option<ShellCommandRow> {
    let body = extract_tag(trimmed, "shell-context")?;
    Some(ShellCommandRow {
        id: message.id.clone(),
        kind: ShellCommandRowKind::ShellContext,
        title: "Shell context".to_string(),
        summary: (!body.trim().is_empty()).then(|| first_non_empty_line(&body).to_string()),
        command: None,
        args: vec![],
        stdout: Some(body),
        stderr: None,
        exit_code: None,
        duration_seconds: None,
        cwd: None,
        render_hints: expandable_shell_hints(),
    })
}

fn parse_task_notification(message: &MessageRowContent, trimmed: &str) -> Option<TaskRow> {
    if !trimmed.starts_with("<task-notification>") {
        return None;
    }

    let task_id = extract_tag(trimmed, "task-id");
    let tool_use_id = extract_tag(trimmed, "tool-use-id");
    let output_file = extract_tag(trimmed, "output-file");
    let status = extract_tag(trimmed, "status")
        .as_deref()
        .map(parse_task_status)
        .unwrap_or(TaskRowStatus::Pending);
    let summary = extract_tag(trimmed, "summary");
    let result_text = trimmed
        .split_once("</task-notification>")
        .map(|(_, remainder)| remainder.trim().to_string())
        .filter(|value| !value.is_empty());

    Some(TaskRow {
        id: message.id.clone(),
        kind: TaskRowKind::BackgroundCommand,
        status,
        title: summary
            .clone()
            .unwrap_or_else(|| "Background task notification".to_string()),
        summary,
        task_id,
        tool_use_id,
        output_file,
        result_text,
        render_hints: compact_notice_hints(),
    })
}

fn extract_tag(content: &str, tag: &str) -> Option<String> {
    let start_token = format!("<{tag}>");
    let end_token = format!("</{tag}>");
    let start = content.find(&start_token)?;
    let rest = &content[start + start_token.len()..];
    let end = rest.find(&end_token)?;
    let value = rest[..end].trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn strip_nested_tag(content: &str, first_tag: &str, second_tag: &str) -> String {
    let first = remove_tag_block(content, first_tag);
    remove_tag_block(&first, second_tag).trim().to_string()
}

fn remove_tag_block(content: &str, tag: &str) -> String {
    let start_token = format!("<{tag}>");
    let end_token = format!("</{tag}>");
    if let Some(start) = content.find(&start_token) {
        if let Some(end) = content[start..].find(&end_token) {
            let end_index = start + end + end_token.len();
            let mut cleaned = String::new();
            cleaned.push_str(&content[..start]);
            cleaned.push_str(&content[end_index..]);
            return cleaned;
        }
    }
    content.to_string()
}

fn parse_line_value(body: Option<&str>, prefix: &str) -> Option<String> {
    body?
        .lines()
        .find_map(|line| line.trim().strip_prefix(prefix).map(str::trim))
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn parse_output_block(body: Option<&str>) -> Option<String> {
    let body = body?;
    let marker = "Output:";
    let (_, output) = body.split_once(marker)?;
    let output = output.trim();
    (!output.is_empty()).then(|| output.to_string())
}

fn parse_duration_seconds(value: String) -> Option<f64> {
    value
        .split_whitespace()
        .next()
        .and_then(|raw| raw.parse::<f64>().ok())
}

fn parse_task_status(value: &str) -> TaskRowStatus {
    match value.trim().to_ascii_lowercase().as_str() {
        "completed" => TaskRowStatus::Completed,
        "failed" => TaskRowStatus::Failed,
        "running" => TaskRowStatus::Running,
        _ => TaskRowStatus::Pending,
    }
}

fn first_non_empty_line(body: &str) -> &str {
    body.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default()
}

fn strip_image_markers(content: &str) -> String {
    let mut remaining = content;
    let mut cleaned = String::new();

    loop {
        let Some(start) = remaining.find("<image") else {
            cleaned.push_str(remaining);
            break;
        };
        cleaned.push_str(&remaining[..start]);
        let after_start = &remaining[start..];
        let Some(end) = after_start.find("</image>") else {
            cleaned.push_str(after_start);
            break;
        };
        remaining = &after_start[end + "</image>".len()..];
    }

    cleaned
        .lines()
        .filter(|line| {
            let trimmed = line.trim();
            !(trimmed.starts_with("[Image #") && trimmed.ends_with(']'))
        })
        .map(str::trim_end)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

fn compact_context_hints() -> RenderHints {
    RenderHints {
        can_expand: true,
        default_expanded: false,
        emphasized: false,
        monospace_summary: false,
        accent_tone: Some("context".to_string()),
    }
}

fn compact_notice_hints() -> RenderHints {
    RenderHints {
        can_expand: true,
        default_expanded: false,
        emphasized: false,
        monospace_summary: false,
        accent_tone: Some("notice".to_string()),
    }
}

fn expandable_shell_hints() -> RenderHints {
    RenderHints {
        can_expand: true,
        default_expanded: false,
        emphasized: false,
        monospace_summary: true,
        accent_tone: Some("shell".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn system_message(id: &str, content: &str) -> ConversationRow {
        ConversationRow::System(MessageRowContent {
            id: id.to_string(),
            content: content.to_string(),
            turn_id: None,
            timestamp: None,
            is_streaming: false,
            images: vec![],
        })
    }

    #[test]
    fn parses_environment_context() {
        let row = upgrade_row(system_message(
            "row-1",
            "<environment_context>\n  <cwd>/tmp/project</cwd>\n  <shell>zsh</shell>\n</environment_context>",
        ));

        match row {
            ConversationRow::Context(context) => {
                assert_eq!(context.kind, ContextRowKind::Environment);
                assert_eq!(context.cwd.as_deref(), Some("/tmp/project"));
                assert_eq!(context.shell.as_deref(), Some("zsh"));
            }
            other => panic!("expected context row, got {other:?}"),
        }
    }

    #[test]
    fn strips_image_markers_from_messages() {
        let row = upgrade_row(ConversationRow::Assistant(MessageRowContent {
            id: "row-2".to_string(),
            content: "<image name=[Image #1]>\n</image>\nHello".to_string(),
            turn_id: None,
            timestamp: None,
            is_streaming: false,
            images: vec![],
        }));

        match row {
            ConversationRow::Assistant(message) => assert_eq!(message.content, "Hello"),
            other => panic!("expected assistant row, got {other:?}"),
        }
    }

    #[test]
    fn parses_task_notification() {
        let row = upgrade_row(system_message(
            "row-3",
            "<task-notification>\n<task-id>abc</task-id>\n<status>failed</status>\n<summary>Task failed</summary>\n</task-notification>\nRead the output file.",
        ));

        match row {
            ConversationRow::Task(task) => {
                assert_eq!(task.status, TaskRowStatus::Failed);
                assert_eq!(task.task_id.as_deref(), Some("abc"));
            }
            other => panic!("expected task row, got {other:?}"),
        }
    }

    #[test]
    fn parses_permissions_instructions() {
        let row = upgrade_row(system_message(
            "row-4",
            "<permissions instructions>\nOnly read files unless asked.\n</permissions instructions>",
        ));

        match row {
            ConversationRow::Context(context) => {
                assert_eq!(context.title, "Permissions instructions");
            }
            other => panic!("expected context row, got {other:?}"),
        }
    }

    #[test]
    fn reports_handled_wrapper_inventory() {
        assert!(handled_wrappers().contains(&"environment_context"));
        assert!(handled_wrappers().contains(&"image_marker"));
    }
}
