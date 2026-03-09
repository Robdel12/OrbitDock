use tokio::sync::mpsc;

use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionState, SessionSummary,
};

use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::PersistCommand;

pub(crate) struct DirectSessionCreationInputs {
    pub id: String,
    pub provider: Provider,
    pub cwd: String,
    pub git_branch: Option<String>,
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub effort: Option<String>,
}

pub(crate) struct PreparedDirectSession {
    pub project_name: Option<String>,
    pub handle: SessionHandle,
    pub summary: SessionSummary,
    pub snapshot: SessionState,
}

pub(crate) fn prepare_direct_session(input: DirectSessionCreationInputs) -> PreparedDirectSession {
    let project_name = input.cwd.split('/').next_back().map(String::from);
    let mut handle = SessionHandle::new(input.id, input.provider, input.cwd);
    handle.set_git_branch(input.git_branch);

    if let Some(ref model) = input.model {
        handle.set_model(Some(model.clone()));
    }
    if let Some(ref effort) = input.effort {
        handle.set_effort(Some(effort.clone()));
    }

    if input.provider == Provider::Codex {
        handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
        handle.set_config(input.approval_policy, input.sandbox_mode);
    } else if input.provider == Provider::Claude {
        handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
    }

    let summary = handle.summary();
    let snapshot = handle.retained_state();

    PreparedDirectSession {
        project_name,
        handle,
        summary,
        snapshot,
    }
}

pub(crate) async fn persist_direct_session_create(
    persist_tx: &mpsc::Sender<PersistCommand>,
    id: String,
    provider: Provider,
    project_path: String,
    project_name: Option<String>,
    branch: Option<String>,
    model: Option<String>,
    approval_policy: Option<String>,
    sandbox_mode: Option<String>,
    permission_mode: Option<String>,
    effort: Option<String>,
) {
    let _ = persist_tx
        .send(PersistCommand::SessionCreate {
            id: id.clone(),
            provider,
            project_path,
            project_name,
            branch,
            model,
            approval_policy,
            sandbox_mode,
            permission_mode,
            forked_from_session_id: None,
        })
        .await;

    if let Some(effort_name) = effort {
        let _ = persist_tx
            .send(PersistCommand::EffortUpdate {
                session_id: id,
                effort: Some(effort_name),
            })
            .await;
    }
}

#[cfg(test)]
mod tests {
    use super::{prepare_direct_session, DirectSessionCreationInputs};
    use orbitdock_protocol::{ClaudeIntegrationMode, CodexIntegrationMode, Provider};

    #[test]
    fn prepare_direct_session_sets_codex_direct_state_and_config() {
        let prepared = prepare_direct_session(DirectSessionCreationInputs {
            id: "session-1".into(),
            provider: Provider::Codex,
            cwd: "/tmp/project".into(),
            git_branch: Some("main".into()),
            model: Some("gpt-5".into()),
            approval_policy: Some("on-request".into()),
            sandbox_mode: Some("workspace-write".into()),
            effort: Some("high".into()),
        });

        assert_eq!(prepared.project_name.as_deref(), Some("project"));
        assert_eq!(
            prepared.summary.codex_integration_mode,
            Some(CodexIntegrationMode::Direct)
        );
        assert_eq!(prepared.snapshot.model.as_deref(), Some("gpt-5"));
        assert_eq!(prepared.snapshot.effort.as_deref(), Some("high"));
        assert_eq!(
            prepared.snapshot.approval_policy.as_deref(),
            Some("on-request")
        );
    }

    #[test]
    fn prepare_direct_session_sets_claude_direct_mode_without_codex_config() {
        let prepared = prepare_direct_session(DirectSessionCreationInputs {
            id: "session-2".into(),
            provider: Provider::Claude,
            cwd: "/tmp/claude".into(),
            git_branch: None,
            model: Some("claude-opus".into()),
            approval_policy: Some("ignored".into()),
            sandbox_mode: Some("ignored".into()),
            effort: Some("medium".into()),
        });

        assert_eq!(
            prepared.summary.claude_integration_mode,
            Some(ClaudeIntegrationMode::Direct)
        );
        assert_eq!(prepared.snapshot.model.as_deref(), Some("claude-opus"));
        assert_eq!(prepared.snapshot.approval_policy, None);
    }
}
