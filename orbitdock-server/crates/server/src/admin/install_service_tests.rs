use std::path::{Path, PathBuf};

use super::{
  dedup_non_empty, extract_probe_path, normalize_path_env, plan_service_install,
  render_launchd_environment_variables, render_launchd_plist, render_systemd_unit,
  ServiceInstallPlan, ServiceOptions,
};

#[test]
fn extract_probe_path_prefers_last_probe_output() {
  let output = "__ORBITDOCK_PATH__/tmp/old\nnoise\n__ORBITDOCK_PATH__/usr/bin:/bin\n";
  let path = extract_probe_path(output);
  assert_eq!(path.as_deref(), Some("/usr/bin:/bin"));
}

#[test]
fn extract_probe_path_rejects_empty_paths() {
  let output = "__ORBITDOCK_PATH__\n";
  assert_eq!(extract_probe_path(output), None);
}

#[test]
fn dedup_non_empty_removes_blanks_and_duplicates() {
  let values = vec![
    "".to_string(),
    " /usr/bin ".to_string(),
    "/bin".to_string(),
    "/usr/bin".to_string(),
    "   ".to_string(),
  ];
  assert_eq!(dedup_non_empty(values).as_deref(), Some("/usr/bin:/bin"));
}

#[test]
fn normalize_path_env_dedups_empty_segments() {
  let path = normalize_path_env("/usr/bin::/bin:/usr/bin");
  assert_eq!(path.as_deref(), Some("/usr/bin:/bin"));
}

#[test]
fn render_launchd_environment_variables_escapes_values() {
  let xml = render_launchd_environment_variables(&[
    ("PATH".to_string(), "/usr/bin:/bin".to_string()),
    (
      "CLAUDE_BIN".to_string(),
      "/tmp/claude & \"beta\"".to_string(),
    ),
  ]);
  assert!(xml.contains("<key>EnvironmentVariables</key>"));
  assert!(xml.contains("<key>PATH</key>"));
  assert!(xml.contains("<string>/usr/bin:/bin</string>"));
  assert!(xml.contains("<key>CLAUDE_BIN</key>"));
  assert!(xml.contains("<string>/tmp/claude &amp; &quot;beta&quot;</string>"));
}

#[test]
fn service_install_plan_trims_auth_token_and_collects_tls_args() {
  let plan = plan_service_install(
    Path::new("/tmp/orbitdock"),
    ServiceOptions {
      bind: "127.0.0.1:4000".parse().expect("bind"),
      enable: true,
      tls_cert: Some(PathBuf::from("/tmp/server.crt")),
      tls_key: Some(PathBuf::from("/tmp/server.key")),
      auth_token: Some("  secret-token  ".to_string()),
    },
  )
  .expect("plan service install");

  assert_eq!(plan.bind_addr, "127.0.0.1:4000");
  assert_eq!(plan.data_dir, "/tmp/orbitdock");
  assert_eq!(plan.auth_token.as_deref(), Some("secret-token"));
  assert_eq!(
    plan.extra_args,
    vec![
      "--tls-cert".to_string(),
      "/tmp/server.crt".to_string(),
      "--tls-key".to_string(),
      "/tmp/server.key".to_string()
    ]
  );
  assert!(plan.uses_tls);
  assert!(plan.enable);
}

#[test]
fn render_launchd_plist_includes_env_and_extra_args() {
  let plan = ServiceInstallPlan {
    binary_path: "/usr/local/bin/orbitdock".to_string(),
    bind_addr: "127.0.0.1:4000".to_string(),
    data_dir: "/tmp/orbitdock".to_string(),
    extra_args: vec!["--tls-cert".to_string(), "/tmp/server.crt".to_string()],
    uses_tls: true,
    auth_token: Some("secret-token".to_string()),
    enable: true,
  };

  let plist = render_launchd_plist(
    &plan,
    &[
      ("PATH".to_string(), "/usr/bin:/bin".to_string()),
      (
        "ORBITDOCK_AUTH_TOKEN".to_string(),
        "secret-token".to_string(),
      ),
    ],
  );

  assert!(plist.contains("<string>/usr/local/bin/orbitdock</string>"));
  assert!(plist.contains("<string>127.0.0.1:4000</string>"));
  assert!(plist.contains("<key>ORBITDOCK_AUTH_TOKEN</key>"));
  assert!(plist.contains("<string>--tls-cert</string>"));
  assert!(plist.contains("<string>/tmp/server.crt</string>"));
}

#[test]
fn render_systemd_unit_includes_auth_env_and_extra_args() {
  let plan = ServiceInstallPlan {
    binary_path: "/usr/local/bin/orbitdock".to_string(),
    bind_addr: "0.0.0.0:4000".to_string(),
    data_dir: "/tmp/orbitdock".to_string(),
    extra_args: vec!["--tls-key".to_string(), "/tmp/server.key".to_string()],
    uses_tls: true,
    auth_token: Some("secret-token".to_string()),
    enable: false,
  };

  let unit = render_systemd_unit(&plan);

  assert!(unit.contains("Environment=\"ORBITDOCK_AUTH_TOKEN=secret-token\""));
  assert!(unit.contains(
    "ExecStart=/usr/local/bin/orbitdock start --bind 0.0.0.0:4000 --data-dir /tmp/orbitdock --tls-key /tmp/server.key"
  ));
}
