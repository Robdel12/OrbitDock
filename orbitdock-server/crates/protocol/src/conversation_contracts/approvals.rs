use serde::{Deserialize, Serialize};

use crate::conversation_contracts::render_hints::RenderHints;
use crate::domain_events::{ApprovalRequestPayload, QuestionPrompt, QuestionResponseValue};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApprovalRow {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub request: ApprovalRequestPayload,
    #[serde(default)]
    pub render_hints: RenderHints,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuestionRow {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub prompts: Vec<QuestionPrompt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response: Option<QuestionResponseValue>,
    #[serde(default)]
    pub render_hints: RenderHints,
}
