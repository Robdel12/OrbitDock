use std::collections::HashMap;
use std::sync::Arc;

use super::item_mapping::{
  command_execution_tool_status, file_change_tool_row, guardian_review_tool_row,
  map_collab_agent_tool, map_dynamic_tool, map_item, map_terminal_interaction,
  CollabAgentToolCallArgs, DynamicToolCallArgs,
};
use super::notification_mapping::{map_notification, map_token_usage, map_warning};
use super::AppServerSessionRoute;
use codex_app_server_protocol::{
  CollabAgentState, CollabAgentStatus, CollabAgentTool, CollabAgentToolCallStatus,
  CommandExecutionOutputDeltaNotification, CommandExecutionStatus,
  DynamicToolCallOutputContentItem, FileUpdateChange, GuardianApprovalReview,
  GuardianApprovalReviewAction, GuardianApprovalReviewStatus, GuardianCommandSource,
  GuardianRiskLevel, ItemCompletedNotification, PatchApplyStatus, PatchChangeKind,
  ServerNotification, TerminalInteractionNotification, ThreadItem, ThreadTokenUsage,
  TokenUsageBreakdown,
};
use codex_utils_absolute_path::AbsolutePathBuf;
use orbitdock_connector_core::{ConnectorOutput, ConnectorStateEvent, ConnectorTransportEffect};
use orbitdock_protocol::conversation_contracts::ConversationRow;
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::{SubagentStatus, TokenUsageSnapshotKind};
use serde_json::json;
use tokio::sync::{mpsc, Mutex};

use crate::row_mapping::tool_row_entry;

fn absolute_test_path(path: &str) -> AbsolutePathBuf {
  AbsolutePathBuf::from_absolute_path(path).expect("absolute test path")
}

fn usage_breakdown(
  total_tokens: i64,
  input_tokens: i64,
  cached_input_tokens: i64,
  output_tokens: i64,
) -> TokenUsageBreakdown {
  TokenUsageBreakdown {
    total_tokens,
    input_tokens,
    cached_input_tokens,
    output_tokens,
    reasoning_output_tokens: 0,
  }
}

#[test]
fn token_usage_uses_last_for_live_context_and_total_for_accounting() {
  let outputs = map_token_usage(ThreadTokenUsage {
    total: usage_breakdown(101_600_000, 101_600_000, 12_000, 50_000),
    last: usage_breakdown(64_000, 64_000, 8_000, 2_000),
    model_context_window: Some(258_400),
  });

  let live = outputs
    .first()
    .and_then(ConnectorOutput::as_state_event)
    .expect("live token output");
  let accounting = outputs
    .get(1)
    .and_then(ConnectorOutput::as_state_event)
    .expect("accounting token output");

  match live {
    ConnectorStateEvent::TokensUpdated {
      usage,
      snapshot_kind,
    } => {
      assert_eq!(*snapshot_kind, TokenUsageSnapshotKind::ContextTurn);
      assert_eq!(usage.input_tokens, 64_000);
      assert_eq!(usage.cached_tokens, 8_000);
      assert_eq!(usage.output_tokens, 2_000);
      assert_eq!(usage.context_window, 258_400);
    }
    other => panic!("expected live tokens_updated output, got {other:?}"),
  }

  match accounting {
    ConnectorStateEvent::TurnUsageUpdated {
      usage,
      snapshot_kind,
    } => {
      assert_eq!(*snapshot_kind, TokenUsageSnapshotKind::LifetimeTotals);
      assert_eq!(usage.input_tokens, 101_600_000);
      assert_eq!(usage.cached_tokens, 12_000);
      assert_eq!(usage.output_tokens, 50_000);
      assert_eq!(usage.context_window, 258_400);
    }
    other => panic!("expected turn_usage_updated output, got {other:?}"),
  }
}

#[test]
fn startup_skills_trimmed_warning_stays_out_of_timeline() {
  let outputs = map_warning(
    "Some enabled skills were not included in the model-visible skills list for this session."
      .to_string(),
  );

  assert!(outputs.is_empty());
}

