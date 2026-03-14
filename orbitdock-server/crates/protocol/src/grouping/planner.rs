use crate::conversation_contracts::{ActivityGroupKind, ActivityGroupRow, RenderHints, ToolRow};
use crate::domain_events::{ToolFamily, ToolStatus};

pub fn group_contiguous_tool_rows(rows: Vec<ToolRow>) -> Vec<ActivityGroupRow> {
    if rows.is_empty() {
        return Vec::new();
    }

    let mut groups = Vec::new();
    let mut current: Vec<ToolRow> = Vec::new();
    let mut next_group_index: usize = 0;

    for row in rows {
        let should_split = current
            .last()
            .map(|last| last.grouping_key != row.grouping_key || last.family != row.family)
            .unwrap_or(false);

        if should_split {
            groups.push(build_group(&current, next_group_index));
            next_group_index += 1;
            current.clear();
        }

        current.push(row);
    }

    if !current.is_empty() {
        groups.push(build_group(&current, next_group_index));
    }

    groups
}

fn build_group(rows: &[ToolRow], index: usize) -> ActivityGroupRow {
    let children = rows.to_vec();
    let first = &children[0];
    let turn_id = first.started_at.clone();
    let grouping_key = first.grouping_key.clone();
    let status = fold_status(children.iter().map(|row| row.status));
    let family = common_family(&children);
    let title = match family {
        Some(ToolFamily::Agent) => format!("{} agent operations", children.len()),
        Some(ToolFamily::Search) => format!("{} search operations", children.len()),
        Some(ToolFamily::FileChange | ToolFamily::FileRead) => {
            format!("{} file operations", children.len())
        }
        _ => format!("{} operations", children.len()),
    };

    ActivityGroupRow {
        id: format!("activity-group-{}", index),
        group_kind: infer_group_kind(family),
        title,
        subtitle: Some(format!("{} tool events in this block", children.len())),
        summary: None,
        child_count: children.len(),
        children,
        turn_id,
        grouping_key,
        status,
        family,
        render_hints: RenderHints {
            can_expand: true,
            ..RenderHints::default()
        },
    }
}

fn infer_group_kind(family: Option<ToolFamily>) -> ActivityGroupKind {
    match family {
        Some(ToolFamily::Agent) => ActivityGroupKind::WorkerBlock,
        Some(_) => ActivityGroupKind::ToolBlock,
        None => ActivityGroupKind::MixedBlock,
    }
}

fn common_family(rows: &[ToolRow]) -> Option<ToolFamily> {
    let first = rows.first()?.family;
    if rows.iter().all(|row| row.family == first) {
        Some(first)
    } else {
        None
    }
}

fn fold_status(statuses: impl Iterator<Item = ToolStatus>) -> ToolStatus {
    let mut saw_running = false;
    let mut saw_failed = false;
    let mut saw_blocked = false;
    let mut saw_needs_input = false;

    for status in statuses {
        match status {
            ToolStatus::Running => saw_running = true,
            ToolStatus::Failed | ToolStatus::Cancelled => saw_failed = true,
            ToolStatus::Blocked => saw_blocked = true,
            ToolStatus::NeedsInput => saw_needs_input = true,
            ToolStatus::Pending | ToolStatus::Completed => {}
        }
    }

    if saw_running {
        ToolStatus::Running
    } else if saw_needs_input {
        ToolStatus::NeedsInput
    } else if saw_blocked {
        ToolStatus::Blocked
    } else if saw_failed {
        ToolStatus::Failed
    } else {
        ToolStatus::Completed
    }
}
