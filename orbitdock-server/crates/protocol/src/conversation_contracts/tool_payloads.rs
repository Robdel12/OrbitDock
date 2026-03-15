use serde::{Deserialize, Serialize};

use crate::domain_events::ToolPreviewPayload;

/// On the wire, invocation and result are flat JSON objects.
/// Connectors serialize their typed payloads to Value before placing on ToolRow.
pub type ToolInvocationPayloadContract = serde_json::Value;
pub type ToolResultPayloadContract = serde_json::Value;
pub type ToolPreview = ToolPreviewPayload;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolPayloadReference {
    pub tool_id: String,
}
