use std::fs;
use std::io::{self, Stdout};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Context;
use crossterm::event::{Event as CrosstermEvent, EventStream, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
  disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use futures::StreamExt;
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
#[cfg(unix)]
use tokio::signal::unix::{signal, Signal, SignalKind};
use tokio::sync::mpsc;

use orbitdock_server::{ServerRunOptions, StderrLogMode};

use super::{draw, handle_key_event, ConsoleAction, DevConsoleState};

/// Try to set up the TUI terminal. This is separated from `run_server_with_dev_console`
/// so callers can distinguish "TUI setup failed" (safe to fall back to plain logs)
/// from "server itself failed" (should propagate, not retry — which would panic
/// because the tracing subscriber is already installed).
pub fn try_enter_terminal() -> anyhow::Result<TerminalSession> {
  TerminalSession::enter()
}

pub async fn run_server_with_dev_console(
  mut options: ServerRunOptions,
  mut terminal: TerminalSession,
) -> anyhow::Result<()> {
  let bind_addr = options.bind_addr;
  let (tx, mut rx) = mpsc::unbounded_channel();
  options.logging.live_sink = Some(tx);
  options.logging.stderr_mode = StderrLogMode::Off;

  let mut input = EventStream::new();
  let mut state = DevConsoleState::new(bind_addr);
  #[cfg(unix)]
  let mut job_control = JobControlSignals::new()?;
  let mut terminal_suspend_state = TerminalSuspendState::default();

  let server_future = orbitdock_server::run_server(options);
  tokio::pin!(server_future);

  loop {
    terminal.draw(|frame| draw(frame, &mut state))?;

    #[cfg(unix)]
    tokio::select! {
        server_result = &mut server_future => {
            return server_result;
        }
        maybe_event = rx.recv() => {
            if let Some(event) = maybe_event {
                state.push_event(event);
            } else {
                break;
            }
        }
        maybe_input = input.next() => {
            match maybe_input.transpose()? {
                Some(CrosstermEvent::Key(key)) if key.kind == KeyEventKind::Press => {
                    match handle_key_event(&mut state, key) {
                        ConsoleAction::Continue => {}
                        ConsoleAction::Quit => break,
                        ConsoleAction::OpenPager => {
                            state.status_message = Some(match open_selected_event_in_pager(&state, &mut terminal) {
                                Ok(()) => "Opened selected event in pager".to_string(),
                                Err(error) => format!("Pager open failed: {error}"),
                            });
                        }
                        ConsoleAction::CopySelectedEvent => {
                            state.status_message = Some(match copy_selected_event_to_clipboard(&state) {
                                Ok(()) => "Copied selected event details to clipboard".to_string(),
                                Err(error) => format!("Clipboard copy failed: {error}"),
                            });
                        }
                    }
                }
                Some(CrosstermEvent::Resize(_, _)) => {}
                Some(_) => {}
                None => break,
            }
        }
        _ = job_control.sigtstp.recv() => {
            suspend_for_job_control_signal(
                &mut terminal,
                &mut terminal_suspend_state,
                libc::SIGTSTP,
            )?;
        }
        _ = job_control.sigttin.recv() => {
            suspend_for_job_control_signal(
                &mut terminal,
                &mut terminal_suspend_state,
                libc::SIGTTIN,
            )?;
        }
        _ = job_control.sigttou.recv() => {
            suspend_for_job_control_signal(
                &mut terminal,
                &mut terminal_suspend_state,
                libc::SIGTTOU,
            )?;
        }
        _ = job_control.sigcont.recv(), if terminal_suspend_state.is_suspended() => {
            terminal.resume()?;
            terminal_suspend_state.mark_resumed();
        }
    }

    #[cfg(not(unix))]
    tokio::select! {
        server_result = &mut server_future => {
            return server_result;
        }
        maybe_event = rx.recv() => {
            if let Some(event) = maybe_event {
                state.push_event(event);
            } else {
                break;
            }
        }
        maybe_input = input.next() => {
            match maybe_input.transpose()? {
                Some(CrosstermEvent::Key(key)) if key.kind == KeyEventKind::Press => {
                    match handle_key_event(&mut state, key) {
                        ConsoleAction::Continue => {}
                        ConsoleAction::Quit => break,
                        ConsoleAction::OpenPager => {
                            state.status_message = Some(match open_selected_event_in_pager(&state, &mut terminal) {
                                Ok(()) => "Opened selected event in pager".to_string(),
                                Err(error) => format!("Pager open failed: {error}"),
                            });
                        }
                        ConsoleAction::CopySelectedEvent => {
                            state.status_message = Some(match copy_selected_event_to_clipboard(&state) {
                                Ok(()) => "Copied selected event details to clipboard".to_string(),
                                Err(error) => format!("Clipboard copy failed: {error}"),
                            });
                        }
                    }
                }
                Some(CrosstermEvent::Resize(_, _)) => {}
                Some(_) => {}
                None => break,
            }
        }
    }
  }

  Ok(())
}

#[derive(Debug, Default)]
pub(crate) struct TerminalSuspendState {
  suspended_for_signal: bool,
}

impl TerminalSuspendState {
  pub(crate) fn is_suspended(&self) -> bool {
    self.suspended_for_signal
  }

  pub(crate) fn mark_suspended(&mut self) -> bool {
    let should_suspend = !self.suspended_for_signal;
    self.suspended_for_signal = true;
    should_suspend
  }

  pub(crate) fn mark_resumed(&mut self) {
    self.suspended_for_signal = false;
  }
}

#[cfg(unix)]
struct JobControlSignals {
  sigtstp: Signal,
  sigcont: Signal,
  sigttin: Signal,
  sigttou: Signal,
}

#[cfg(unix)]
impl JobControlSignals {
  fn new() -> anyhow::Result<Self> {
    Ok(Self {
      sigtstp: signal(SignalKind::from_raw(libc::SIGTSTP)).context("listen for SIGTSTP")?,
      sigcont: signal(SignalKind::from_raw(libc::SIGCONT)).context("listen for SIGCONT")?,
      sigttin: signal(SignalKind::from_raw(libc::SIGTTIN)).context("listen for SIGTTIN")?,
      sigttou: signal(SignalKind::from_raw(libc::SIGTTOU)).context("listen for SIGTTOU")?,
    })
  }
}

#[cfg(unix)]
fn suspend_for_job_control_signal(
  terminal: &mut TerminalSession,
  suspend_state: &mut TerminalSuspendState,
  signal: i32,
) -> anyhow::Result<()> {
  if suspend_state.mark_suspended() {
    terminal.suspend()?;
  }

  signal_hook::low_level::emulate_default_handler(signal)
    .with_context(|| format!("emulate default handler for signal {signal}"))?;
  Ok(())
}

fn copy_selected_event_to_clipboard(state: &DevConsoleState) -> anyhow::Result<()> {
  let event = state
    .selected_event()
    .context("No selected event to copy")?;
  let payload = serde_json::to_string_pretty(event.as_ref())?;
  copy_text_to_clipboard(&payload)
}

fn open_selected_event_in_pager(
  state: &DevConsoleState,
  terminal: &mut TerminalSession,
) -> anyhow::Result<()> {
  let event = state
    .selected_event()
    .context("No selected event to open")?;
  let payload = serde_json::to_string_pretty(event.as_ref())?;
  let temp_path = write_pager_file(&payload)?;
  let (pager_command, pager_args) = pager_command_and_args();

  terminal.suspend()?;

  let pager_result = (|| -> anyhow::Result<()> {
    let status = Command::new(&pager_command)
      .args(&pager_args)
      .arg(&temp_path)
      .stdin(Stdio::inherit())
      .stdout(Stdio::inherit())
      .stderr(Stdio::inherit())
      .status()
      .with_context(|| format!("spawn pager {pager_command}"))?;

    if status.success() {
      Ok(())
    } else {
      anyhow::bail!("pager exited with {status}");
    }
  })();

  let resume_result = terminal.resume();
  let _ = fs::remove_file(&temp_path);

  resume_result?;
  pager_result
}

fn copy_text_to_clipboard(text: &str) -> anyhow::Result<()> {
  #[cfg(target_os = "macos")]
  {
    copy_with_command("pbcopy", &[], text)
  }

  #[cfg(target_os = "windows")]
  {
    copy_with_command("clip", &[], text)
  }

  #[cfg(not(any(target_os = "macos", target_os = "windows")))]
  {
    copy_with_command("wl-copy", &[], text)
      .or_else(|_| copy_with_command("xclip", &["-selection", "clipboard"], text))
  }
}

fn copy_with_command(command: &str, args: &[&str], text: &str) -> anyhow::Result<()> {
  let mut child = Command::new(command)
    .args(args)
    .stdin(Stdio::piped())
    .stdout(Stdio::null())
    .stderr(Stdio::piped())
    .spawn()
    .with_context(|| format!("spawn {command}"))?;

  {
    use std::io::Write;

    let stdin = child
      .stdin
      .as_mut()
      .context("clipboard command missing stdin")?;
    stdin.write_all(text.as_bytes())?;
  }

  let output = child.wait_with_output()?;
  if output.status.success() {
    Ok(())
  } else {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let reason = if stderr.is_empty() {
      format!("{command} exited with {}", output.status)
    } else {
      stderr
    };
    anyhow::bail!("{reason}");
  }
}

fn write_pager_file(text: &str) -> anyhow::Result<PathBuf> {
  let now = SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .unwrap_or_default()
    .as_millis();
  let path = std::env::temp_dir().join(format!(
    "orbitdock-log-event-{}-{now}.json",
    std::process::id()
  ));
  fs::write(&path, text)?;
  Ok(path)
}

fn pager_command_and_args() -> (String, Vec<String>) {
  let pager = std::env::var("PAGER")
    .ok()
    .filter(|value| !value.trim().is_empty())
    .unwrap_or_else(|| "less".to_string());
  let mut parts = pager
    .split_whitespace()
    .map(ToOwned::to_owned)
    .collect::<Vec<_>>();
  let command = if parts.is_empty() {
    "less".to_string()
  } else {
    parts.remove(0)
  };
  let mut args = parts;
  if command == "less" && !args.iter().any(|arg| arg == "-R") {
    args.insert(0, "-R".to_string());
  }
  (command, args)
}

pub struct TerminalSession {
  terminal: Terminal<CrosstermBackend<Stdout>>,
}

impl TerminalSession {
  fn enter() -> anyhow::Result<Self> {
    enable_raw_mode().context("enable raw mode")?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen).context("enter alternate screen")?;
    let backend = CrosstermBackend::new(stdout);
    let terminal = Terminal::new(backend).context("create terminal")?;
    Ok(Self { terminal })
  }

  fn draw<F>(&mut self, render: F) -> anyhow::Result<()>
  where
    F: FnOnce(&mut ratatui::Frame<'_>),
  {
    self.terminal.draw(render).context("draw dev console")?;
    Ok(())
  }

  fn suspend(&mut self) -> anyhow::Result<()> {
    disable_raw_mode().context("disable raw mode for pager")?;
    execute!(self.terminal.backend_mut(), LeaveAlternateScreen)
      .context("leave alternate screen for pager")?;
    self
      .terminal
      .show_cursor()
      .context("show cursor before opening pager")?;
    Ok(())
  }

  fn resume(&mut self) -> anyhow::Result<()> {
    enable_raw_mode().context("re-enable raw mode after pager")?;
    execute!(self.terminal.backend_mut(), EnterAlternateScreen)
      .context("re-enter alternate screen after pager")?;
    self
      .terminal
      .clear()
      .context("clear terminal after pager")?;
    Ok(())
  }
}

impl Drop for TerminalSession {
  fn drop(&mut self) {
    let _ = disable_raw_mode();
    let _ = execute!(self.terminal.backend_mut(), LeaveAlternateScreen);
    let _ = self.terminal.show_cursor();
  }
}
