use crate::runtime::{
  apply_delta_thinking, finalized_thinking_row_entry, row_entry, thinking_row_entry,
  RawToolCallContext, ReasoningEventTracker, StreamingMessage, STREAM_THROTTLE_MS,
};
use crate::timeline::{render_review_output, review_request_summary};
use crate::workers::iso_now;
use codex_protocol::items::TurnItem;
use codex_protocol::models::ResponseItem;
use codex_protocol::protocol::ReviewRequest;
use codex_protocol::protocol::{
  AgentMessageContentDeltaEvent, AgentMessageDeltaEvent, AgentReasoningDeltaEvent,
  AgentReasoningRawContentDeltaEvent, AgentReasoningRawContentEvent, ExitedReviewModeEvent,
  ItemCompletedEvent, ItemStartedEvent, RawResponseItemEvent, ReasoningContentDeltaEvent,
  ReasoningRawContentDeltaEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::{
  classify_tool_name, compute_tool_display, extract_compact_result_text, ConversationRow,
  ConversationRowEntry, MessageRowContent, ToolDisplayInput, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::Provider;
use serde_json::json;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

fn tool_row_entry(row: ToolRow) -> ConversationRowEntry {
  let row = with_display(row);
  row_entry(ConversationRow::Tool(row))
}

fn with_display(mut row: ToolRow) -> ToolRow {
  let invocation_ref = row.invocation.is_object().then_some(&row.invocation);
  let result_str = extract_compact_result_text(row.result.as_ref());
  row.tool_display = Some(compute_tool_display(ToolDisplayInput {
    kind: row.kind,
    family: row.family,
    status: row.status,
    title: &row.title,
    subtitle: row.subtitle.as_deref(),
    summary: row.summary.as_deref(),
    duration_ms: row.duration_ms,
    invocation_input: invocation_ref,
    result_output: result_str.as_deref(),
  }));
  row
}

fn raw_tool_output_text(output: &codex_protocol::models::FunctionCallOutputPayload) -> String {
  output
    .body
    .to_text()
    .or_else(|| serde_json::to_string(output).ok())
    .unwrap_or_default()
}

fn should_surface_raw_function_tool(kind: ToolKind) -> bool {
  matches!(
    kind,
    ToolKind::Read | ToolKind::Glob | ToolKind::Grep | ToolKind::ToolSearch
  )
}

fn normalize_function_arguments(arguments: &str) -> serde_json::Value {
  serde_json::from_str(arguments).unwrap_or_else(|_| json!({ "raw": arguments }))
}

pub(crate) async fn handle_agent_message_content_delta(
  event: AgentMessageContentDeltaEvent,
  streaming_message: &Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
) -> Vec<ConnectorEvent> {
  let mut streaming = streaming_message.lock().await;
  match streaming.as_mut() {
    None => {
      let msg_id = event.item_id.clone();
      let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: msg_id.clone(),
        content: event.delta.clone(),
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: true,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }));
      *streaming = Some(StreamingMessage {
        message_id: msg_id,
        content: event.delta,
        last_broadcast: std::time::Instant::now(),
        from_content_delta: true,
      });
      vec![ConnectorEvent::ConversationRowCreated(entry)]
    }
    Some(streaming_msg) => {
      streaming_msg.content.push_str(&event.delta);
      let now = std::time::Instant::now();
      if now.duration_since(streaming_msg.last_broadcast).as_millis() >= STREAM_THROTTLE_MS {
        streaming_msg.last_broadcast = now;
        let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
          id: streaming_msg.message_id.clone(),
          content: streaming_msg.content.clone(),
          turn_id: None,
          timestamp: Some(iso_now()),
          is_streaming: true,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        }));
        vec![ConnectorEvent::ConversationRowUpdated {
          row_id: streaming_msg.message_id.clone(),
          entry,
        }]
      } else {
        vec![]
      }
    }
  }
}

