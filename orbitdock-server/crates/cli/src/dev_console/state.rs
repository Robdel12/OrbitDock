use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use orbitdock_server::ServerLogEvent;

pub(crate) const MAX_EVENTS_PER_CATEGORY: usize = 400;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum Category {
  Errors,
  WebSocket,
  Claude,
  Codex,
  Mission,
  SessionApproval,
  TranscriptRollout,
  PersistenceRestore,
  ServerSystem,
  Other,
}

impl Category {
  pub(crate) fn title(self) -> &'static str {
    match self {
      Self::Errors => "Errors",
      Self::WebSocket => "WebSocket",
      Self::Claude => "Claude",
      Self::Codex => "Codex",
      Self::Mission => "Mission",
      Self::SessionApproval => "Session / Approval",
      Self::TranscriptRollout => "Transcript / Rollout",
      Self::PersistenceRestore => "Persistence / Restore",
      Self::ServerSystem => "Server / System",
      Self::Other => "Other",
    }
  }

  pub(crate) fn all() -> &'static [Category] {
    &[
      Self::Errors,
      Self::WebSocket,
      Self::Claude,
      Self::Codex,
      Self::Mission,
      Self::SessionApproval,
      Self::TranscriptRollout,
      Self::PersistenceRestore,
      Self::ServerSystem,
      Self::Other,
    ]
  }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LevelFilter {
  All,
  InfoAndAbove,
  WarnAndAbove,
  ErrorOnly,
}

impl LevelFilter {
  pub(crate) fn title(self) -> &'static str {
    match self {
      Self::All => "All",
      Self::InfoAndAbove => "Info+",
      Self::WarnAndAbove => "Warn+",
      Self::ErrorOnly => "Error",
    }
  }

  pub(crate) fn next(self) -> Self {
    match self {
      Self::All => Self::InfoAndAbove,
      Self::InfoAndAbove => Self::WarnAndAbove,
      Self::WarnAndAbove => Self::ErrorOnly,
      Self::ErrorOnly => Self::All,
    }
  }

  pub(crate) fn matches(self, level: &str) -> bool {
    match self {
      Self::All => true,
      Self::InfoAndAbove => matches!(level, "INFO" | "WARN" | "ERROR"),
      Self::WarnAndAbove => matches!(level, "WARN" | "ERROR"),
      Self::ErrorOnly => level == "ERROR",
    }
  }
}

#[derive(Default)]
pub(crate) struct LevelCounts {
  pub(crate) error: usize,
  pub(crate) warn: usize,
  pub(crate) info: usize,
  pub(crate) debug: usize,
  pub(crate) trace: usize,
}

impl LevelCounts {
  pub(crate) fn increment(&mut self, level: &str) {
    match level {
      "ERROR" => self.error += 1,
      "WARN" => self.warn += 1,
      "INFO" => self.info += 1,
      "DEBUG" => self.debug += 1,
      "TRACE" => self.trace += 1,
      _ => {}
    }
  }
}

#[derive(Clone)]
struct LogRow {
  event: Arc<ServerLogEvent>,
}

#[derive(Clone, Copy)]
pub(crate) struct PaneState {
  pub(crate) category: Category,
  pub(crate) selected: usize,
  pub(crate) follow_tail: bool,
}

impl PaneState {
  fn new(category: Category) -> Self {
    Self {
      category,
      selected: 0,
      follow_tail: true,
    }
  }
}

pub(crate) enum Overlay {
  CategoryPicker { selected: usize },
}

pub(crate) struct DevConsoleState {
  pub(crate) bind_addr: std::net::SocketAddr,
  pub(crate) panes: [PaneState; 4],
  pub(crate) focus: usize,
  pub(crate) paused: bool,
  pub(crate) detail_open: bool,
  pub(crate) overlay: Option<Overlay>,
  pub(crate) level_filter: LevelFilter,
  pub(crate) session_pin: Option<String>,
  pub(crate) status_message: Option<String>,
  events_by_category: HashMap<Category, VecDeque<LogRow>>,
  pub(crate) level_counts: LevelCounts,
  pub(crate) total_events: usize,
}

impl DevConsoleState {
  pub(crate) fn new(bind_addr: std::net::SocketAddr) -> Self {
    let mut events_by_category = HashMap::new();
    for category in Category::all() {
      events_by_category.insert(*category, VecDeque::new());
    }

    Self {
      bind_addr,
      panes: [
        PaneState::new(Category::Errors),
        PaneState::new(Category::WebSocket),
        PaneState::new(Category::Claude),
        PaneState::new(Category::Codex),
      ],
      focus: 0,
      paused: false,
      detail_open: true,
      overlay: None,
      level_filter: LevelFilter::All,
      session_pin: None,
      status_message: None,
      events_by_category,
      level_counts: LevelCounts::default(),
      total_events: 0,
    }
  }

