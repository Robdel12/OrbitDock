//! Interactive terminal service with PTY-backed sessions.
//!
//! Each terminal session owns a pseudo-terminal running the user's shell.
//! Raw PTY output is broadcast to subscribers; input bytes are written
//! directly to the PTY master fd.

use std::ffi::CString;
use std::os::fd::{AsRawFd, OwnedFd};
use std::sync::Arc;

use dashmap::DashMap;
use nix::libc;
use nix::pty::{openpty, OpenptyResult};
use nix::sys::signal::{self, Signal};
use nix::unistd::{self, ForkResult, Pid};
use tokio::io::unix::AsyncFd;
use tokio::io::Interest;
use tokio::sync::{broadcast, watch};
use tracing::{debug, error, info, warn};

/// Binary frame type tags for server→client terminal messages.
pub const FRAME_TYPE_OUTPUT: u8 = 0x01;
pub const FRAME_TYPE_EXITED: u8 = 0x02;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalCreateError {
  DuplicateId,
  PtyFailed,
  ForkFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalNotFound {
  NotFound,
}

struct TerminalSession {
  child_pid: Pid,
  master_fd: Arc<OwnedFd>,
  cancel_tx: watch::Sender<bool>,
  cols: u16,
  rows: u16,
}

#[derive(Clone, Default)]
pub struct TerminalService {
  sessions: Arc<DashMap<String, TerminalSession>>,
}

impl TerminalService {
  pub fn new() -> Self {
    Self::default()
  }

  /// Spawn a new PTY terminal session.
  ///
  /// Returns a broadcast receiver for raw PTY output bytes.
  pub fn create(
    &self,
    terminal_id: String,
    cwd: String,
    shell: Option<String>,
    cols: u16,
    rows: u16,
  ) -> Result<broadcast::Receiver<Vec<u8>>, TerminalCreateError> {
    if self.sessions.contains_key(&terminal_id) {
      return Err(TerminalCreateError::DuplicateId);
    }

    let OpenptyResult { master, slave } = openpty(None, None).map_err(|e| {
      error!(
        component = "terminal",
        event = "terminal.openpty.failed",
        error = %e,
        "Failed to open PTY pair"
      );
      TerminalCreateError::PtyFailed
    })?;

    // Set initial window size on the slave PTY before forking.
    set_winsize(slave.as_raw_fd(), cols, rows);

    let shell_path = shell.unwrap_or_else(default_shell);
    let shell_cstr =
      CString::new(shell_path.as_bytes()).unwrap_or_else(|_| CString::new("/bin/sh").unwrap());
    let cwd_cstr = CString::new(cwd.as_bytes()).unwrap_or_else(|_| CString::new("/tmp").unwrap());

    // Safety: fork + exec in the child. The child replaces itself immediately.
    let child_pid = match unsafe { unistd::fork() } {
      Ok(ForkResult::Child) => {
        // Child process: set up PTY slave as stdin/stdout/stderr, then exec shell.
        drop(master);

        // Create a new session so the child owns the controlling terminal.
        let _ = unistd::setsid();

        // Set the slave as the controlling terminal.
        unsafe { libc::ioctl(slave.as_raw_fd(), libc::TIOCSCTTY as _, 0) };

        // Dup slave to stdin/stdout/stderr.
        let slave_raw = slave.as_raw_fd();
        let _ = unistd::dup2(slave_raw, 0);
        let _ = unistd::dup2(slave_raw, 1);
        let _ = unistd::dup2(slave_raw, 2);
        if slave_raw > 2 {
          drop(slave);
        }

        let _ = unistd::chdir(cwd_cstr.as_c_str());

        // Set TERM so the shell can find terminfo for proper I/O.
        std::env::set_var("TERM", "xterm-256color");

        // Exec the shell as a login shell (prepend '-' to argv[0]).
        let login_name = format!("-{}", shell_path.rsplit('/').next().unwrap_or("sh"));
        let login_cstr =
          CString::new(login_name.as_bytes()).unwrap_or_else(|_| CString::new("-sh").unwrap());
        let args = [login_cstr.as_c_str()];
        let _ = unistd::execv(shell_cstr.as_c_str(), &args);

        // If exec fails, exit immediately.
        unsafe { libc::_exit(127) };
      }
      Ok(ForkResult::Parent { child }) => child,
      Err(e) => {
        error!(
          component = "terminal",
          event = "terminal.fork.failed",
          error = %e,
          "Failed to fork for PTY session"
        );
        return Err(TerminalCreateError::ForkFailed);
      }
    };

    // Parent: close slave side — only the child needs it.
    drop(slave);

    let master_fd = Arc::new(master);
    let (output_tx, output_rx) = broadcast::channel(256);
    let (cancel_tx, cancel_rx) = watch::channel(false);

    let session = TerminalSession {
      child_pid,
      master_fd: master_fd.clone(),
      cancel_tx,
      cols,
      rows,
    };

    self.sessions.insert(terminal_id.clone(), session);

    // Spawn async reader task for PTY output.
    let sessions = self.sessions.clone();
    tokio::spawn(async move {
      pty_reader_loop(terminal_id, master_fd, output_tx, cancel_rx, sessions).await;
    });

    info!(
      component = "terminal",
      event = "terminal.created",
      pid = child_pid.as_raw(),
      cols,
      rows,
      "Terminal session created"
    );

    Ok(output_rx)
  }

  /// Write input bytes to a terminal's PTY master.
  pub fn write_input(&self, terminal_id: &str, data: &[u8]) -> Result<(), TerminalNotFound> {
    let session = self
      .sessions
      .get(terminal_id)
      .ok_or(TerminalNotFound::NotFound)?;
    // Write is synchronous on the master fd — this is fine for human-typing-speed input.
    let _ = unistd::write(&*session.master_fd, data);
    Ok(())
  }

  /// Resize a terminal's PTY.
  pub fn resize(&self, terminal_id: &str, cols: u16, rows: u16) -> Result<(), TerminalNotFound> {
    let mut session = self
      .sessions
      .get_mut(terminal_id)
      .ok_or(TerminalNotFound::NotFound)?;
    set_winsize(session.master_fd.as_raw_fd(), cols, rows);
    // Signal the child's process group so applications pick up the new size.
    let _ = signal::kill(session.child_pid, Signal::SIGWINCH);
    session.cols = cols;
    session.rows = rows;
    debug!(
      component = "terminal",
      event = "terminal.resized",
      terminal_id,
      cols,
      rows,
      "Terminal resized"
    );
    Ok(())
  }

  /// Destroy a terminal session, killing the child process.
  pub fn destroy(&self, terminal_id: &str) -> Result<(), TerminalNotFound> {
    let (_, session) = self
      .sessions
      .remove(terminal_id)
      .ok_or(TerminalNotFound::NotFound)?;
    let _ = session.cancel_tx.send(true);
    let _ = signal::kill(session.child_pid, Signal::SIGHUP);
    info!(
      component = "terminal",
      event = "terminal.destroyed",
      terminal_id,
      pid = session.child_pid.as_raw(),
      "Terminal session destroyed"
    );
    Ok(())
  }
}

/// Async PTY reader loop — reads output from the master fd and broadcasts it.
async fn pty_reader_loop(
  terminal_id: String,
  master_fd: Arc<OwnedFd>,
  output_tx: broadcast::Sender<Vec<u8>>,
  mut cancel_rx: watch::Receiver<bool>,
  sessions: Arc<DashMap<String, TerminalSession>>,
) {
  // Make the fd non-blocking for async I/O.
  let raw_fd = master_fd.as_raw_fd();
  unsafe {
    let flags = libc::fcntl(raw_fd, libc::F_GETFL);
    libc::fcntl(raw_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
  }

  let async_fd = match AsyncFd::with_interest(raw_fd, Interest::READABLE) {
    Ok(fd) => fd,
    Err(e) => {
      error!(
        component = "terminal",
        event = "terminal.async_fd.failed",
        terminal_id = %terminal_id,
        error = %e,
        "Failed to create AsyncFd for PTY"
      );
      sessions.remove(&terminal_id);
      return;
    }
  };

  let mut buf = [0u8; 4096];

  loop {
    tokio::select! {
      _ = cancel_rx.changed() => {
        if *cancel_rx.borrow() {
          break;
        }
      }
      readable = async_fd.readable() => {
        match readable {
          Ok(mut guard) => {
            match guard.try_io(|inner| {
              let n = unsafe {
                libc::read(
                  inner.as_raw_fd(),
                  buf.as_mut_ptr() as *mut libc::c_void,
                  buf.len(),
                )
              };
              if n > 0 {
                Ok(n as usize)
              } else if n == 0 {
                Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "PTY closed"))
              } else {
                Err(std::io::Error::last_os_error())
              }
            }) {
              Ok(Ok(n)) => {
                let chunk = buf[..n].to_vec();
                let _ = output_tx.send(chunk);
              }
              Ok(Err(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                debug!(
                  component = "terminal",
                  event = "terminal.pty.eof",
                  terminal_id = %terminal_id,
                  "PTY EOF — child process exited"
                );
                break;
              }
              Ok(Err(e)) => {
                warn!(
                  component = "terminal",
                  event = "terminal.pty.read_error",
                  terminal_id = %terminal_id,
                  error = %e,
                  "PTY read error"
                );
                break;
              }
              Err(_would_block) => {
                // AsyncFd spurious wake — retry on next readable event.
                continue;
              }
            }
          }
          Err(e) => {
            error!(
              component = "terminal",
              event = "terminal.async_fd.error",
              terminal_id = %terminal_id,
              error = %e,
              "AsyncFd readable error"
            );
            break;
          }
        }
      }
    }
  }

  // Clean up: reap child, remove from sessions map.
  if let Some((_, session)) = sessions.remove(&terminal_id) {
    // Best-effort waitpid to avoid zombie processes.
    let exit_status = match nix::sys::wait::waitpid(
      session.child_pid,
      Some(nix::sys::wait::WaitPidFlag::WNOHANG),
    ) {
      Ok(nix::sys::wait::WaitStatus::Exited(_, code)) => Some(code),
      Ok(nix::sys::wait::WaitStatus::Signaled(_, sig, _)) => Some(128 + sig as i32),
      _ => None,
    };
    info!(
      component = "terminal",
      event = "terminal.exited",
      terminal_id = %terminal_id,
      exit_code = ?exit_status,
      "Terminal session ended"
    );
  }

  // Prevent AsyncFd from closing the fd — OwnedFd handles that.
  std::mem::forget(async_fd);
}

/// Set the window size on a PTY file descriptor.
fn set_winsize(fd: i32, cols: u16, rows: u16) {
  let ws = libc::winsize {
    ws_row: rows,
    ws_col: cols,
    ws_xpixel: 0,
    ws_ypixel: 0,
  };
  unsafe {
    libc::ioctl(fd, libc::TIOCSWINSZ, &ws);
  }
}

/// Determine the user's default shell.
fn default_shell() -> String {
  std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
}

/// Build a binary frame for terminal output (server → client).
///
/// Format: `[type:1][id_len:1][id:N][payload:...]`
pub fn build_output_frame(terminal_id: &str, payload: &[u8]) -> Vec<u8> {
  let id_bytes = terminal_id.as_bytes();
  let id_len = id_bytes.len().min(255) as u8;
  let mut frame = Vec::with_capacity(2 + id_len as usize + payload.len());
  frame.push(FRAME_TYPE_OUTPUT);
  frame.push(id_len);
  frame.extend_from_slice(&id_bytes[..id_len as usize]);
  frame.extend_from_slice(payload);
  frame
}

/// Build a binary frame for terminal exit notification.
pub fn build_exit_frame(terminal_id: &str, exit_code: Option<i32>) -> Vec<u8> {
  let id_bytes = terminal_id.as_bytes();
  let id_len = id_bytes.len().min(255) as u8;
  let mut frame = Vec::with_capacity(2 + id_len as usize + 4);
  frame.push(FRAME_TYPE_EXITED);
  frame.push(id_len);
  frame.extend_from_slice(&id_bytes[..id_len as usize]);
  frame.extend_from_slice(&exit_code.unwrap_or(-1).to_le_bytes());
  frame
}

#[cfg(test)]
mod tests {
  use super::*;
  use tokio::time::{timeout, Duration};

  #[tokio::test]
  async fn create_and_receive_output() {
    let service = TerminalService::new();
    let mut rx = service
      .create(
        "test-term-1".to_string(),
        "/tmp".to_string(),
        Some("/bin/sh".to_string()),
        80,
        24,
      )
      .expect("create terminal");

    // Write a command — the shell should echo output back.
    service
      .write_input("test-term-1", b"echo hello_term\n")
      .expect("write input");

    // Collect output until we see our expected string or timeout.
    let mut collected = String::new();
    let found = timeout(Duration::from_secs(5), async {
      while let Ok(chunk) = rx.recv().await {
        collected.push_str(&String::from_utf8_lossy(&chunk));
        if collected.contains("hello_term") {
          return true;
        }
      }
      false
    })
    .await
    .unwrap_or(false);

    assert!(found, "Expected 'hello_term' in output, got: {collected}");

    service.destroy("test-term-1").expect("destroy");
  }

  #[tokio::test]
  async fn resize_does_not_crash() {
    let service = TerminalService::new();
    let _rx = service
      .create("test-resize".to_string(), "/tmp".to_string(), None, 80, 24)
      .expect("create");

    service.resize("test-resize", 120, 40).expect("resize");
    service.destroy("test-resize").expect("destroy");
  }

  #[tokio::test]
  async fn duplicate_id_rejected() {
    let service = TerminalService::new();
    let _rx = service
      .create("dup-id".to_string(), "/tmp".to_string(), None, 80, 24)
      .expect("first create");

    let err = service
      .create("dup-id".to_string(), "/tmp".to_string(), None, 80, 24)
      .expect_err("second create should fail");

    assert_eq!(err, TerminalCreateError::DuplicateId);
    service.destroy("dup-id").expect("cleanup");
  }

  #[test]
  fn build_output_frame_format() {
    let frame = build_output_frame("term-1", b"hello");
    assert_eq!(frame[0], FRAME_TYPE_OUTPUT);
    assert_eq!(frame[1], 6); // "term-1" length
    assert_eq!(&frame[2..8], b"term-1");
    assert_eq!(&frame[8..], b"hello");
  }

  #[test]
  fn build_exit_frame_format() {
    let frame = build_exit_frame("t", Some(42));
    assert_eq!(frame[0], FRAME_TYPE_EXITED);
    assert_eq!(frame[1], 1);
    assert_eq!(&frame[2..3], b"t");
    let exit_code = i32::from_le_bytes(frame[3..7].try_into().unwrap());
    assert_eq!(exit_code, 42);
  }
}
