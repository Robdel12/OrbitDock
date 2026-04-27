use super::{convert_app_server_type, convert_optional};
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
