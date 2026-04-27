use super::{
  parse_launchd_bind, parse_systemd_bind, tailscale_https_url_from_status_json, ExposureMode,
};

#[test]
fn exposure_modes_map_to_expected_binds() {
  let bind = |mode| match mode {
    ExposureMode::Cloudflare | ExposureMode::Tailscale | ExposureMode::ReverseProxy => {
      "127.0.0.1:4000"
    }
    ExposureMode::Direct => "0.0.0.0:4000",
  };

  assert_eq!(bind(ExposureMode::Cloudflare), "127.0.0.1:4000");
  assert_eq!(bind(ExposureMode::Tailscale), "127.0.0.1:4000");
  assert_eq!(bind(ExposureMode::ReverseProxy), "127.0.0.1:4000");
  assert_eq!(bind(ExposureMode::Direct), "0.0.0.0:4000");
}

#[test]
fn parse_launchd_bind_reads_bind_address() {
  let content = r#"
        <string>start</string>
        <string>--bind</string>
        <string>127.0.0.1:4000</string>
        "#;
  let bind = parse_launchd_bind(content).expect("bind");
  assert_eq!(bind.to_string(), "127.0.0.1:4000");
}

#[test]
fn parse_systemd_bind_reads_bind_address() {
  let content = r#"ExecStart=/Users/test/.orbitdock/bin/orbitdock start --bind 0.0.0.0:4000 --data-dir /Users/test/.orbitdock"#;
  let bind = parse_systemd_bind(content).expect("bind");
  assert_eq!(bind.to_string(), "0.0.0.0:4000");
}

#[test]
fn tailscale_status_json_prefers_https_dns_name() {
  let json = br#"{
      "Self": {
        "DNSName": "orbitdock-mac.penguin.ts.net."
      }
    }"#;

  assert_eq!(
    tailscale_https_url_from_status_json(json),
    Some("https://orbitdock-mac.penguin.ts.net".to_string())
  );
}
