use super::runtime::EnvironmentTracker;
use std::collections::HashMap;
use std::sync::Arc;

pub(super) mod approvals;
pub(super) mod capabilities;
pub(super) mod collab;
pub(super) mod lifecycle;
pub(super) mod messages;
pub(super) mod runtime_signals;
pub(super) mod streaming;
pub(super) mod tools;

pub(super) type SharedStringBuffers = Arc<tokio::sync::Mutex<HashMap<String, String>>>;
pub(super) type SharedEnvironmentTracker = Arc<tokio::sync::Mutex<EnvironmentTracker>>;
pub(super) type SharedPatchContexts = Arc<tokio::sync::Mutex<HashMap<String, serde_json::Value>>>;