pub(crate) async fn handle_agent_message_delta(
  event_id: &str,
  event: AgentMessageDeltaEvent,
  streaming_message: &Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
) -> Vec<ConnectorEvent> {
  let mut streaming = streaming_message.lock().await;
  match streaming.as_mut() {
    None => {
      let msg_id = event_id.to_string();
      let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: msg_id.clone(),
        content: event.delta.clone(),
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: true,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }));
      *streaming = Some(StreamingMessage {
        message_id: msg_id,
        content: event.delta,
        last_broadcast: std::time::Instant::now(),
        from_content_delta: false,
      });
      vec![ConnectorEvent::ConversationRowCreated(entry)]
    }
    Some(streaming_msg) => {
      if streaming_msg.from_content_delta {
        return vec![];
      }
      streaming_msg.content.push_str(&event.delta);
      let now = std::time::Instant::now();
      if now.duration_since(streaming_msg.last_broadcast).as_millis() < STREAM_THROTTLE_MS {
        return vec![];
      }
      streaming_msg.last_broadcast = now;
      let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: streaming_msg.message_id.clone(),
        content: streaming_msg.content.clone(),
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: true,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }));
      vec![ConnectorEvent::ConversationRowUpdated {
        row_id: streaming_msg.message_id.clone(),
        entry,
      }]
    }
  }
}

pub(crate) async fn handle_reasoning_content_delta(
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
  event: ReasoningContentDeltaEvent,
) -> Vec<ConnectorEvent> {
  let should_process = {
    let mut tracker = reasoning_tracker.lock().await;
    tracker.should_process_modern_summary()
  };
  if !should_process {
    return vec![];
  }
  apply_delta_thinking(
    delta_buffers,
    format!(
      "reasoning-summary-{}-{}",
      event.item_id, event.summary_index
    ),
    event.delta,
  )
  .await
}

pub(crate) async fn handle_reasoning_raw_content_delta(
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
  event: ReasoningRawContentDeltaEvent,
) -> Vec<ConnectorEvent> {
  let should_process = {
    let mut tracker = reasoning_tracker.lock().await;
    tracker.should_process_modern_raw()
  };
  if !should_process {
    return vec![];
  }
  apply_delta_thinking(
    delta_buffers,
    format!("reasoning-raw-{}-{}", event.item_id, event.content_index),
    event.delta,
  )
  .await
}

pub(crate) async fn handle_agent_reasoning_delta(
  event_id: &str,
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
  event: AgentReasoningDeltaEvent,
) -> Vec<ConnectorEvent> {
  let should_process = {
    let mut tracker = reasoning_tracker.lock().await;
    tracker.should_process_legacy_summary()
  };
  if !should_process {
    return vec![];
  }
  apply_delta_thinking(
    delta_buffers,
    format!("reasoning-summary-legacy-{}", event_id),
    event.delta,
  )
  .await
}

pub(crate) async fn handle_agent_reasoning_raw_content(
  event_id: &str,
  event: AgentReasoningRawContentEvent,
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
  msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
  let should_process = {
    let mut tracker = reasoning_tracker.lock().await;
    tracker.should_process_legacy_raw()
  };
  if !should_process {
    return vec![];
  }
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
  let entry = thinking_row_entry(format!("reasoning-raw-{}-{}", event_id, seq), event.text);
  vec![ConnectorEvent::ConversationRowCreated(entry)]
}

pub(crate) async fn handle_agent_reasoning_raw_content_delta(
  event_id: &str,
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
  event: AgentReasoningRawContentDeltaEvent,
) -> Vec<ConnectorEvent> {
  let should_process = {
    let mut tracker = reasoning_tracker.lock().await;
    tracker.should_process_legacy_raw()
  };
  if !should_process {
    return vec![];
  }
  apply_delta_thinking(
    delta_buffers,
    format!("reasoning-raw-legacy-{}", event_id),
    event.delta,
  )
  .await
}

pub(crate) async fn handle_agent_reasoning_section_break(
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
) -> Vec<ConnectorEvent> {
  let mut tracker = reasoning_tracker.lock().await;
  tracker.mark_modern_summary_seen();
  vec![]
}

pub(crate) fn handle_entered_review_mode(
  event_id: &str,
  event: ReviewRequest,
  msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
  let summary = review_request_summary(&event);
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);

  vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
    ToolRow {
      id: format!("review-entered-{}-{}", event_id, seq),
      provider: Provider::Codex,
      family: ToolFamily::Plan,
      kind: ToolKind::EnterPlanMode,
      status: ToolStatus::Completed,
      title: "Enter review mode".to_string(),
      subtitle: None,
      summary: Some(summary),
      preview: None,
      started_at: Some(iso_now()),
      ended_at: Some(iso_now()),
      duration_ms: None,
      grouping_key: None,
      invocation: json!({
          "mode": "review",
          "steps": [],
          "review_mode": "enter",
      }),
      result: None,
      render_hints: Default::default(),
      tool_display: None,
    },
  ))]
}

