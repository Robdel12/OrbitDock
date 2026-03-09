//! Input normalization and validation helpers.
//!
//! Pure functions for sanitizing user-supplied strings, model overrides,
//! question/answer maps, and approval decisions. Shared by WebSocket
//! handlers and other server components.

use std::collections::HashMap;

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
mod tests {
    use std::collections::HashMap;

    use super::{
        build_question_answers, normalize_question_answers, work_status_for_approval_decision,
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
}
