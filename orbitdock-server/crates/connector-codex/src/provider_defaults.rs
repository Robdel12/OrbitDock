use codex_core::config::Config;
use codex_model_provider_info::ModelProviderInfo;
use std::collections::HashMap;

use super::{ORBITDOCK_OPENROUTER_SITE_URL, ORBITDOCK_OPENROUTER_TITLE};

pub(crate) fn apply_orbitdock_provider_defaults(config: &mut Config) {
  let provider_id = config.model_provider_id.clone();
  let Some(provider) = config.model_providers.get_mut(&provider_id) else {
    return;
  };

  if !is_openrouter_provider(&provider_id, provider) {
    return;
  }

  let headers = provider.http_headers.get_or_insert_with(HashMap::new);
  headers
    .entry("HTTP-Referer".to_string())
    .or_insert_with(|| ORBITDOCK_OPENROUTER_SITE_URL.to_string());

  if !headers.contains_key("X-OpenRouter-Title") && !headers.contains_key("X-Title") {
    headers.insert(
      "X-OpenRouter-Title".to_string(),
      ORBITDOCK_OPENROUTER_TITLE.to_string(),
    );
  }
}

fn is_openrouter_provider(provider_id: &str, provider: &ModelProviderInfo) -> bool {
  provider_id.eq_ignore_ascii_case("openrouter")
    || provider.name.eq_ignore_ascii_case("openrouter")
    || provider
      .base_url
      .as_ref()
      .is_some_and(|value| value.to_ascii_lowercase().contains("openrouter.ai"))
}