pub(crate) fn handle_exited_review_mode(
  event_id: &str,
  event: ExitedReviewModeEvent,
  msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
  let output = event
    .review_output
    .map(|review_output| render_review_output(&review_output))
    .unwrap_or_else(|| "Review mode exited.".to_string());

  vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
    ToolRow {
      id: format!("review-exited-{}-{}", event_id, seq),
      provider: Provider::Codex,
      family: ToolFamily::Plan,
      kind: ToolKind::ExitPlanMode,
      status: ToolStatus::Completed,
      title: "Exit review mode".to_string(),
      subtitle: None,
      summary: Some(output.clone()),
      preview: None,
      started_at: Some(iso_now()),
      ended_at: Some(iso_now()),
      duration_ms: None,
      grouping_key: None,
      invocation: json!({
          "mode": "review",
          "steps": [],
          "review_mode": "exit",
      }),
      result: Some(json!({
          "tool_name": "task",
          "raw_output": output.clone(),
          "summary": output,
      })),
      render_hints: Default::default(),
      tool_display: None,
    },
  ))]
}

pub(crate) async fn handle_item_started(
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  event: ItemStartedEvent,
) -> Vec<ConnectorEvent> {
  match event.item {
    TurnItem::Plan(item) => {
      apply_delta_thinking(delta_buffers, format!("plan-{}", item.id), item.text).await
    }
    TurnItem::ContextCompaction(item) => {
      vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
          id: item.id,
          provider: Provider::Codex,
          family: ToolFamily::Context,
          kind: ToolKind::CompactContext,
          status: ToolStatus::Running,
          title: "Compacting context".to_string(),
          subtitle: None,
          summary: None,
          preview: None,
          started_at: Some(iso_now()),
          ended_at: None,
          duration_ms: None,
          grouping_key: None,
          invocation: json!({}),
          result: None,
          render_hints: Default::default(),
          tool_display: None,
        },
      ))]
    }
    _ => vec![],
  }
}

pub(crate) async fn handle_item_completed(
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  event: ItemCompletedEvent,
) -> Vec<ConnectorEvent> {
  match event.item {
    TurnItem::Plan(item) => {
      let message_id = format!("plan-{}", item.id);
      {
        let mut buffers = delta_buffers.lock().await;
        buffers.remove(&message_id);
      }
      let entry = finalized_thinking_row_entry(message_id.clone(), item.text);
      vec![ConnectorEvent::ConversationRowUpdated {
        row_id: message_id,
        entry,
      }]
    }
    TurnItem::Reasoning(item) => {
      let mut events: Vec<ConnectorEvent> = Vec::new();

      for (idx, summary) in item.summary_text.into_iter().enumerate() {
        let message_id = format!("reasoning-summary-{}-{}", item.id, idx);
        let had_buffer = {
          let mut buffers = delta_buffers.lock().await;
          buffers.remove(&message_id).is_some()
        };
        let entry = finalized_thinking_row_entry(message_id.clone(), summary);
        if had_buffer {
          events.push(ConnectorEvent::ConversationRowUpdated {
            row_id: message_id,
            entry,
          });
        } else {
          events.push(ConnectorEvent::ConversationRowCreated(entry));
        }
      }

      for (idx, raw) in item.raw_content.into_iter().enumerate() {
        let message_id = format!("reasoning-raw-{}-{}", item.id, idx);
        let had_buffer = {
          let mut buffers = delta_buffers.lock().await;
          buffers.remove(&message_id).is_some()
        };
        let entry = finalized_thinking_row_entry(message_id.clone(), raw);
        if had_buffer {
          events.push(ConnectorEvent::ConversationRowUpdated {
            row_id: message_id,
            entry,
          });
        } else {
          events.push(ConnectorEvent::ConversationRowCreated(entry));
        }
      }

      events
    }
    TurnItem::ContextCompaction(item) => {
      let entry = tool_row_entry(ToolRow {
        id: item.id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Context,
        kind: ToolKind::CompactContext,
        status: ToolStatus::Completed,
        title: "Context compacted".to_string(),
        subtitle: None,
        summary: Some("Context compacted".to_string()),
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: json!({
            "summary": "Context compacted",
        }),
        result: Some(json!({
            "summary": "Context compacted",
        })),
        render_hints: Default::default(),
        tool_display: None,
      });
      vec![ConnectorEvent::ConversationRowUpdated {
        row_id: item.id,
        entry,
      }]
    }
    _ => vec![],
  }
}

