use std::io;
use std::net::{SocketAddr, TcpListener};
use std::path::Path;

pub(crate) fn ensure_bind_addr_available(
  bind_addr: SocketAddr,
  data_dir: &Path,
) -> anyhow::Result<()> {
  match TcpListener::bind(bind_addr) {
    Ok(listener) => {
      drop(listener);
      Ok(())
    }
    Err(error) if error.kind() == io::ErrorKind::AddrInUse => {
      anyhow::bail!("{}", describe_bind_conflict(bind_addr, data_dir));
    }
    Err(error) => Err(error).map_err(|error| {
      anyhow::anyhow!(
        "OrbitDock could not verify bind address {}: {}",
        bind_addr,
        error
      )
    }),
  }
}

#[cfg(test)]
pub(crate) fn bind_conflict_message(bind_addr: SocketAddr, data_dir: &Path) -> String {
  describe_bind_conflict(bind_addr, data_dir)
}

fn describe_bind_conflict(bind_addr: SocketAddr, data_dir: &Path) -> String {
  let mut lines = vec![format!(
    "OrbitDock could not start because {} is already in use.",
    bind_addr
  )];

  if let Some(pid) = active_pid_from_file(data_dir) {
    lines.push(format!(
      "The managed OrbitDock PID file points to a running process ({pid})."
    ));
  }

  if local_healthcheck_ok(bind_addr.port()) {
    lines.push(format!(
      "A server is already answering health checks on http://127.0.0.1:{}/health.",
      bind_addr.port()
    ));
  }

  lines.push(
    "Stop the existing OrbitDock/dev server or choose a different `--bind` address before retrying."
      .to_string(),
  );
  lines.join(" ")
}

fn local_healthcheck_ok(port: u16) -> bool {
  let url = format!("http://127.0.0.1:{port}/health");
  std::process::Command::new("curl")
    .args(["-s", "--connect-timeout", "1", "--max-time", "2", &url])
    .output()
    .map(|output| output.status.success())
    .unwrap_or(false)
}

fn active_pid_from_file(data_dir: &Path) -> Option<u32> {
  let pid_path = data_dir.join("orbitdock.pid");
  let pid_str = std::fs::read_to_string(pid_path).ok()?;
  let pid = pid_str.trim().parse::<u32>().ok()?;
  if pid == 0 || !process_alive(pid) {
    return None;
  }
  Some(pid)
}

fn process_alive(pid: u32) -> bool {
  unsafe {
    let result = libc::kill(pid as i32, 0);
    if result == 0 {
      return true;
    }

    matches!(
      std::io::Error::last_os_error().raw_os_error(),
      Some(libc::EPERM)
    )
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::net::{IpAddr, Ipv4Addr};

  #[test]
  fn conflict_message_always_mentions_bind_address() {
    let bind_addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4000);
    let data_dir = std::env::temp_dir();
    let message = bind_conflict_message(bind_addr, &data_dir);

    assert!(message.contains("127.0.0.1:4000"));
    assert!(message.contains("already in use"));
    assert!(message.contains("Stop the existing OrbitDock/dev server"));
  }
}
