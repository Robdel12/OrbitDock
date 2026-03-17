/// Resolve the Linear API key from env var or encrypted config table.
pub fn resolve_linear_api_key() -> Option<String> {
    if let Ok(key) = std::env::var("LINEAR_API_KEY") {
        if !key.is_empty() {
            return Some(key);
        }
    }

    crate::infrastructure::persistence::load_config_value("linear_api_key")
}
