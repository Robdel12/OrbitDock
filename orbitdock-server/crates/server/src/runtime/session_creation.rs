use std::sync::Arc;

use tokio::sync::mpsc;

use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexConfigMode, CodexConfigSource, CodexIntegrationMode,
    CodexSessionOverrides, Provider, SessionState, SessionSummary,
};

use crate::domain::sessions::session::{SessionConfigPatch, SessionHandle};
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_direct_start::{
    start_direct_claude_session, start_direct_codex_session, StartDirectCodexRequest,
};
use crate::runtime::session_mutations::end_failed_direct_session;
use crate::runtime::session_registry::SessionRegistry;

pub(crate) struct DirectSessionCreationInputs {
    pub id: String,
    pub provider: Provider,
    pub cwd: String,
    pub git_branch: Option<String>,
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
    pub effort: Option<String>,
    pub mission_id: Option<String>,
    pub issue_identifier: Option<String>,
    pub allow_bypass_permissions: bool,
    pub codex_config_mode: Option<CodexConfigMode>,
    pub codex_config_profile: Option<String>,
    pub codex_model_provider: Option<String>,
    pub codex_config_source: Option<CodexConfigSource>,
    pub codex_config_overrides: Option<CodexSessionOverrides>,
}

pub(crate) struct PreparedDirectSession {
    pub project_name: Option<String>,
    pub handle: SessionHandle,
    pub summary: SessionSummary,
    pub snapshot: SessionState,
}

#[derive(Clone)]
pub(crate) struct DirectSessionRequest {
    pub provider: Provider,
    pub cwd: String,
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub permission_mode: Option<String>,
    pub allowed_tools: Vec<String>,
    pub disallowed_tools: Vec<String>,
    pub effort: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
    pub mission_id: Option<String>,
    pub issue_identifier: Option<String>,
    /// Dynamic tool specs for Codex sessions (mission tools).
    pub dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec>,
    /// When true, pass `--allow-dangerously-skip-permissions` to the Claude CLI,
    /// enabling mid-session switches to `bypassPermissions` mode.
    pub allow_bypass_permissions: bool,
    pub codex_config_mode: Option<CodexConfigMode>,
    pub codex_config_profile: Option<String>,
    pub codex_model_provider: Option<String>,
    pub codex_config_source: Option<CodexConfigSource>,
    pub codex_config_overrides: Option<CodexSessionOverrides>,
}

pub(crate) struct PreparedPersistedDirectSession {
    pub id: String,
    pub request: DirectSessionRequest,
    pub handle: SessionHandle,
    pub summary: SessionSummary,
    pub snapshot: SessionState,
}

