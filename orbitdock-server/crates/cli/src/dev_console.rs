use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::{self, Stdout};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Context;
use crossterm::event::{
    DisableMouseCapture, EnableMouseCapture, Event as CrosstermEvent, EventStream, KeyCode,
    KeyEvent, KeyEventKind, KeyModifiers,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use futures::StreamExt;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::prelude::{Alignment, Color, Line, Modifier, Span, Style};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::{Frame, Terminal};
use tokio::sync::mpsc;

use orbitdock_server::{ServerLogEvent, ServerRunOptions, StderrLogMode};

const MAX_EVENTS_PER_CATEGORY: usize = 400;

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

    let server_future = orbitdock_server::run_server(options);
    tokio::pin!(server_future);

    loop {
        terminal.draw(|frame| draw(frame, &mut state))?;

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

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum Category {
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
    fn title(self) -> &'static str {
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

    fn all() -> &'static [Category] {
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
enum LevelFilter {
    All,
    InfoAndAbove,
    WarnAndAbove,
    ErrorOnly,
}

impl LevelFilter {
    fn title(self) -> &'static str {
        match self {
            Self::All => "All",
            Self::InfoAndAbove => "Info+",
            Self::WarnAndAbove => "Warn+",
            Self::ErrorOnly => "Error",
        }
    }

    fn next(self) -> Self {
        match self {
            Self::All => Self::InfoAndAbove,
            Self::InfoAndAbove => Self::WarnAndAbove,
            Self::WarnAndAbove => Self::ErrorOnly,
            Self::ErrorOnly => Self::All,
        }
    }

    fn matches(self, level: &str) -> bool {
        match self {
            Self::All => true,
            Self::InfoAndAbove => matches!(level, "INFO" | "WARN" | "ERROR"),
            Self::WarnAndAbove => matches!(level, "WARN" | "ERROR"),
            Self::ErrorOnly => level == "ERROR",
        }
    }
}

#[derive(Default)]
struct LevelCounts {
    error: usize,
    warn: usize,
    info: usize,
    debug: usize,
    trace: usize,
}

impl LevelCounts {
    fn increment(&mut self, level: &str) {
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
struct PaneState {
    category: Category,
    selected: usize,
    follow_tail: bool,
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

enum Overlay {
    CategoryPicker { selected: usize },
}

enum ConsoleAction {
    Continue,
    Quit,
    OpenPager,
}

struct DevConsoleState {
    bind_addr: SocketAddr,
    panes: [PaneState; 4],
    focus: usize,
    paused: bool,
    detail_open: bool,
    overlay: Option<Overlay>,
    level_filter: LevelFilter,
    session_pin: Option<String>,
    status_message: Option<String>,
    events_by_category: HashMap<Category, VecDeque<LogRow>>,
    level_counts: LevelCounts,
    total_events: usize,
}

impl DevConsoleState {
    fn new(bind_addr: SocketAddr) -> Self {
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

    fn push_event(&mut self, event: ServerLogEvent) {
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
            let receives_event = pane.category == primary
                || (pane.category == Category::Errors && event.level == "ERROR");
            if receives_event && pane.follow_tail && self.event_matches_filters(&event) {
                let visible = self.filtered_rows(pane.category);
                if !visible.is_empty() {
                    self.panes[pane_index].selected = visible.len().saturating_sub(1);
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

    fn filtered_rows(&self, category: Category) -> Vec<Arc<ServerLogEvent>> {
        self.events_by_category
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

    fn event_matches_filters(&self, event: &ServerLogEvent) -> bool {
        self.level_filter.matches(&event.level)
            && self
                .session_pin
                .as_ref()
                .is_none_or(|session_id| event.session_id.as_ref() == Some(session_id))
    }

    fn selected_event(&self) -> Option<Arc<ServerLogEvent>> {
        let pane = self.panes[self.focus];
        let rows = self.filtered_rows(pane.category);
        rows.get(pane.selected).cloned()
    }

    fn clamp_selection(&mut self, pane_index: usize) {
        let rows = self.filtered_rows(self.panes[pane_index].category);
        if rows.is_empty() {
            self.panes[pane_index].selected = 0;
            self.panes[pane_index].follow_tail = true;
            return;
        }

        if self.panes[pane_index].follow_tail {
            self.panes[pane_index].selected = rows.len().saturating_sub(1);
            return;
        }

        if self.panes[pane_index].selected >= rows.len() {
            self.panes[pane_index].selected = rows.len().saturating_sub(1);
        }
    }
}

fn handle_key_event(state: &mut DevConsoleState, key: KeyEvent) -> ConsoleAction {
    if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
        return ConsoleAction::Quit;
    }

    match &mut state.overlay {
        Some(Overlay::CategoryPicker { selected }) => {
            match key.code {
                KeyCode::Esc => state.overlay = None,
                KeyCode::Up => {
                    *selected = selected.saturating_sub(1);
                }
                KeyCode::Down => {
                    *selected = (*selected + 1).min(Category::all().len().saturating_sub(1));
                }
                KeyCode::Enter => {
                    state.panes[state.focus].category = Category::all()[*selected];
                    state.panes[state.focus].follow_tail = true;
                    state.clamp_selection(state.focus);
                    state.overlay = None;
                }
                _ => {}
            }
            return ConsoleAction::Continue;
        }
        None => {}
    }

    match key.code {
        KeyCode::Char('q') => return ConsoleAction::Quit,
        KeyCode::Tab => {
            state.focus = (state.focus + 1) % state.panes.len();
        }
        KeyCode::BackTab => {
            state.focus = (state.focus + state.panes.len() - 1) % state.panes.len();
        }
        KeyCode::Up => {
            let pane = &mut state.panes[state.focus];
            pane.selected = pane.selected.saturating_sub(1);
            pane.follow_tail = false;
        }
        KeyCode::Down => {
            let pane_index = state.focus;
            let visible_len = state.filtered_rows(state.panes[pane_index].category).len();
            if visible_len == 0 {
                return ConsoleAction::Continue;
            }
            let pane = &mut state.panes[pane_index];
            pane.selected = (pane.selected + 1).min(visible_len.saturating_sub(1));
            pane.follow_tail = pane.selected == visible_len.saturating_sub(1);
        }
        KeyCode::Home => {
            let pane = &mut state.panes[state.focus];
            pane.selected = 0;
            pane.follow_tail = false;
        }
        KeyCode::End => {
            state.panes[state.focus].follow_tail = true;
            state.clamp_selection(state.focus);
        }
        KeyCode::Enter => {
            state.detail_open = !state.detail_open;
        }
        KeyCode::Char(' ') => {
            state.paused = !state.paused;
        }
        KeyCode::Char('l') => {
            state.level_filter = state.level_filter.next();
            for pane_index in 0..state.panes.len() {
                state.clamp_selection(pane_index);
            }
        }
        KeyCode::Char('s') => {
            state.session_pin = state
                .selected_event()
                .and_then(|event| event.session_id.clone());
            for pane_index in 0..state.panes.len() {
                state.panes[pane_index].follow_tail = true;
                state.clamp_selection(pane_index);
            }
        }
        KeyCode::Char('u') => {
            state.session_pin = None;
            for pane_index in 0..state.panes.len() {
                state.panes[pane_index].follow_tail = true;
                state.clamp_selection(pane_index);
            }
        }
        KeyCode::Char('y') => {
            state.status_message = Some(match copy_selected_event_to_clipboard(state) {
                Ok(()) => "Copied selected event details to clipboard".to_string(),
                Err(error) => format!("Clipboard copy failed: {error}"),
            });
        }
        KeyCode::Char('c') => {
            let current = state.panes[state.focus].category;
            let selected = Category::all()
                .iter()
                .position(|category| *category == current)
                .unwrap_or(0);
            state.overlay = Some(Overlay::CategoryPicker { selected });
        }
        KeyCode::Char('o') => return ConsoleAction::OpenPager,
        _ => {}
    }

    ConsoleAction::Continue
}

fn draw(frame: &mut Frame<'_>, state: &mut DevConsoleState) {
    let root = frame.area();
    let columns = if state.detail_open {
        Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(66), Constraint::Percentage(34)])
            .split(root)
    } else {
        Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Min(1), Constraint::Length(0)])
            .split(root)
    };

    let left = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(10),
            Constraint::Length(3),
        ])
        .split(columns[0]);

    draw_header(frame, left[0], state);
    draw_panes(frame, left[1], state);
    draw_footer(frame, left[2], state);

    if state.detail_open {
        draw_detail(frame, columns[1], state);
    }

    if let Some(Overlay::CategoryPicker { selected }) = state.overlay {
        draw_category_picker(frame, root, selected);
    }
}

fn draw_header(frame: &mut Frame<'_>, area: Rect, state: &DevConsoleState) {
    let text = Line::from(vec![
        Span::styled(
            "OrbitDock Dev Console",
            Style::default().add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::raw(format!("bind {}", state.bind_addr)),
        Span::raw("  "),
        Span::styled(
            if state.paused { "paused" } else { "live" },
            Style::default().fg(if state.paused {
                Color::Yellow
            } else {
                Color::Green
            }),
        ),
        Span::raw("  "),
        Span::styled(
            format!("level {}", state.level_filter.title()),
            Style::default().fg(Color::Cyan),
        ),
        Span::raw("  "),
        Span::styled(
            format!("err {}", state.level_counts.error),
            Style::default().fg(Color::Red),
        ),
        Span::raw(" "),
        Span::styled(
            format!("warn {}", state.level_counts.warn),
            Style::default().fg(Color::Yellow),
        ),
        Span::raw(" "),
        Span::styled(
            format!("info {}", state.level_counts.info),
            Style::default().fg(Color::Blue),
        ),
        Span::raw("  "),
        Span::raw(format!("events {}", state.total_events)),
        Span::raw("  "),
        Span::raw(match &state.session_pin {
            Some(session_id) => format!("session {}", short_session_id(session_id)),
            None => "session all".to_string(),
        }),
        Span::raw("  "),
        Span::styled(
            state
                .status_message
                .clone()
                .unwrap_or_else(|| "ready".to_string()),
            Style::default().fg(Color::Green),
        ),
    ]);

    let header = Paragraph::new(text)
        .block(Block::default().borders(Borders::ALL).title("Status"))
        .wrap(Wrap { trim: false });
    frame.render_widget(header, area);
}

fn draw_panes(frame: &mut Frame<'_>, area: Rect, state: &mut DevConsoleState) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(area);
    let top = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(rows[0]);
    let bottom = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(rows[1]);

    for (index, area) in [top[0], top[1], bottom[0], bottom[1]]
        .into_iter()
        .enumerate()
    {
        draw_pane(frame, area, state, index);
    }
}

fn draw_pane(frame: &mut Frame<'_>, area: Rect, state: &mut DevConsoleState, pane_index: usize) {
    state.clamp_selection(pane_index);

    let pane = state.panes[pane_index];
    let rows = state.filtered_rows(pane.category);
    let title = format!(
        "{} {}",
        pane.category.title(),
        if pane.follow_tail { "• tail" } else { "" }
    );
    let border_style = if state.focus == pane_index {
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default()
    };

    let items = if rows.is_empty() {
        vec![ListItem::new(Line::from("No matching events yet"))]
    } else {
        rows.iter()
            .map(|event| ListItem::new(Line::from(render_event_summary(event))))
            .collect()
    };

    let mut list_state = ListState::default();
    if !rows.is_empty() {
        list_state.select(Some(pane.selected));
    }

    let list = List::new(items)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(border_style)
                .title(title),
        )
        .highlight_style(Style::default().bg(Color::DarkGray))
        .highlight_symbol(">");
    frame.render_stateful_widget(list, area, &mut list_state);
}

fn draw_detail(frame: &mut Frame<'_>, area: Rect, state: &DevConsoleState) {
    let detail = state
        .selected_event()
        .and_then(|event| serde_json::to_string_pretty(event.as_ref()).ok())
        .unwrap_or_else(|| "Select a row to inspect its structured payload.".to_string());

    let widget = Paragraph::new(detail)
        .block(Block::default().borders(Borders::ALL).title("Details"))
        .wrap(Wrap { trim: false });
    frame.render_widget(widget, area);
}

fn draw_footer(frame: &mut Frame<'_>, area: Rect, state: &DevConsoleState) {
    let footer = Paragraph::new(Line::from(vec![
        Span::raw("Tab panes  "),
        Span::raw("↑↓ rows  "),
        Span::raw("c category  "),
        Span::raw("Enter details  "),
        Span::raw("Space pause  "),
        Span::raw("l level  "),
        Span::raw("s pin  "),
        Span::raw("u unpin  "),
        Span::raw("y copy  "),
        Span::raw("o pager  "),
        Span::raw("q quit"),
        Span::raw(if state.overlay.is_some() {
            "  Esc close picker"
        } else {
            ""
        }),
    ]))
    .alignment(Alignment::Left)
    .block(Block::default().borders(Borders::ALL).title("Keys"));
    frame.render_widget(footer, area);
}

fn draw_category_picker(frame: &mut Frame<'_>, area: Rect, selected: usize) {
    let popup = centered_rect(40, 55, area);
    let items: Vec<ListItem<'_>> = Category::all()
        .iter()
        .map(|category| ListItem::new(Line::from(category.title())))
        .collect();
    let mut state = ListState::default();
    state.select(Some(selected));

    frame.render_widget(Clear, popup);
    let list = List::new(items)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title("Choose Category"),
        )
        .highlight_style(Style::default().bg(Color::DarkGray))
        .highlight_symbol(">");
    frame.render_stateful_widget(list, popup, &mut state);
}

fn render_event_summary(event: &ServerLogEvent) -> Vec<Span<'static>> {
    let mut spans = vec![
        Span::styled(
            short_timestamp(&event.timestamp),
            Style::default().fg(Color::DarkGray),
        ),
        Span::raw(" "),
        Span::styled(level_label(&event.level), level_style(&event.level)),
        Span::raw(" "),
    ];

    if let Some(component) = &event.component {
        spans.push(Span::styled(
            component.clone(),
            Style::default().fg(Color::Cyan),
        ));
        spans.push(Span::raw(" "));
    }

    if let Some(event_name) = &event.event {
        spans.push(Span::styled(
            event_name.clone(),
            Style::default().fg(Color::Magenta),
        ));
        spans.push(Span::raw(" "));
    }

    spans.push(Span::raw(event.message.clone()));

    if let Some(session_id) = &event.session_id {
        spans.push(Span::raw(" "));
        spans.push(Span::styled(
            format!("[{}]", short_session_id(session_id)),
            Style::default().fg(Color::Yellow),
        ));
    }

    spans
}

fn level_label(level: &str) -> String {
    match level {
        "ERROR" => "ERR".to_string(),
        "WARN" => "WRN".to_string(),
        "INFO" => "INF".to_string(),
        "DEBUG" => "DBG".to_string(),
        "TRACE" => "TRC".to_string(),
        other => other.to_string(),
    }
}

fn level_style(level: &str) -> Style {
    match level {
        "ERROR" => Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        "WARN" => Style::default().fg(Color::Yellow),
        "INFO" => Style::default().fg(Color::Blue),
        "DEBUG" => Style::default().fg(Color::Gray),
        "TRACE" => Style::default().fg(Color::DarkGray),
        _ => Style::default(),
    }
}

fn short_timestamp(timestamp: &str) -> String {
    timestamp
        .split('T')
        .nth(1)
        .and_then(|value| value.split('.').next())
        .unwrap_or(timestamp)
        .to_string()
}

fn short_session_id(session_id: &str) -> String {
    session_id.chars().take(8).collect()
}

fn centered_rect(width_percent: u16, height_percent: u16, area: Rect) -> Rect {
    let vertical = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - height_percent) / 2),
            Constraint::Percentage(height_percent),
            Constraint::Percentage((100 - height_percent) / 2),
        ])
        .split(area);
    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - width_percent) / 2),
            Constraint::Percentage(width_percent),
            Constraint::Percentage((100 - width_percent) / 2),
        ])
        .split(vertical[1])[1]
}

