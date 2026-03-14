//! Pure grouping helpers for conversation tool activity.

pub mod grouping_keys;
pub mod planner;
pub mod summaries;

pub use grouping_keys::tool_grouping_key;
pub use planner::group_contiguous_tool_rows;
pub use summaries::summarize_activity_group;
