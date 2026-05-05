use super::{convert_app_server_type, convert_optional, convert_sandbox_policy};
use codex_app_server_protocol::{NetworkAccess, SandboxPolicy as AppServerSandboxPolicy};
use codex_protocol::protocol::SandboxPolicy;
use serde::{Deserialize, Serialize};

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
struct BridgeSample {
  name: String,
  count: u32,
}

#[test]
fn convert_app_server_type_round_trips_values() {
  let sample = BridgeSample {
    name: "bridge".to_string(),
    count: 3,
  };

  let converted: BridgeSample =
    convert_app_server_type(sample, "bridge sample").expect("sample should convert");

  assert_eq!(
    converted,
    BridgeSample {
      name: "bridge".to_string(),
      count: 3,
    }
  );
}

#[test]
fn convert_optional_keeps_none_and_converts_some() {
  let converted: Option<BridgeSample> =
    convert_optional(None::<BridgeSample>, "bridge sample").expect("none should convert");
  assert_eq!(converted, None);

  let converted: Option<BridgeSample> = convert_optional(
    Some(BridgeSample {
      name: "bridge".to_string(),
      count: 7,
    }),
    "bridge sample",
  )
  .expect("sample should convert");

  assert_eq!(
    converted,
    Some(BridgeSample {
      name: "bridge".to_string(),
      count: 7,
    })
  );
}

#[test]
fn convert_sandbox_policy_uses_app_server_shape() {
  let converted = convert_sandbox_policy(Some(SandboxPolicy::ExternalSandbox {
    network_access: codex_protocol::protocol::NetworkAccess::Restricted,
  }));

  assert_eq!(
    converted,
    Some(AppServerSandboxPolicy::ExternalSandbox {
      network_access: NetworkAccess::Restricted,
    })
  );
}
