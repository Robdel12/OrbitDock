use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationDisplayMode {
    Grouped,
    Verbose,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct RenderHints {
    #[serde(default)]
    pub can_expand: bool,
    #[serde(default)]
    pub default_expanded: bool,
    #[serde(default)]
    pub emphasized: bool,
    #[serde(default)]
    pub monospace_summary: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accent_tone: Option<String>,
}
