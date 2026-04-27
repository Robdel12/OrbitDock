use orbitdock_server::ServerLogEvent;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::prelude::{Alignment, Color, Line, Modifier, Span, Style};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;

use super::state::{Category, DevConsoleState, Overlay};

pub(crate) fn draw(frame: &mut Frame<'_>, state: &mut DevConsoleState) {
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

  if let Some(Overlay::CategoryPicker { selected }) = &state.overlay {
    draw_category_picker(frame, root, *selected);
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
    rows
      .iter()
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
