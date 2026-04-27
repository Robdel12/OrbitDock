use super::ClientConfig;

#[test]
fn from_sources_normalizes_wildcard_server_urls_to_loopback() {
  let config = ClientConfig::from_sources(Some("http://0.0.0.0:4000"), None, false, None);
  assert_eq!(config.server_url, "http://127.0.0.1:4000");
}
