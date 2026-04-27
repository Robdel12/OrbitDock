use super::*;

fn system_message(id: &str, content: &str) -> ConversationRow {
  ConversationRow::System(MessageRowContent {
    id: id.to_string(),
    content: content.to_string(),
    turn_id: None,
    timestamp: None,
    is_streaming: false,
    images: vec![],
    memory_citation: None,
    delivery_status: None,
  })
}

#[test]
fn parses_environment_context() {
  let row = upgrade_row(system_message(
            "row-1",
            "<environment_context>\n  <cwd>/tmp/project</cwd>\n  <shell>zsh</shell>\n</environment_context>",
        ));

  match row {
    ConversationRow::Context(context) => {
      assert_eq!(context.kind, ContextRowKind::Environment);
      assert_eq!(context.cwd.as_deref(), Some("/tmp/project"));
      assert_eq!(context.shell.as_deref(), Some("zsh"));
    }
    other => panic!("expected context row, got {other:?}"),
  }
}

#[test]
fn strips_image_markers_from_messages() {
  let row = upgrade_row(ConversationRow::Assistant(MessageRowContent {
    id: "row-2".to_string(),
    content: "<image name=[Image #1]>\n</image>\nHello".to_string(),
    turn_id: None,
    timestamp: None,
    is_streaming: false,
    images: vec![],
    memory_citation: None,
    delivery_status: None,
  }));

  match row {
    ConversationRow::Assistant(message) => assert_eq!(message.content, "Hello"),
    other => panic!("expected assistant row, got {other:?}"),
  }
}

#[test]
fn parses_task_notification() {
  let row = upgrade_row(system_message(
            "row-3",
            "<task-notification>\n<task-id>abc</task-id>\n<status>failed</status>\n<summary>Task failed</summary>\n</task-notification>\nRead the output file.",
        ));

  match row {
    ConversationRow::Task(task) => {
      assert_eq!(task.status, TaskRowStatus::Failed);
      assert_eq!(task.task_id.as_deref(), Some("abc"));
    }
    other => panic!("expected task row, got {other:?}"),
  }
}

#[test]
fn parses_permissions_instructions() {
  let row = upgrade_row(system_message(
    "row-4",
    "<permissions instructions>\nOnly read files unless asked.\n</permissions instructions>",
  ));

  match row {
    ConversationRow::Context(context) => {
      assert_eq!(context.title, "Permissions instructions");
    }
    other => panic!("expected context row, got {other:?}"),
  }
}

#[test]
fn reports_handled_wrapper_inventory() {
  assert!(handled_wrappers().contains(&"environment_context"));
  assert!(handled_wrappers().contains(&"image_marker"));
}
