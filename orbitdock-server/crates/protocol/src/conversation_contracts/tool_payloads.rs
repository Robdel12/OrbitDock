use crate::domain_events::ToolPreviewPayload;

/// On the wire, invocation and result are flat JSON objects.
/// Connectors serialize their typed payloads to Value before placing on ToolRow.
pub type ToolInvocationPayloadContract = serde_json::Value;
pub type ToolResultPayloadContract = serde_json::Value;
pub type ToolPreview = ToolPreviewPayload;
