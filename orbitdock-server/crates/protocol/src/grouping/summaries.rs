use crate::conversation_contracts::{ActivityGroupKind, ActivityGroupRow};

pub fn summarize_activity_group(group: &ActivityGroupRow) -> String {
    let noun = match group.group_kind {
        ActivityGroupKind::ToolBlock => "tool events",
        ActivityGroupKind::WorkerBlock => "worker events",
        ActivityGroupKind::MixedBlock => "activity events",
    };
    format!("{} {}", group.child_count, noun)
}
