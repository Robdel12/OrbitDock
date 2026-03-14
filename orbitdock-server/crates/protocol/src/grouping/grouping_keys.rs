use crate::domain_events::GroupingKey;

pub fn tool_grouping_key(turn_id: Option<&str>, group_id: impl Into<String>) -> GroupingKey {
    GroupingKey {
        turn_id: turn_id.map(str::to_owned),
        group_id: group_id.into(),
    }
}
