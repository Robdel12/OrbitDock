use super::ClientConfig;

#[test]
fn from_sources_normalizes_wildcard_server_urls_to_loopback() {
  let data_dir =
    std::env::temp_dir().join(format!("orbitdock-cli-config-tests-{}", std::process::id()));
  let _ = std::fs::create_dir_all(&data_dir);
  orbitdock_server::init_data_dir(Some(&data_dir));

  let ipv4 = ClientConfig::from_sources(Some("http://0.0.0.0:4000"), None, false, None);
  assert_eq!(ipv4.server_url, "http://127.0.0.1:4000");

  let ipv6 = ClientConfig::from_sources(Some("http://[::]:4000"), None, false, None);
  assert_eq!(ipv6.server_url, "http://[::1]:4000");
}
