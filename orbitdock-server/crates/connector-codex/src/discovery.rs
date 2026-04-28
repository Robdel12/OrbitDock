use orbitdock_connector_core::ConnectorError;

use crate::{CodexConfigOverrides, CodexRuntimeOverrides};

use super::model_rejects_reasoning_summary;

pub async fn discover_models() -> Result<Vec<orbitdock_protocol::CodexModelOption>, ConnectorError>
{
  discover_models_for_context(None, None).await
}

pub async fn discover_models_for_context(
  cwd: Option<&str>,
  model_provider: Option<&str>,
) -> Result<Vec<orbitdock_protocol::CodexModelOption>, ConnectorError> {
  let app_server = crate::app_server::shared_app_server(
    cwd.unwrap_or("."),
    &CodexConfigOverrides {
      model_provider: model_provider.map(str::to_string),
      config_profile: None,
    },
    &CodexRuntimeOverrides::default(),
  )
  .await?;

  let models = app_server
    .model_list(false)
    .await?
    .data
    .into_iter()
    .filter(|model| !model.hidden)
    .map(|model| {
      let supported_reasoning_efforts = model
        .supported_reasoning_efforts
        .into_iter()
        .map(|effort| effort.reasoning_effort.to_string())
        .collect();
      let supported_service_tiers = model.additional_speed_tiers;
      let supports_reasoning_summaries = !model_rejects_reasoning_summary(Some(&model.model));

      orbitdock_protocol::CodexModelOption {
        id: model.id,
        model: model.model,
        display_name: model.display_name,
        description: model.description,
        is_default: model.is_default,
        supported_reasoning_efforts,
        supports_reasoning_summaries,
        supported_collaboration_modes: vec!["default".to_string(), "plan".to_string()],
        supports_multi_agent: true,
        multi_agent_is_experimental: true,
        supports_personality: model.supports_personality,
        supported_service_tiers,
        supports_developer_instructions: true,
      }
    })
    .collect();

  Ok(models)
}
