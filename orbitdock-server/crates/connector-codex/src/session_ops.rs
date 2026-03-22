use std::collections::HashMap;
use std::path::PathBuf;

use codex_core::SteerInputError;
use codex_protocol::openai_models::ReasoningEffort;
use codex_protocol::protocol::{
    AskForApproval, McpServerRefreshConfig, Op, ReviewDecision, SandboxPolicy,
};
use codex_protocol::request_permissions::{PermissionGrantScope, RequestPermissionsResponse};
use codex_protocol::request_user_input::{RequestUserInputAnswer, RequestUserInputResponse};
use codex_protocol::user_input::UserInput;
use tracing::{info, warn};

use super::config::{
    collaboration_mode_for_update, parse_personality, parse_service_tier_override,
    preferred_reasoning_summary, reasoning_summary_for_model,
};
use super::{
    CodexConfigOverrides, CodexConnector, CodexControlPlane, SteerOutcome, UpdateConfigOptions,
};
use crate::session::{CodexExecApproval, CodexPatchApproval};
use orbitdock_connector_core::ConnectorError;

fn parse_reasoning_effort(value: &str) -> Option<ReasoningEffort> {
    Some(match value {
        "none" => ReasoningEffort::None,
        "minimal" => ReasoningEffort::Minimal,
        "low" => ReasoningEffort::Low,
        "medium" => ReasoningEffort::Medium,
        "high" => ReasoningEffort::High,
        "xhigh" => ReasoningEffort::XHigh,
        _ => return None,
    })
}

impl CodexConnector {
    pub async fn fork_thread(
        &self,
        nth_user_message: Option<u32>,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
        cwd: Option<&str>,
    ) -> Result<(CodexConnector, String), ConnectorError> {
        let rollout_path =
            codex_core::find_thread_path_by_id_str(&self.codex_home, &self.thread_id)
                .await
                .map_err(|e| {
                    ConnectorError::ProviderError(format!("Failed to find rollout path: {}", e))
                })?
                .ok_or_else(|| {
                    ConnectorError::ProviderError(format!(
                        "No rollout file found for thread {}",
                        self.thread_id
                    ))
                })?;

        let effective_cwd = cwd.unwrap_or(".");
        let mut config = Self::build_config(
            effective_cwd,
            model,
            approval_policy,
            sandbox_mode,
            &CodexConfigOverrides::default(),
            &CodexControlPlane::default(),
        )
        .await?;
        Self::finalize_reasoning_summary(&mut config, self.thread_manager.as_ref()).await;

        let nth = nth_user_message.map(|n| n as usize).unwrap_or(usize::MAX);

        let new_thread = self
            .thread_manager
            .fork_thread(nth, config, rollout_path, false)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to fork thread: {}", e)))?;

        let new_thread_id = new_thread.thread_id.to_string();
        let connector = Self::from_thread(
            new_thread,
            self.thread_manager.clone(),
            self.codex_home.clone(),
        )?;

        Ok((connector, new_thread_id))
    }

    pub async fn send_message(
        &self,
        content: &str,
        model: Option<&str>,
        effort: Option<&str>,
        skills: &[orbitdock_protocol::SkillInput],
        images: &[orbitdock_protocol::ImageInput],
        mentions: &[orbitdock_protocol::MentionInput],
    ) -> Result<(), ConnectorError> {
        if model.is_some() || effort.is_some() {
            let effort_value = effort.map(|e| match e {
                "none" => ReasoningEffort::None,
                "minimal" => ReasoningEffort::Minimal,
                "low" => ReasoningEffort::Low,
                "medium" => ReasoningEffort::Medium,
                "high" => ReasoningEffort::High,
                "xhigh" => ReasoningEffort::XHigh,
                _ => ReasoningEffort::Medium,
            });
            let effective_model = if let Some(model) = model {
                Some(model.to_string())
            } else {
                let current = self.current_model.lock().await;
                current.clone()
            };
            let summary = Some(reasoning_summary_for_model(
                effective_model.as_deref(),
                preferred_reasoning_summary(),
            ));
            let override_op = Op::OverrideTurnContext {
                cwd: None,
                approval_policy: None,
                sandbox_policy: None,
                windows_sandbox_level: None,
                model: model.map(|m| m.to_string()),
                effort: effort_value.map(Some),
                summary,
                service_tier: None,
                collaboration_mode: None,
                personality: None,
            };
            self.thread.submit(override_op).await.map_err(|e| {
                ConnectorError::ProviderError(format!("Failed to override turn context: {}", e))
            })?;
            info!(
                "Submitted per-turn overrides: model={:?}, effort={:?}, summary={:?}",
                model, effort, summary
            );
        }

        let mut items = vec![UserInput::Text {
            text: content.to_string(),
            text_elements: Vec::new(),
        }];

        for skill in skills {
            items.push(UserInput::Skill {
                name: skill.name.clone(),
                path: PathBuf::from(&skill.path),
            });
        }

        for image in images {
            match image.input_type.as_str() {
                "url" => items.push(UserInput::Image {
                    image_url: image.value.clone(),
                }),
                "path" => items.push(UserInput::LocalImage {
                    path: PathBuf::from(&image.value),
                }),
                other => {
                    warn!("Unknown image input_type: {}, treating as url", other);
                    items.push(UserInput::Image {
                        image_url: image.value.clone(),
                    });
                }
            }
        }

        for mention in mentions {
            items.push(UserInput::Mention {
                name: mention.name.clone(),
                path: mention.path.clone(),
            });
        }

        let op = Op::UserInput {
            items,
            final_output_json_schema: None,
        };

        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to send message: {}", e)))?;

        info!("Sent user message");
        Ok(())
    }

