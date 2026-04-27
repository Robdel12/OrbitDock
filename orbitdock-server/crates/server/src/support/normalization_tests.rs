use std::collections::HashMap;

use serde_json::{Map, Value};

use super::{
  build_question_answers, normalize_permission_response, normalize_question_answers,
  work_status_for_approval_decision,
};

#[test]
fn build_question_answers_uses_structured_answers_when_present() {
  let mut answers = HashMap::new();
  answers.insert(
    "question-a".to_string(),
    vec![" yes ".to_string(), "".to_string()],
  );

  let built = build_question_answers("fallback", Some("question-b"), Some(answers));

  assert_eq!(built.get("question-a"), Some(&vec!["yes".to_string()]));
  assert!(!built.contains_key("question-b"));
}

#[test]
fn build_question_answers_falls_back_to_plain_answer() {
  let built = build_question_answers("  Ship it  ", Some("question-a"), None);

  assert_eq!(built.get("question-a"), Some(&vec!["Ship it".to_string()]));
}

#[test]
fn normalize_question_answers_drops_blank_keys_and_values() {
  let mut raw = HashMap::new();
  raw.insert(" ".to_string(), vec!["ignored".to_string()]);
  raw.insert(
    "question-a".to_string(),
    vec![" ".to_string(), "answer".to_string()],
  );

  let normalized = normalize_question_answers(Some(raw));

  assert_eq!(normalized.len(), 1);
  assert_eq!(
    normalized.get("question-a"),
    Some(&vec!["answer".to_string()])
  );
}

#[test]
fn approval_decision_work_status_keeps_tooling_active_for_continue_actions() {
  assert_eq!(
    work_status_for_approval_decision("approved"),
    orbitdock_protocol::WorkStatus::Working
  );
  assert_eq!(
    work_status_for_approval_decision("approved_for_session"),
    orbitdock_protocol::WorkStatus::Working
  );
  assert_eq!(
    work_status_for_approval_decision("approved_always"),
    orbitdock_protocol::WorkStatus::Working
  );
  assert_eq!(
    work_status_for_approval_decision("denied"),
    orbitdock_protocol::WorkStatus::Working
  );
  assert_eq!(
    work_status_for_approval_decision("abort"),
    orbitdock_protocol::WorkStatus::Waiting
  );
  assert_eq!(
    work_status_for_approval_decision("unknown_value"),
    orbitdock_protocol::WorkStatus::Waiting
  );
}

#[test]
fn normalize_permission_response_defaults_to_empty_object() {
  assert_eq!(
    normalize_permission_response(None).expect("empty permissions"),
    Value::Object(Map::new())
  );
}

#[test]
fn normalize_permission_response_rejects_non_object_values() {
  assert_eq!(
    normalize_permission_response(Some(Value::String("nope".to_string()))),
    Err("invalid_permissions_payload")
  );
}