#[test]
fn skills_context_budget_warning_stays_out_of_timeline() {
  let outputs = map_warning(
    "Warning: Exceeded skills context budget of 2%. Loaded skill descriptions were truncated by an average of 84 characters per skill."
      .to_string(),
  );

  assert!(outputs.is_empty());
}

#[test]
fn codex_transport_fallback_warning_stays_out_of_timeline() {
  let outputs = map_warning(
    "Falling back from WebSockets to HTTPS transport. stream disconnected before completion: websocket closed by server before response.completed"
      .to_string(),
  );

  assert!(outputs.is_empty());
}

#[test]
fn file_change_row_normalizes_app_server_add_content_for_diff_display() {
  let row = file_change_tool_row(
    "patch-1".to_string(),
    vec![FileUpdateChange {
      path: "runtime.js".to_string(),
      kind: PatchChangeKind::Add,
      diff: "let ready = true;\nexport { ready };".to_string(),
    }],
    PatchApplyStatus::Completed,
    false,
    Some("applied".to_string()),
  );

  assert_eq!(row.title, "runtime.js");
  assert_eq!(row.subtitle.as_deref(), Some("runtime.js"));

  let diff = row.invocation["diff"].as_str().expect("diff");
  assert!(diff.contains("--- /dev/null"));
  assert!(diff.contains("+++ runtime.js"));
  assert!(diff.contains("+let ready = true;"));

  let entry = tool_row_entry(row);
  let ConversationRow::Tool(tool) = entry.row else {
    panic!("expected tool row");
  };
  let display = tool.tool_display.expect("tool display");
  let preview = display.diff_preview.expect("diff preview");

  assert_eq!(preview.additions, 2);
  assert_eq!(preview.deletions, 0);
  assert_eq!(
    preview.preview_lines.first().map(String::as_str),
    Some("let ready = true;")
  );
}

#[test]
fn dynamic_file_tool_rows_keep_native_file_display_shape() {
  let outputs = map_dynamic_tool(DynamicToolCallArgs {
    id: "dynamic-write-1".to_string(),
    namespace: None,
    tool: "file_write".to_string(),
    arguments: json!({ "path": "/tmp/runtime.js" }),
    content_items: Some(vec![DynamicToolCallOutputContentItem::InputText {
      text: "{\"path\":\"/tmp/runtime.js\",\"bytes_written\":42}".to_string(),
    }]),
    success: true,
    duration_ms: Some(12),
    started: false,
  });

  let state = outputs
    .first()
    .and_then(ConnectorOutput::as_state_event)
    .expect("dynamic tool row update");
  let ConnectorStateEvent::ConversationRowUpdated { entry, .. } = state else {
    panic!("expected row update");
  };
  let ConversationRow::Tool(tool) = &entry.row else {
    panic!("expected tool row");
  };

  assert_eq!(tool.family, ToolFamily::FileChange);
  assert_eq!(tool.kind, ToolKind::Write);
  assert_eq!(tool.status, ToolStatus::Completed);
  assert_eq!(tool.title, "Write");
  assert_eq!(tool.result.as_ref().unwrap()["path"], "/tmp/runtime.js");
  assert_eq!(
    tool.result.as_ref().unwrap()["output"],
    "Wrote 42 bytes to /tmp/runtime.js"
  );

  let display = tool.tool_display.as_ref().expect("tool display");
  assert_eq!(display.tool_type, "write");
  assert_eq!(display.summary, "Wrote 42 bytes to /tmp/runtime.js");
}

#[test]
fn declined_command_execution_maps_to_cancelled_tool_status() {
  assert_eq!(
    command_execution_tool_status(CommandExecutionStatus::Declined, false, None),
    ToolStatus::Cancelled
  );
}

#[tokio::test]
async fn command_execution_creates_pty_without_process_id() {
  let outputs = map_item(
    ThreadItem::CommandExecution {
      id: "cmd-1".to_string(),
      command: "cargo test".to_string(),
      cwd: absolute_test_path("/tmp/orbitdock"),
      process_id: None,
      source: codex_app_server_protocol::CommandExecutionSource::Agent,
      status: CommandExecutionStatus::InProgress,
      command_actions: Vec::new(),
      aggregated_output: None,
      exit_code: None,
      duration_ms: None,
    },
    true,
    &test_route(),
  )
  .await;

  assert!(outputs.iter().any(|output| {
    matches!(
      output,
      ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyCreated { tool_id })
        if tool_id == "cmd-1"
    )
  }));
}

