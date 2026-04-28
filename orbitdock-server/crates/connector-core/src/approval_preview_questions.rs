use orbitdock_protocol::{ApprovalQuestionOption, ApprovalQuestionPrompt};
use serde_json::{Map as JsonMap, Value as JsonValue};

use super::{parse_tool_input_object, trim_non_empty, trim_non_empty_str};

pub(super) fn approval_question_prompts(
  tool_input: Option<&str>,
  fallback_question: Option<&str>,
) -> Vec<ApprovalQuestionPrompt> {
  extract_question_prompts_for_approval(tool_input, fallback_question)
}

pub(super) fn approval_question(
  tool_input: Option<&str>,
  fallback_question: Option<&str>,
) -> Option<String> {
  let prompts = approval_question_prompts(tool_input, fallback_question);
  prompts
    .first()
    .map(|prompt| prompt.question.clone())
    .filter(|text| !text.is_empty())
    .or_else(|| trim_non_empty(fallback_question))
}

fn parse_bool_value(value: Option<&JsonValue>) -> bool {
  let Some(value) = value else {
    return false;
  };
  if let Some(flag) = value.as_bool() {
    return flag;
  }
  if let Some(number) = value.as_u64() {
    return number > 0;
  }
  if let Some(text) = value.as_str() {
    let normalized = text.trim().to_ascii_lowercase();
    return normalized == "true" || normalized == "1" || normalized == "yes";
  }
  false
}

fn parse_question_options_from_json(value: Option<&JsonValue>) -> Vec<ApprovalQuestionOption> {
  let Some(options) = value.and_then(JsonValue::as_array) else {
    return vec![];
  };

  options
    .iter()
    .filter_map(|raw_option| {
      let option = raw_option.as_object()?;
      let label = option
        .get("label")
        .or_else(|| option.get("value"))
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str)?;
      let description = option
        .get("description")
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str);
      Some(ApprovalQuestionOption { label, description })
    })
    .collect()
}

fn parse_question_prompt_from_json(
  payload: &JsonMap<String, JsonValue>,
  fallback_id: &str,
) -> Option<ApprovalQuestionPrompt> {
  let id = payload
    .get("id")
    .and_then(JsonValue::as_str)
    .and_then(trim_non_empty_str)
    .unwrap_or_else(|| fallback_id.to_string());
  let header = payload
    .get("header")
    .and_then(JsonValue::as_str)
    .and_then(trim_non_empty_str);
  let question = payload
    .get("question")
    .and_then(JsonValue::as_str)
    .and_then(trim_non_empty_str)
    .unwrap_or_else(|| "Question".to_string());
  if question.is_empty() {
    return None;
  }

  Some(ApprovalQuestionPrompt {
    id,
    header,
    question,
    options: parse_question_options_from_json(payload.get("options")),
    allows_multiple_selection: parse_bool_value(
      payload
        .get("multiSelect")
        .or_else(|| payload.get("multi_select")),
    ),
    allows_other: parse_bool_value(payload.get("isOther").or_else(|| payload.get("is_other"))),
    is_secret: parse_bool_value(payload.get("isSecret").or_else(|| payload.get("is_secret"))),
  })
}

fn parse_question_prompts_from_tool_input(tool_input: Option<&str>) -> Vec<ApprovalQuestionPrompt> {
  let Some(input) = parse_tool_input_object(tool_input) else {
    return vec![];
  };

  if let Some(raw_questions) = input.get("questions").and_then(JsonValue::as_array) {
    return raw_questions
      .iter()
      .enumerate()
      .filter_map(|(index, raw_question)| {
        let payload = raw_question.as_object()?;
        parse_question_prompt_from_json(payload, index.to_string().as_str())
      })
      .collect();
  }

  if input.contains_key("question") || input.contains_key("options") {
    if let Some(prompt) = parse_question_prompt_from_json(&input, "0") {
      return vec![prompt];
    }
  }

  vec![]
}

fn extract_question_prompts_for_approval(
  tool_input: Option<&str>,
  fallback_question: Option<&str>,
) -> Vec<ApprovalQuestionPrompt> {
  let prompts = parse_question_prompts_from_tool_input(tool_input);
  if !prompts.is_empty() {
    return prompts;
  }

  let Some(question) = trim_non_empty(fallback_question) else {
    return vec![];
  };

  vec![ApprovalQuestionPrompt {
    id: "0".to_string(),
    header: None,
    question,
    options: vec![],
    allows_multiple_selection: false,
    allows_other: true,
    is_secret: false,
  }]
}
