use serde::{Deserialize, Serialize};

use crate::conversation_contracts::render_hints::RenderHints;
use crate::domain_events::{WorkerOperationKind, WorkerStateSnapshot};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkerRow {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub worker: WorkerStateSnapshot,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation: Option<WorkerOperationKind>,
    #[serde(default)]
    pub render_hints: RenderHints,
}
