use serde::{Deserialize, Serialize};

use crate::domain_events::{ToolInvocationPayload, ToolPreviewPayload, ToolResultPayload};

pub type ToolInvocationPayloadContract = ToolInvocationPayload;
pub type ToolResultPayloadContract = ToolResultPayload;
pub type ToolPreview = ToolPreviewPayload;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolPayloadReference {
    pub tool_id: String,
}
