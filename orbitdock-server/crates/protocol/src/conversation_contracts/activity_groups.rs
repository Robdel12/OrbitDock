use serde::{Deserialize, Serialize};

use crate::conversation_contracts::render_hints::RenderHints;
use crate::conversation_contracts::rows::{ToolRow, ToolRowSummary};
use crate::domain_events::{ToolFamily, ToolStatus};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityGroupKind {
    ToolBlock,
    WorkerBlock,
    MixedBlock,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivityGroupRow {
    pub id: String,
    pub group_kind: ActivityGroupKind,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub child_count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<ToolRow>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grouping_key: Option<String>,
    pub status: ToolStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<ToolFamily>,
    #[serde(default)]
    pub render_hints: RenderHints,
}

/// Wire-safe activity group — children use `ToolRowSummary` (no raw payloads).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivityGroupRowSummary {
    pub id: String,
    pub group_kind: ActivityGroupKind,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub child_count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<ToolRowSummary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grouping_key: Option<String>,
    pub status: ToolStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<ToolFamily>,
    #[serde(default)]
    pub render_hints: RenderHints,
}

impl ActivityGroupRow {
    /// Convert to wire-safe summary, mapping children to `ToolRowSummary`.
    pub fn to_summary(&self) -> ActivityGroupRowSummary {
        ActivityGroupRowSummary {
            id: self.id.clone(),
            group_kind: self.group_kind,
            title: self.title.clone(),
            subtitle: self.subtitle.clone(),
            summary: self.summary.clone(),
            child_count: self.child_count,
            children: self.children.iter().map(ToolRow::to_summary).collect(),
            turn_id: self.turn_id.clone(),
            grouping_key: self.grouping_key.clone(),
            status: self.status,
            family: self.family,
            render_hints: self.render_hints.clone(),
        }
    }
}
