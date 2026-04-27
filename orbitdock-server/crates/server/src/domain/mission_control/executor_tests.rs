use super::*;
use crate::domain::mission_control::tracker::{Tracker, TrackerConfig, TrackerIssue};
use crate::infrastructure::linear::client::LinearClient;
use async_trait::async_trait;
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct TestTracker {
  updated_states: Mutex<Vec<String>>,
}

#[async_trait]
impl Tracker for TestTracker {
  async fn fetch_candidates(&self, _config: &TrackerConfig) -> anyhow::Result<Vec<TrackerIssue>> {
    Ok(vec![])
  }

  async fn fetch_issue_states(
    &self,
    _issue_ids: &[String],
  ) -> anyhow::Result<HashMap<String, String>> {
    Ok(HashMap::new())
  }

  fn kind(&self) -> &str {
    "test"
  }

  async fn update_issue_state(&self, _issue_id: &str, state_name: &str) -> anyhow::Result<()> {
    self
      .updated_states
      .lock()
      .unwrap()
      .push(state_name.to_string());
    Ok(())
  }
}

fn test_ctx() -> MissionToolContext {
  MissionToolContext {
    issue_id: "issue-abc-123".into(),
    issue_identifier: "TEST-42".into(),
    mission_id: "mission-xyz".into(),
  }
}

#[tokio::test]
async fn unknown_tool_returns_error() {
  let client = LinearClient::new("fake-key".into());
  let result = execute_mission_tool(&client, &test_ctx(), "nonexistent_tool", json!({})).await;

  assert!(!result.success);
  assert!(!result.blocked);
  let output: serde_json::Value = serde_json::from_str(&result.output).unwrap();
  assert!(output["error"].as_str().unwrap().contains("Unknown tool"));
}

#[test]
fn missing_field_helper_reports_field_name() {
  let result = missing_field("body");
  assert!(!result.success);
  let output: serde_json::Value = serde_json::from_str(&result.output).unwrap();
  assert!(output["error"].as_str().unwrap().contains("body"));
}

#[test]
fn ok_json_helper_produces_success() {
  let result = ok_json(json!({"test": true}));
  assert!(result.success);
  assert!(!result.blocked);
  assert!(result.completed_state.is_none());
  let output: serde_json::Value = serde_json::from_str(&result.output).unwrap();
  assert_eq!(output["test"], true);
}

#[tokio::test]
async fn terminal_mission_status_marks_local_completion() {
  let tracker = Arc::new(TestTracker::default());

  let result = execute_mission_tool(
    tracker.as_ref(),
    &test_ctx(),
    "mission_set_status",
    json!({ "state": "Done" }),
  )
  .await;

  assert!(result.success);
  assert_eq!(result.completed_state.as_deref(), Some("Done"));
  assert_eq!(tracker.updated_states.lock().unwrap().as_slice(), ["Done"]);
}
