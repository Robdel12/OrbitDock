//! Input normalization and validation helpers.
//!
//! Pure functions for sanitizing user-supplied strings, model overrides,
//! question/answer maps, and approval decisions. Shared by WebSocket
//! handlers and other server components.

use std::collections::HashMap;

use serde_json::{Map, Value};

pub(crate) fn normalize_non_empty(value: Option<String>) -> Option<String> {
  value
    .as_deref()
    .map(str::trim)
    .filter(|v| !v.is_empty())
    .map(str::to_string)
}

pub(crate) fn is_provider_placeholder_model(model: &str) -> bool {
  matches!(
    model.trim().to_ascii_lowercase().as_str(),
    "openai" | "anthropic"
  )
}

pub(crate) fn normalize_model_override(value: Option<String>) -> Option<String> {
  normalize_non_empty(value).filter(|model| !is_provider_placeholder_model(model))
}

pub(crate) fn normalize_question_answers(
  raw_answers: Option<HashMap<String, Vec<String>>>,
) -> HashMap<String, Vec<String>> {
  let Some(raw_answers) = raw_answers else {
    return HashMap::new();
  };

  let mut normalized = HashMap::new();
  for (raw_question_id, raw_values) in raw_answers {
    let question_id = raw_question_id.trim();
    if question_id.is_empty() {
      continue;
    }

    let values: Vec<String> = raw_values
      .into_iter()
      .map(|value| value.trim().to_string())
      .filter(|value| !value.is_empty())
      .collect();
    if values.is_empty() {
      continue;
    }

    normalized.insert(question_id.to_string(), values);
  }

  normalized
}

pub(crate) fn build_question_answers(
  answer: &str,
  question_id: Option<&str>,
  raw_answers: Option<HashMap<String, Vec<String>>>,
) -> HashMap<String, Vec<String>> {
  let mut normalized = normalize_question_answers(raw_answers);
  let trimmed_answer = answer.trim();
  if normalized.is_empty() && !trimmed_answer.is_empty() {
    let key = question_id
      .map(str::trim)
      .filter(|value| !value.is_empty())
      .unwrap_or("0");
    normalized.insert(key.to_string(), vec![trimmed_answer.to_string()]);
  }
  normalized
}

pub(crate) fn normalize_permission_response(
  raw_permissions: Option<Value>,
) -> Result<Value, &'static str> {
  match raw_permissions {
    None | Some(Value::Null) => Ok(Value::Object(Map::new())),
    Some(Value::Object(map)) => Ok(Value::Object(map)),
    Some(_) => Err("invalid_permissions_payload"),
  }
}

pub(crate) fn work_status_for_approval_decision(decision: &str) -> orbitdock_protocol::WorkStatus {
  let normalized = decision.trim().to_lowercase();
  if matches!(
    normalized.as_str(),
    "approved" | "approved_for_session" | "approved_always" | "denied" | "deny"
  ) {
    orbitdock_protocol::WorkStatus::Working
  } else {
    orbitdock_protocol::WorkStatus::Waiting
  }
}

#[cfg(test)]
#[path = "normalization_tests.rs"]
mod tests;
