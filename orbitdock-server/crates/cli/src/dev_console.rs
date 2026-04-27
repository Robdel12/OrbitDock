#[path = "dev_console/input.rs"]
mod input;
#[path = "dev_console/render.rs"]
mod render;
#[path = "dev_console/runtime.rs"]
mod runtime;
#[path = "dev_console/state.rs"]
mod state;

pub use runtime::{run_server_with_dev_console, try_enter_terminal, TerminalSession};

pub(crate) use input::{handle_key_event, ConsoleAction};
pub(crate) use render::draw;
#[cfg(test)]
pub(crate) use runtime::TerminalSuspendState;
pub(crate) use state::DevConsoleState;
#[cfg(test)]
pub(crate) use state::{classify_category, Category};

#[cfg(test)]
mod tests;
