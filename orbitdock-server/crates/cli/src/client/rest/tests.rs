use orbitdock_protocol::HTTP_HEADER_CLIENT_VERSION;

use super::client_headers;

#[test]
fn client_headers_advertise_current_version_handshake() {
  let headers = client_headers();

  assert_eq!(
    headers
      .get(HTTP_HEADER_CLIENT_VERSION)
      .and_then(|value| value.to_str().ok()),
    Some(env!("CARGO_PKG_VERSION"))
  );
}