struct PersistDirectSessionCreate {
    id: String,
    provider: Provider,
    project_path: String,
    project_name: Option<String>,
    branch: Option<String>,
    model: Option<String>,
    approval_policy: Option<String>,
    sandbox_mode: Option<String>,
    permission_mode: Option<String>,
    collaboration_mode: Option<String>,
    multi_agent: Option<bool>,
    personality: Option<String>,
    service_tier: Option<String>,
    developer_instructions: Option<String>,
    effort: Option<String>,
    mission_id: Option<String>,
    issue_identifier: Option<String>,
    allow_bypass_permissions: bool,
    codex_config_mode: Option<CodexConfigMode>,
    codex_config_profile: Option<String>,
    codex_model_provider: Option<String>,
    codex_config_source: Option<CodexConfigSource>,
    codex_config_overrides_json: Option<String>,
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
        handle.set_config(SessionConfigPatch {
            approval_policy: input.approval_policy,
            sandbox_mode: input.sandbox_mode,
            collaboration_mode: input.collaboration_mode,
            multi_agent: input.multi_agent,
            personality: input.personality,
            service_tier: input.service_tier,
            developer_instructions: input.developer_instructions,
            codex_config_mode: input.codex_config_mode,
            codex_config_profile: input.codex_config_profile,
            codex_model_provider: input.codex_model_provider,
            model: input.model,
            effort: input.effort,
            codex_config_source: input.codex_config_source,
            codex_config_overrides: input.codex_config_overrides,
        });
    } else if input.provider == Provider::Claude {
        handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
    }

    if input.mission_id.is_some() || input.issue_identifier.is_some() {
        handle.set_mission_context(input.mission_id, input.issue_identifier);
    }
    if input.allow_bypass_permissions {
        handle.set_allow_bypass_permissions(true);
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

async fn persist_direct_session_create(
    persist_tx: &mpsc::Sender<PersistCommand>,
    request: PersistDirectSessionCreate,
) {
    let PersistDirectSessionCreate {
        id,
        provider,
        project_path,
        project_name,
        branch,
        model,
        approval_policy,
        sandbox_mode,
        permission_mode,
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
        effort,
        mission_id,
        issue_identifier,
        allow_bypass_permissions,
        codex_config_mode,
        codex_config_profile,
        codex_model_provider,
        codex_config_source,
        codex_config_overrides_json,
    } = request;
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
            collaboration_mode,
            multi_agent,
            personality,
            service_tier,
            developer_instructions,
            codex_config_mode,
            codex_config_profile,
            codex_model_provider,
            codex_config_source,
            codex_config_overrides_json,
            forked_from_session_id: None,
            mission_id,
            issue_identifier,
            allow_bypass_permissions,
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

pub(crate) async fn prepare_persist_direct_session(
    state: &Arc<SessionRegistry>,
    id: String,
    request: DirectSessionRequest,
) -> PreparedPersistedDirectSession {
    let git_branch = crate::domain::git::repo::resolve_git_branch(&request.cwd).await;
    let prepared = prepare_direct_session(DirectSessionCreationInputs {
        id: id.clone(),
        provider: request.provider,
        cwd: request.cwd.clone(),
        git_branch: git_branch.clone(),
        model: request.model.clone(),
        approval_policy: request.approval_policy.clone(),
        sandbox_mode: request.sandbox_mode.clone(),
        collaboration_mode: request.collaboration_mode.clone(),
        multi_agent: request.multi_agent,
        personality: request.personality.clone(),
        service_tier: request.service_tier.clone(),
        developer_instructions: request.developer_instructions.clone(),
        effort: request.effort.clone(),
        mission_id: request.mission_id.clone(),
        issue_identifier: request.issue_identifier.clone(),
        allow_bypass_permissions: request.allow_bypass_permissions,
        codex_config_mode: request.codex_config_mode,
        codex_config_profile: request.codex_config_profile.clone(),
        codex_model_provider: request.codex_model_provider.clone(),
        codex_config_source: request.codex_config_source,
        codex_config_overrides: request.codex_config_overrides.clone(),
    });

    let persist_tx = state.persist().clone();
    persist_direct_session_create(
        &persist_tx,
        PersistDirectSessionCreate {
            id: id.clone(),
            provider: request.provider,
            project_path: request.cwd.clone(),
            project_name: prepared.project_name,
            branch: git_branch,
            model: request.model.clone(),
            approval_policy: request.approval_policy.clone(),
            sandbox_mode: request.sandbox_mode.clone(),
            permission_mode: request.permission_mode.clone(),
            collaboration_mode: request.collaboration_mode.clone(),
            multi_agent: request.multi_agent,
            personality: request.personality.clone(),
            service_tier: request.service_tier.clone(),
            developer_instructions: request.developer_instructions.clone(),
            effort: request.effort.clone(),
            mission_id: request.mission_id.clone(),
            issue_identifier: request.issue_identifier.clone(),
            allow_bypass_permissions: request.allow_bypass_permissions,
            codex_config_mode: request.codex_config_mode,
            codex_config_profile: request.codex_config_profile.clone(),
            codex_model_provider: request.codex_model_provider.clone(),
            codex_config_source: request.codex_config_source,
            codex_config_overrides_json: request
                .codex_config_overrides
                .as_ref()
                .and_then(crate::runtime::codex_config::serialize_codex_overrides),
        },
    )
    .await;

    PreparedPersistedDirectSession {
        id,
        request,
        handle: prepared.handle,
        summary: prepared.summary,
        snapshot: prepared.snapshot,
    }
}

pub(crate) async fn launch_prepared_direct_session(
    state: &Arc<SessionRegistry>,
    prepared: PreparedPersistedDirectSession,
) -> Result<(), String> {
    let session_id = prepared.id.clone();
    let request = prepared.request.clone();
    let handle = prepared.handle;

    let start_result = match request.provider {
        Provider::Codex => {
            start_direct_codex_session(
                state,
                StartDirectCodexRequest {
                    handle,
                    session_id: &session_id,
                    cwd: &request.cwd,
                    model: request.model.as_deref(),
                    approval_policy: request.approval_policy.as_deref(),
                    sandbox_mode: request.sandbox_mode.as_deref(),
                    collaboration_mode: request.collaboration_mode.as_deref(),
                    multi_agent: request.multi_agent,
                    personality: request.personality.as_deref(),
                    service_tier: request.service_tier.as_deref(),
                    developer_instructions: request.developer_instructions.as_deref(),
                    config_profile: request.codex_config_profile.as_deref(),
                    model_provider: request.codex_model_provider.as_deref(),
                    dynamic_tools: request.dynamic_tools.clone(),
                },
            )
            .await
        }
        Provider::Claude => {
            start_direct_claude_session(
                state,
                crate::runtime::session_direct_start::StartDirectClaudeRequest {
                    handle,
                    session_id: &session_id,
                    cwd: &request.cwd,
                    model: request.model.as_deref(),
                    permission_mode: request.permission_mode.as_deref(),
                    allowed_tools: &request.allowed_tools,
                    disallowed_tools: &request.disallowed_tools,
                    effort: request.effort.as_deref(),
                    allow_bypass_permissions: request.allow_bypass_permissions,
                },
            )
            .await
        }
    };

    if start_result.is_err() {
        end_failed_direct_session(state, &session_id).await;
    }

    start_result
}

#[cfg(test)]
mod tests {
    use super::{
        prepare_direct_session, DirectSessionCreationInputs, DirectSessionRequest,
        PreparedPersistedDirectSession,
    };
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
            collaboration_mode: Some("workers".into()),
            multi_agent: Some(true),
            personality: Some("mentor".into()),
            service_tier: Some("priority".into()),
            developer_instructions: Some("Stay focused".into()),
            effort: Some("high".into()),
            mission_id: None,
            issue_identifier: None,
            allow_bypass_permissions: false,
            codex_config_mode: None,
            codex_config_profile: None,
            codex_model_provider: None,
            codex_config_source: None,
            codex_config_overrides: None,
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
        assert_eq!(
            prepared.snapshot.collaboration_mode.as_deref(),
            Some("workers")
        );
        assert_eq!(prepared.snapshot.multi_agent, Some(true));
        assert_eq!(prepared.snapshot.personality.as_deref(), Some("mentor"));
        assert_eq!(prepared.snapshot.service_tier.as_deref(), Some("priority"));
        assert_eq!(
            prepared.snapshot.developer_instructions.as_deref(),
            Some("Stay focused")
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
            collaboration_mode: Some("ignored".into()),
            multi_agent: Some(true),
            personality: Some("ignored".into()),
            service_tier: Some("ignored".into()),
            developer_instructions: Some("ignored".into()),
            effort: Some("medium".into()),
            mission_id: None,
            issue_identifier: None,
            allow_bypass_permissions: false,
            codex_config_mode: None,
            codex_config_profile: None,
            codex_model_provider: None,
            codex_config_source: None,
            codex_config_overrides: None,
        });

        assert_eq!(
            prepared.summary.claude_integration_mode,
            Some(ClaudeIntegrationMode::Direct)
        );
        assert_eq!(prepared.snapshot.model.as_deref(), Some("claude-opus"));
        assert_eq!(prepared.snapshot.approval_policy, None);
    }

    #[test]
    fn prepared_persisted_direct_session_keeps_transport_relevant_state() {
        let request = DirectSessionRequest {
            provider: Provider::Claude,
            cwd: "/tmp/claude".into(),
            model: Some("claude-opus".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: Some("plan".into()),
            allowed_tools: vec!["Read".into()],
            disallowed_tools: vec!["Edit".into()],
            effort: Some("medium".into()),
            collaboration_mode: Some("workers".into()),
            multi_agent: Some(true),
            personality: Some("mentor".into()),
            service_tier: Some("priority".into()),
            developer_instructions: Some("Stay focused".into()),
            mission_id: None,
            issue_identifier: None,
            dynamic_tools: Vec::new(),
            allow_bypass_permissions: false,
            codex_config_mode: None,
            codex_config_profile: None,
            codex_model_provider: None,
            codex_config_source: None,
            codex_config_overrides: None,
        };
        let prepared = prepare_direct_session(DirectSessionCreationInputs {
            id: "session-3".into(),
            provider: request.provider,
            cwd: request.cwd.clone(),
            git_branch: None,
            model: request.model.clone(),
            approval_policy: request.approval_policy.clone(),
            sandbox_mode: request.sandbox_mode.clone(),
            collaboration_mode: request.collaboration_mode.clone(),
            multi_agent: request.multi_agent,
            personality: request.personality.clone(),
            service_tier: request.service_tier.clone(),
            developer_instructions: request.developer_instructions.clone(),
            effort: request.effort.clone(),
            mission_id: None,
            issue_identifier: None,
            allow_bypass_permissions: false,
            codex_config_mode: None,
            codex_config_profile: None,
            codex_model_provider: None,
            codex_config_source: None,
            codex_config_overrides: None,
        });

        let persisted = PreparedPersistedDirectSession {
            id: "session-3".into(),
            request,
            handle: prepared.handle,
            summary: prepared.summary,
            snapshot: prepared.snapshot,
        };

        assert_eq!(persisted.summary.id, "session-3");
        assert_eq!(persisted.snapshot.id, "session-3");
        assert_eq!(persisted.request.permission_mode.as_deref(), Some("plan"));
        assert_eq!(persisted.request.allowed_tools, vec!["Read"]);
        assert_eq!(
            persisted.request.collaboration_mode.as_deref(),
            Some("workers")
        );
        assert_eq!(persisted.request.multi_agent, Some(true));
    }
}