    pub async fn steer_turn(
        &self,
        content: &str,
        images: &[orbitdock_protocol::ImageInput],
        mentions: &[orbitdock_protocol::MentionInput],
    ) -> Result<SteerOutcome, ConnectorError> {
        let mut items: Vec<UserInput> = Vec::new();

        if !content.is_empty() {
            items.push(UserInput::Text {
                text: content.to_string(),
                text_elements: Vec::new(),
            });
        }

        for image in images {
            match image.input_type.as_str() {
                "url" => items.push(UserInput::Image {
                    image_url: image.value.clone(),
                }),
                "path" => items.push(UserInput::LocalImage {
                    path: PathBuf::from(&image.value),
                }),
                other => {
                    warn!("Unknown image input_type: {}, treating as url", other);
                    items.push(UserInput::Image {
                        image_url: image.value.clone(),
                    });
                }
            }
        }

        for mention in mentions {
            items.push(UserInput::Mention {
                name: mention.name.clone(),
                path: mention.path.clone(),
            });
        }

        match self.thread.steer_input(items, None).await {
            Ok(turn_id) => {
                info!("Steered active turn: {}", turn_id);
                Ok(SteerOutcome::Accepted)
            }
            Err(SteerInputError::NoActiveTurn(items)) => {
                info!("No active turn for steer, falling back to send_message");
                self.thread
                    .submit(Op::UserInput {
                        items,
                        final_output_json_schema: None,
                    })
                    .await
                    .map_err(|e| {
                        ConnectorError::ProviderError(format!(
                            "Failed to send fallback message: {}",
                            e
                        ))
                    })?;
                Ok(SteerOutcome::FellBackToNewTurn)
            }
            Err(SteerInputError::EmptyInput) => {
                Err(ConnectorError::ProviderError("Empty steer input".into()))
            }
            Err(SteerInputError::ExpectedTurnMismatch { expected, actual }) => {
                Err(ConnectorError::ProviderError(format!(
                    "Turn mismatch: expected {expected}, got {actual}"
                )))
            }
        }
    }

    pub async fn list_skills(
        &self,
        cwds: Vec<String>,
        force_reload: bool,
    ) -> Result<(), ConnectorError> {
        let cwds: Vec<PathBuf> = cwds.into_iter().map(PathBuf::from).collect();
        let op = Op::ListSkills { cwds, force_reload };
        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to list skills: {}", e)))?;
        info!("Requested skills list");
        Ok(())
    }

