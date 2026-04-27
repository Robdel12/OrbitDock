use super::*;

#[test]
fn channel_roundtrip() {
  for channel in [
    UpdateChannel::Stable,
    UpdateChannel::Beta,
    UpdateChannel::Nightly,
  ] {
    let s = channel.to_string();
    let parsed: UpdateChannel = s.parse().unwrap();
    assert_eq!(parsed, channel);
  }
}

#[test]
fn channel_case_insensitive() {
  assert_eq!(
    "STABLE".parse::<UpdateChannel>().unwrap(),
    UpdateChannel::Stable
  );
  assert_eq!(
    "Beta".parse::<UpdateChannel>().unwrap(),
    UpdateChannel::Beta
  );
  assert_eq!(
    "NIGHTLY".parse::<UpdateChannel>().unwrap(),
    UpdateChannel::Nightly
  );
}

#[test]
fn invalid_channel() {
  assert!("alpha".parse::<UpdateChannel>().is_err());
}

#[test]
fn release_info_parses_version() {
  let info = ReleaseInfo {
    tag_name: "v0.7.0".to_string(),
    html_url: String::new(),
    published_at: None,
    prerelease: false,
    assets: vec![],
  };
  let v = info.version().unwrap();
  assert_eq!(v, semver::Version::new(0, 7, 0));
}

#[test]
fn release_info_parses_prerelease_version() {
  let info = ReleaseInfo {
    tag_name: "v0.8.0-beta.1".to_string(),
    html_url: String::new(),
    published_at: None,
    prerelease: true,
    assets: vec![],
  };
  let v = info.version().unwrap();
  assert!(!v.pre.is_empty());
}

#[test]
fn release_info_nightly_tag() {
  let info = ReleaseInfo {
    tag_name: "nightly".to_string(),
    html_url: String::new(),
    published_at: None,
    prerelease: true,
    assets: vec![],
  };
  assert!(info.version().is_none());
}
