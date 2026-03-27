use orbitdock_protocol::Provider;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::domain::mission_control::skills::{read_skill_content_for_claude, resolve_skill_inputs};
use crate::runtime::session_registry::SessionRegistry;

pub(crate) async fn send_initial_prompt(
  registry: &SessionRegistry,
  session_id: &str,
  provider: Provider,
  prompt: &str,
  model: Option<String>,
  effort: Option<String>,
  skills: &[String],
) {
  match provider {
    Provider::Codex => {
      let mission_skills = resolve_skill_inputs(skills);
      if let Some(tx) = registry.get_codex_action_tx(session_id) {
        let _ = tx
          .send(CodexAction::SendMessage {
            content: prompt.to_string(),
            model,
            effort,
            skills: mission_skills,
            images: vec![],
            mentions: vec![],
          })
          .await;
      }
    }
    Provider::Claude => {
      let claude_prompt = match read_skill_content_for_claude(skills) {
        Some(skill_content) => format!("{skill_content}\n\n{prompt}"),
        None => prompt.to_string(),
      };
      if let Some(tx) = registry.get_claude_action_tx(session_id) {
        let _ = tx
          .send(ClaudeAction::SendMessage {
            content: claude_prompt,
            model,
            effort,
            images: vec![],
          })
          .await;
      }
    }
  }
}
