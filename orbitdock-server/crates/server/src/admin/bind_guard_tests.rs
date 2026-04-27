use std::net::{IpAddr, Ipv4Addr, SocketAddr};

#[test]
fn conflict_message_always_mentions_bind_address() {
  let bind_addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4000);
  let data_dir = std::env::temp_dir();
  let message = super::describe_bind_conflict(bind_addr, &data_dir);

  assert!(message.contains("127.0.0.1:4000"));
  assert!(message.contains("already in use"));
  assert!(message.contains("Stop the existing OrbitDock/dev server"));
}