  pub(crate) fn push_event(&mut self, event: ServerLogEvent) {
    self.level_counts.increment(&event.level);
    self.total_events += 1;

    let primary = classify_category(&event);
    let event = Arc::new(event);
    self.push_row(primary, Arc::clone(&event));

    if event.level == "ERROR" {
      self.push_row(Category::Errors, Arc::clone(&event));
    }

    if self.paused {
      return;
    }

    for pane_index in 0..self.panes.len() {
      let pane = self.panes[pane_index];
      let receives_event =
        pane.category == primary || (pane.category == Category::Errors && event.level == "ERROR");
      if receives_event && pane.follow_tail && self.event_matches_filters(&event) {
        let visible_count = self.filtered_row_count(pane.category);
        if visible_count > 0 {
          self.panes[pane_index].selected = visible_count.saturating_sub(1);
        }
      }
    }
  }

  fn push_row(&mut self, category: Category, event: Arc<ServerLogEvent>) {
    let rows = self
      .events_by_category
      .get_mut(&category)
      .expect("category bucket should exist");
    rows.push_back(LogRow { event });
    while rows.len() > MAX_EVENTS_PER_CATEGORY {
      rows.pop_front();
    }
  }

  pub(crate) fn filtered_rows(&self, category: Category) -> Vec<Arc<ServerLogEvent>> {
    self
      .events_by_category
      .get(&category)
      .into_iter()
      .flat_map(|rows| rows.iter())
      .filter_map(|row| {
        if self.event_matches_filters(&row.event) {
          Some(Arc::clone(&row.event))
        } else {
          None
        }
      })
      .collect()
  }

  pub(crate) fn filtered_row_count(&self, category: Category) -> usize {
    self
      .events_by_category
      .get(&category)
      .into_iter()
      .flat_map(|rows| rows.iter())
      .filter(|row| self.event_matches_filters(&row.event))
      .count()
  }

  pub(crate) fn event_matches_filters(&self, event: &ServerLogEvent) -> bool {
    self.level_filter.matches(&event.level)
      && self
        .session_pin
        .as_ref()
        .is_none_or(|session_id| event.session_id.as_ref() == Some(session_id))
  }

  pub(crate) fn selected_event(&self) -> Option<Arc<ServerLogEvent>> {
    let pane = self.panes[self.focus];
    self
      .events_by_category
      .get(&pane.category)
      .into_iter()
      .flat_map(|rows| rows.iter())
      .filter(|row| self.event_matches_filters(&row.event))
      .nth(pane.selected)
      .map(|row| Arc::clone(&row.event))
  }

  pub(crate) fn clamp_selection(&mut self, pane_index: usize) {
    let row_count = self.filtered_row_count(self.panes[pane_index].category);
    if row_count == 0 {
      self.panes[pane_index].selected = 0;
      self.panes[pane_index].follow_tail = true;
      return;
    }

    if self.panes[pane_index].follow_tail {
      self.panes[pane_index].selected = row_count.saturating_sub(1);
      return;
    }

    if self.panes[pane_index].selected >= row_count {
      self.panes[pane_index].selected = row_count.saturating_sub(1);
    }
  }
}

pub(crate) fn classify_category(event: &ServerLogEvent) -> Category {
  if event.level == "ERROR" {
    return Category::Errors;
  }

  match event.component.as_deref() {
    Some("websocket") => return Category::WebSocket,
    Some("claude_connector") | Some("hook_handler") => return Category::Claude,
    Some("mission_control") => return Category::Mission,
    Some("session") | Some("approval") | Some("runtime") => {
      return Category::SessionApproval;
    }
    Some("transcript_sync") | Some("transition") | Some("rollout_watcher") => {
      return Category::TranscriptRollout;
    }
    Some("persistence") | Some("restore") | Some("migrations") => {
      return Category::PersistenceRestore;
    }
    Some("server") | Some("logging") | Some("auth") | Some("worktree") | Some("shell") => {
      return Category::ServerSystem;
    }
    _ => {}
  }

  let target = event.target.as_str();
  if target.contains("transport::websocket") {
    return Category::WebSocket;
  }
  if target.starts_with("orbitdock_connector_claude")
    || target.contains("connectors::claude")
    || target.contains("claude_hooks")
  {
    return Category::Claude;
  }
  if target.starts_with("codex_")
    || target.starts_with("codex_core::")
    || target.starts_with("codex_api::")
    || target.starts_with("orbitdock_connector_codex::")
  {
    return Category::Codex;
  }
  if target.contains("mission_") {
    return Category::Mission;
  }
  if target.contains("connector_core::transition")
    || target.contains("session_runtime_helpers")
    || target.contains("codex_rollout")
  {
    return Category::TranscriptRollout;
  }
  if target.contains("persistence") || target.contains("migration") {
    return Category::PersistenceRestore;
  }
  if target.starts_with("orbitdock_server::app")
    || target.starts_with("orbitdock_server::support")
    || target.starts_with("orbitdock_server::domain::worktrees")
  {
    return Category::ServerSystem;
  }

  Category::Other
}