pub(crate) async fn handle_raw_response_item(
  event_id: &str,
  event: RawResponseItemEvent,
  msg_counter: &AtomicU64,
  raw_tool_calls: &Arc<tokio::sync::Mutex<HashMap<String, RawToolCallContext>>>,
) -> Vec<ConnectorEvent> {
  match event.item {
    ResponseItem::FunctionCall {
      name,
      arguments,
      call_id,
      ..
    } => {
      let (family, kind) = classify_tool_name(&name);
      if !should_surface_raw_function_tool(kind) {
        return vec![];
      }

      let invocation = normalize_function_arguments(&arguments);
      let started_at = iso_now();
      let row = ToolRow {
        id: call_id.clone(),
        provider: Provider::Codex,
        family,
        kind,
        status: ToolStatus::Running,
        title: name.clone(),
        subtitle: None,
        summary: None,
        preview: None,
        started_at: Some(started_at.clone()),
        ended_at: None,
        duration_ms: None,
        grouping_key: None,
        invocation,
        result: None,
        render_hints: Default::default(),
        tool_display: None,
      };

      raw_tool_calls.lock().await.insert(
        call_id.clone(),
        RawToolCallContext {
          title: name,
          family,
          kind,
          invocation: row.invocation.clone(),
          started_at,
        },
      );

      vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(row))]
    }
    ResponseItem::FunctionCallOutput { call_id, output } => {
      let Some(context) = raw_tool_calls.lock().await.remove(&call_id) else {
        return vec![];
      };

      let output_text = raw_tool_output_text(&output);
      let row = ToolRow {
        id: call_id.clone(),
        provider: Provider::Codex,
        family: context.family,
        kind: context.kind,
        status: ToolStatus::Completed,
        title: context.title.clone(),
        subtitle: None,
        summary: None,
        preview: None,
        started_at: Some(context.started_at),
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: context.invocation,
        result: Some(json!({
            "tool_name": context.title,
            "output": output_text,
        })),
        render_hints: Default::default(),
        tool_display: None,
      };

      vec![ConnectorEvent::ConversationRowUpdated {
        row_id: call_id,
        entry: tool_row_entry(row),
      }]
    }
    ResponseItem::ToolSearchCall {
      call_id: Some(call_id),
      arguments,
      ..
    } => {
      let title = "ToolSearch".to_string();
      let family = ToolFamily::Search;
      let kind = ToolKind::ToolSearch;
      let started_at = iso_now();
      let row = ToolRow {
        id: call_id.clone(),
        provider: Provider::Codex,
        family,
        kind,
        status: ToolStatus::Running,
        title: title.clone(),
        subtitle: None,
        summary: None,
        preview: None,
        started_at: Some(started_at.clone()),
        ended_at: None,
        duration_ms: None,
        grouping_key: None,
        invocation: arguments.clone(),
        result: None,
        render_hints: Default::default(),
        tool_display: None,
      };

      raw_tool_calls.lock().await.insert(
        call_id.clone(),
        RawToolCallContext {
          title,
          family,
          kind,
          invocation: arguments,
          started_at,
        },
      );

      vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(row))]
    }
    ResponseItem::ToolSearchOutput {
      call_id: Some(call_id),
      tools,
      ..
    } => {
      let Some(context) = raw_tool_calls.lock().await.remove(&call_id) else {
        return vec![];
      };

      let output_text = serde_json::to_string_pretty(&tools)
        .or_else(|_| serde_json::to_string(&tools))
        .unwrap_or_default();

      let row = ToolRow {
        id: call_id.clone(),
        provider: Provider::Codex,
        family: context.family,
        kind: context.kind,
        status: ToolStatus::Completed,
        title: context.title.clone(),
        subtitle: None,
        summary: None,
        preview: None,
        started_at: Some(context.started_at),
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: context.invocation,
        result: Some(json!({
            "tool_name": context.title,
            "output": output_text,
        })),
        render_hints: Default::default(),
        tool_display: None,
      };

      vec![ConnectorEvent::ConversationRowUpdated {
        row_id: call_id,
        entry: tool_row_entry(row),
      }]
    }
    ResponseItem::Other => {
      let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
      let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: format!("raw-response-item-{}-{}", event_id, seq),
        content: "Received unsupported raw response item.".to_string(),
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }));
      vec![ConnectorEvent::ConversationRowCreated(entry)]
    }
    _ => vec![],
  }
}