    pub async fn list_remote_skills(&self) -> Result<(), ConnectorError> {
        use codex_protocol::protocol::{RemoteSkillHazelnutScope, RemoteSkillProductSurface};
        let op = Op::ListRemoteSkills {
            hazelnut_scope: RemoteSkillHazelnutScope::AllShared,
            product_surface: RemoteSkillProductSurface::Codex,
            enabled: None,
        };
        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to list remote skills: {}", e))
        })?;
        info!("Requested remote skills list");
        Ok(())
    }

    pub async fn download_remote_skill(&self, hazelnut_id: &str) -> Result<(), ConnectorError> {
        let op = Op::DownloadRemoteSkill {
            hazelnut_id: hazelnut_id.to_string(),
        };
        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to download skill: {}", e))
        })?;
        info!("Requested remote skill download: {}", hazelnut_id);
        Ok(())
    }

    pub async fn list_mcp_tools(&self) -> Result<(), ConnectorError> {
        let op = Op::ListMcpTools;
        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to list MCP tools: {}", e))
        })?;
        info!("Requested MCP tools list");
        Ok(())
    }

    pub async fn refresh_mcp_servers(&self) -> Result<(), ConnectorError> {
        let config = McpServerRefreshConfig {
            mcp_servers: serde_json::Value::Object(Default::default()),
            mcp_oauth_credentials_store_mode: serde_json::Value::Null,
        };
        let op = Op::RefreshMcpServers { config };
        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to refresh MCP servers: {}", e))
        })?;
        info!("Requested MCP servers refresh");
        Ok(())
    }

    pub async fn interrupt(&self) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::Interrupt)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to interrupt: {}", e)))?;

        info!("Interrupted turn");
        Ok(())
    }

    pub async fn approve_exec(
        &self,
        request_id: &str,
        decision: CodexExecApproval,
    ) -> Result<(), ConnectorError> {
        let label = decision.label();
        let review = match decision {
            CodexExecApproval::Approved => ReviewDecision::Approved,
            CodexExecApproval::ApprovedForSession => ReviewDecision::ApprovedForSession,
            CodexExecApproval::ApprovedAlways { proposed_amendment } => {
                if let Some(cmd) = proposed_amendment {
                    ReviewDecision::ApprovedExecpolicyAmendment {
                        proposed_execpolicy_amendment:
                            codex_protocol::approvals::ExecPolicyAmendment::new(cmd),
                    }
                } else {
                    ReviewDecision::ApprovedForSession
                }
            }
            CodexExecApproval::Abort => ReviewDecision::Abort,
            CodexExecApproval::Denied => ReviewDecision::Denied,
        };

        let op = Op::ExecApproval {
            id: request_id.to_string(),
            turn_id: None,
            decision: review,
        };

        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to approve exec: {}", e)))?;

        info!("Sent exec approval: {} = {}", request_id, label);
        Ok(())
    }

    pub async fn approve_patch(
        &self,
        request_id: &str,
        decision: CodexPatchApproval,
    ) -> Result<(), ConnectorError> {
        let label = decision.label();
        let review = match decision {
            CodexPatchApproval::Approved => ReviewDecision::Approved,
            CodexPatchApproval::ApprovedForSession => ReviewDecision::ApprovedForSession,
            CodexPatchApproval::Abort => ReviewDecision::Abort,
            CodexPatchApproval::Denied => ReviewDecision::Denied,
        };

        let op = Op::PatchApproval {
            id: request_id.to_string(),
            decision: review,
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to approve patch: {}", e))
        })?;

        info!("Sent patch approval: {} = {}", request_id, label);
        Ok(())
    }

    pub async fn answer_question(
        &self,
        request_id: &str,
        answers: HashMap<String, Vec<String>>,
    ) -> Result<(), ConnectorError> {
        let response = RequestUserInputResponse {
            answers: answers
                .into_iter()
                .map(|(k, v)| (k, RequestUserInputAnswer { answers: v }))
                .collect(),
        };

        let op = Op::UserInputAnswer {
            id: request_id.to_string(),
            response,
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to answer question: {}", e))
        })?;

        info!("Sent question answer: {}", request_id);
        Ok(())
    }

    pub async fn respond_to_permission_request(
        &self,
        request_id: &str,
        permissions: serde_json::Value,
        scope: orbitdock_protocol::PermissionGrantScope,
    ) -> Result<(), ConnectorError> {
        let permissions = serde_json::from_value(permissions).map_err(|e| {
            ConnectorError::ProviderError(format!(
                "Failed to decode granted permissions payload: {}",
                e
            ))
        })?;
        let scope = match scope {
            orbitdock_protocol::PermissionGrantScope::Turn => PermissionGrantScope::Turn,
            orbitdock_protocol::PermissionGrantScope::Session => PermissionGrantScope::Session,
        };

        let op = Op::RequestPermissionsResponse {
            id: request_id.to_string(),
            response: RequestPermissionsResponse { permissions, scope },
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to respond to permission request: {}", e))
        })?;

        info!("Sent permission response: {}", request_id);
        Ok(())
    }

    pub async fn set_thread_name(&self, name: &str) -> Result<(), ConnectorError> {
        let op = Op::SetThreadName {
            name: name.to_string(),
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to set thread name: {}", e))
        })?;

        info!("Set thread name: {}", name);
        Ok(())
    }

    pub async fn update_config(
        &self,
        options: UpdateConfigOptions<'_>,
    ) -> Result<(), ConnectorError> {
        let UpdateConfigOptions {
            approval_policy,
            sandbox_mode,
            permission_mode,
            collaboration_mode,
            multi_agent,
            personality,
            service_tier,
            developer_instructions,
            model,
            effort,
        } = options;

        let policy = approval_policy.map(|p| match p {
            "untrusted" => AskForApproval::UnlessTrusted,
            "on-failure" => AskForApproval::OnFailure,
            "on-request" => AskForApproval::OnRequest,
            "never" => AskForApproval::Never,
            _ => AskForApproval::OnRequest,
        });

        let sandbox = sandbox_mode.map(|s| match s {
            "danger-full-access" => SandboxPolicy::DangerFullAccess,
            "read-only" => SandboxPolicy::ReadOnly {
                access: Default::default(),
                network_access: false,
            },
            "workspace-write" => SandboxPolicy::WorkspaceWrite {
                writable_roots: Vec::new(),
                read_only_access: Default::default(),
                network_access: false,
                exclude_tmpdir_env_var: false,
                exclude_slash_tmp: false,
            },
            _ => SandboxPolicy::WorkspaceWrite {
                writable_roots: Vec::new(),
                read_only_access: Default::default(),
                network_access: false,
                exclude_tmpdir_env_var: false,
                exclude_slash_tmp: false,
            },
        });

        let current_model = {
            let current = self.current_model.lock().await;
            current.clone().unwrap_or_else(|| "gpt-5-codex".to_string())
        };
        let current_effort = {
            let current = self.current_reasoning_effort.lock().await;
            *current
        };
        let collaboration_mode = collaboration_mode_for_update(
            self.thread_manager.as_ref(),
            collaboration_mode,
            permission_mode,
            current_model,
            current_effort,
            developer_instructions,
        );
        let collaboration_mode_log = collaboration_mode.clone();

        let op = Op::OverrideTurnContext {
            cwd: None,
            approval_policy: policy,
            sandbox_policy: sandbox,
            windows_sandbox_level: None,
            model: model.map(ToString::to_string),
            effort: effort.and_then(parse_reasoning_effort).map(Some),
            summary: None,
            service_tier: parse_service_tier_override(service_tier),
            collaboration_mode,
            personality: parse_personality(personality),
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to update config: {}", e))
        })?;

        info!(
            "Updated session config: approval={:?}, sandbox={:?}, permission_mode={:?}, collaboration_mode={:?}, multi_agent={:?}, personality={:?}, service_tier={:?}, developer_instructions={:?}, model={:?}, effort={:?}",
            approval_policy,
            sandbox_mode,
            permission_mode,
            collaboration_mode_log,
            multi_agent,
            personality,
            service_tier,
            developer_instructions.map(|_| "[set]"),
            model,
            effort
        );
        Ok(())
    }

    pub async fn compact(&self) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::Compact)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to compact: {}", e)))?;
        info!("Sent compact");
        Ok(())
    }

    pub async fn undo(&self) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::Undo)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to undo: {}", e)))?;
        info!("Sent undo");
        Ok(())
    }

    pub async fn thread_rollback(&self, num_turns: u32) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::ThreadRollback { num_turns })
            .await
            .map_err(|e| {
                ConnectorError::ProviderError(format!("Failed to thread rollback: {}", e))
            })?;
        info!("Sent thread rollback: {} turns", num_turns);
        Ok(())
    }

    pub async fn submit_dynamic_tool_response(
        &self,
        call_id: String,
        response: codex_protocol::dynamic_tools::DynamicToolResponse,
    ) -> Result<(), ConnectorError> {
        let op = Op::DynamicToolResponse {
            id: call_id,
            response,
        };
        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to submit dynamic tool response: {}", e))
        })?;
        Ok(())
    }

    pub async fn shutdown(&self) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::Shutdown)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to shutdown: {}", e)))?;
        info!("Sent shutdown");
        Ok(())
    }
}