#[tokio::test]
async fn command_execution_output_deltas_persist_into_completed_row() {
  let route = test_route();
  let _ = map_notification(
    ServerNotification::CommandExecutionOutputDelta(CommandExecutionOutputDeltaNotification {
      thread_id: "thread-1".to_string(),
      turn_id: "turn-1".to_string(),
      item_id: "cmd-1".to_string(),
      delta: "Compiling ring v0.17.14\n".to_string(),
    }),
    &route,
  )
  .await;
  let outputs = map_notification(
    ServerNotification::ItemCompleted(ItemCompletedNotification {
      thread_id: "thread-1".to_string(),
      turn_id: "turn-1".to_string(),
      item: ThreadItem::CommandExecution {
        id: "cmd-1".to_string(),
        command: "cargo test".to_string(),
        cwd: absolute_test_path("/tmp/orbitdock"),
        process_id: None,
        source: codex_app_server_protocol::CommandExecutionSource::Agent,
        status: CommandExecutionStatus::Completed,
        command_actions: Vec::new(),
        aggregated_output: None,
        exit_code: Some(0),
        duration_ms: Some(1000),
      },
    }),
    &route,
  )
  .await;

  let state = outputs
    .iter()
    .find_map(ConnectorOutput::as_state_event)
    .expect("row update");
  let ConnectorStateEvent::ConversationRowUpdated { entry, .. } = state else {
    panic!("expected row update");
  };
  let ConversationRow::Tool(tool) = &entry.row else {
    panic!("expected tool row");
  };
  assert_eq!(tool.summary.as_deref(), Some("Compiling ring v0.17.14\n"));
  assert_eq!(
    tool.result.as_ref().unwrap()["output"],
    "Compiling ring v0.17.14\n"
  );
  assert_eq!(
    tool
      .tool_display
      .as_ref()
      .unwrap()
      .output_preview
      .as_deref(),
    Some("Compiling ring v0.17.14")
  );
  assert!(outputs.iter().any(|output| {
    matches!(
      output,
      ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyExited { tool_id, exit_code })
        if tool_id == "cmd-1" && *exit_code == Some(0)
    )
  }));
}

#[test]
fn terminal_interaction_stdin_flows_to_pty_output() {
  let outputs = map_terminal_interaction(TerminalInteractionNotification {
    thread_id: "thread-1".to_string(),
    turn_id: "turn-1".to_string(),
    item_id: "cmd-1".to_string(),
    process_id: "process-1".to_string(),
    stdin: "y\n".to_string(),
  });

  let Some(ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyOutput { tool_id, bytes })) =
    outputs.first()
  else {
    panic!("expected terminal interaction pty output");
  };
  assert_eq!(tool_id, "cmd-1");
  assert_eq!(bytes, b"y\n");

  assert!(map_terminal_interaction(TerminalInteractionNotification {
    thread_id: "thread-1".to_string(),
    turn_id: "turn-1".to_string(),
    item_id: "cmd-1".to_string(),
    process_id: "process-1".to_string(),
    stdin: String::new(),
  })
  .is_empty());
}

#[test]
fn guardian_review_notifications_keep_auto_review_tool_shape() {
  let row = guardian_review_tool_row(
    "review-1".to_string(),
    "turn-1".to_string(),
    Some("cmd-1".to_string()),
    GuardianApprovalReview {
      status: GuardianApprovalReviewStatus::Approved,
      risk_level: Some(GuardianRiskLevel::High),
      user_authorization: None,
      rationale: Some("Safe after review".to_string()),
    },
    GuardianApprovalReviewAction::Command {
      source: GuardianCommandSource::Shell,
      command: "make test".to_string(),
      cwd: absolute_test_path("/tmp/orbitdock"),
    },
    false,
  );

  assert_eq!(row.id, "guardian-review-1");
  assert_eq!(row.family, ToolFamily::Approval);
  assert_eq!(row.kind, ToolKind::GuardianAssessment);
  assert_eq!(row.status, ToolStatus::Completed);
  assert_eq!(row.grouping_key.as_deref(), Some("turn-1"));
  assert_eq!(row.invocation["action"]["command"], "make test");

  let entry = tool_row_entry(row);
  let ConversationRow::Tool(tool) = entry.row else {
    panic!("expected guardian tool row");
  };
  let display = tool.tool_display.expect("tool display");
  assert_eq!(display.tool_type, "guardianAssessment");
  assert_eq!(display.summary, "Safe after review");
  assert_eq!(display.subtitle.as_deref(), Some("high risk"));
}

