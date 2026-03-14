use serde::{Deserialize, Serialize};

use crate::conversation_contracts::render_hints::RenderHints;
use crate::conversation_contracts::rows::ToolRow;
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
