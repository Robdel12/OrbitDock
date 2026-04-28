pub(super) fn write_pid_file() {
  let pid_path = crate::infrastructure::paths::pid_file_path();
  let _ = std::fs::write(&pid_path, std::process::id().to_string());
}

pub(super) fn cleanup_stale_pid_file() {
  let pid_path = crate::infrastructure::paths::pid_file_path();
  let Ok(pid_str) = std::fs::read_to_string(&pid_path) else {
    return;
  };

  let Ok(pid) = pid_str.trim().parse::<u32>() else {
    remove_pid_file();
    return;
  };

  if pid == 0 || !process_alive(pid) {
    remove_pid_file();
  }
}

pub(super) fn remove_pid_file() {
  let pid_path = crate::infrastructure::paths::pid_file_path();
  let _ = std::fs::remove_file(&pid_path);
}

pub(super) struct PidFileGuard;

impl Drop for PidFileGuard {
  fn drop(&mut self) {
    remove_pid_file();
  }
}

pub(super) fn process_alive(pid: u32) -> bool {
  unsafe { libc::kill(pid as i32, 0) == 0 }
}