#[test]
fn collab_agent_item_keeps_agent_tool_and_subagent_state() {
  let outputs = map_collab_agent_tool(CollabAgentToolCallArgs {
    id: "collab-1".to_string(),
    tool: CollabAgentTool::SpawnAgent,
    status: CollabAgentToolCallStatus::Completed,
    sender_thread_id: "parent-thread".to_string(),
    receiver_thread_ids: vec!["child-thread".to_string()],
    prompt: Some("Inspect the codebase".to_string()),
    model: Some("gpt-5.4-mini".to_string()),
    reasoning_effort: Some("medium".to_string()),
    agents_states: HashMap::from([(
      "child-thread".to_string(),
      CollabAgentState {
        status: CollabAgentStatus::Completed,
        message: Some("Done".to_string()),
      },
    )]),
    started: false,
  });

  let row_event = outputs
    .first()
    .and_then(ConnectorOutput::as_state_event)
    .expect("row update");
  let ConnectorStateEvent::ConversationRowUpdated { entry, .. } = row_event else {
    panic!("expected collab row update");
  };
  let ConversationRow::Tool(tool) = &entry.row else {
    panic!("expected collab tool row");
  };
  assert_eq!(tool.family, ToolFamily::Agent);
  assert_eq!(tool.kind, ToolKind::SpawnAgent);
  assert_eq!(tool.status, ToolStatus::Completed);
  assert_eq!(tool.invocation["worker_id"], "child-thread");

  let subagents_event = outputs
    .get(1)
    .and_then(ConnectorOutput::as_state_event)
    .expect("subagent update");
  let ConnectorStateEvent::SubagentsUpdated { subagents } = subagents_event else {
    panic!("expected subagents update");
  };
  assert_eq!(subagents.len(), 1);
  assert_eq!(subagents[0].id, "child-thread");
  assert_eq!(subagents[0].status, SubagentStatus::Completed);
  assert_eq!(
    subagents[0].task_summary.as_deref(),
    Some("Inspect the codebase")
  );
}

#[tokio::test]
async fn review_mode_items_surface_review_text() {
  let notice = map_item(
    ThreadItem::EnteredReviewMode {
      id: "review-enter".to_string(),
      review: "Review requested".to_string(),
    },
    false,
    &test_route(),
  )
  .await;
  let output = notice
    .into_iter()
    .next()
    .and_then(|output| output.as_state_event().cloned())
    .expect("notice row");
  let ConnectorStateEvent::ConversationRowCreated(entry) = output else {
    panic!("expected created row");
  };
  let ConversationRow::Notice(row) = entry.row else {
    panic!("expected notice row");
  };
  assert_eq!(row.title, "Review mode");
  assert_eq!(row.summary.as_deref(), Some("Review requested"));

  let assistant = map_item(
    ThreadItem::ExitedReviewMode {
      id: "review-exit".to_string(),
      review: "## Code Review Feedback".to_string(),
    },
    false,
    &test_route(),
  )
  .await
  .into_iter()
  .next()
  .and_then(|output| output.as_state_event().cloned())
  .expect("assistant row");
  let ConnectorStateEvent::ConversationRowCreated(entry) = assistant else {
    panic!("expected created row");
  };
  let ConversationRow::Assistant(row) = entry.row else {
    panic!("expected assistant row");
  };
  assert_eq!(row.content, "## Code Review Feedback");
}

fn test_route() -> AppServerSessionRoute {
  let (output_tx, _) = mpsc::channel(1);
  AppServerSessionRoute::new(
    output_tx,
    Arc::new(Mutex::new(None)),
    Arc::new(Mutex::new(HashMap::new())),
  )
}