fn classify_category(event: &ServerLogEvent) -> Category {
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
        execute!(stdout, EnterAlternateScreen, EnableMouseCapture)
            .context("enter alternate screen")?;
        let backend = CrosstermBackend::new(stdout);
        let terminal = Terminal::new(backend).context("create terminal")?;
        Ok(Self { terminal })
    }

    fn draw<F>(&mut self, render: F) -> anyhow::Result<()>
    where
        F: FnOnce(&mut Frame<'_>),
    {
        self.terminal.draw(render).context("draw dev console")?;
        Ok(())
    }

    fn suspend(&mut self) -> anyhow::Result<()> {
        disable_raw_mode().context("disable raw mode for pager")?;
        execute!(
            self.terminal.backend_mut(),
            LeaveAlternateScreen,
            DisableMouseCapture
        )
        .context("leave alternate screen for pager")?;
        self.terminal
            .show_cursor()
            .context("show cursor before opening pager")?;
        Ok(())
    }

    fn resume(&mut self) -> anyhow::Result<()> {
        enable_raw_mode().context("re-enable raw mode after pager")?;
        execute!(
            self.terminal.backend_mut(),
            EnterAlternateScreen,
            EnableMouseCapture
        )
        .context("re-enter alternate screen after pager")?;
        self.terminal
            .clear()
            .context("clear terminal after pager")?;
        Ok(())
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(
            self.terminal.backend_mut(),
            LeaveAlternateScreen,
            DisableMouseCapture
        );
        let _ = self.terminal.show_cursor();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_event(target: &str) -> ServerLogEvent {
        ServerLogEvent {
            timestamp: "2026-03-19T05:03:47.794Z".to_string(),
            level: "INFO".to_string(),
            target: target.to_string(),
            message: "sample".to_string(),
            component: None,
            event: None,
            session_id: None,
            request_id: None,
            file: None,
            line: None,
            current_span: None,
            fields: Default::default(),
        }
    }

    #[test]
    fn classifies_codex_targets_without_component() {
        assert_eq!(
            classify_category(&sample_event("codex_otel.trace_safe")),
            Category::Codex
        );
        assert_eq!(
            classify_category(&sample_event("orbitdock_connector_codex::runtime")),
            Category::Codex
        );
    }

    #[test]
    fn classifies_transcript_targets() {
        assert_eq!(
            classify_category(&sample_event(
                "orbitdock_server::runtime::session_runtime_helpers"
            )),
            Category::TranscriptRollout
        );
        assert_eq!(
            classify_category(&sample_event("orbitdock_connector_core::transition")),
            Category::TranscriptRollout
        );
    }

    #[test]
    fn classifies_component_first() {
        let mut event = sample_event("orbitdock_server::app");
        event.component = Some("hook_handler".to_string());
        assert_eq!(classify_category(&event), Category::Claude);
    }
}
