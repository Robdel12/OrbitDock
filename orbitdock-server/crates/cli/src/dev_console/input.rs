use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use super::state::{Category, DevConsoleState, Overlay};

pub(crate) enum ConsoleAction {
  Continue,
  Quit,
  OpenPager,
  CopySelectedEvent,
}

pub(crate) fn handle_key_event(state: &mut DevConsoleState, key: KeyEvent) -> ConsoleAction {
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
      return ConsoleAction::CopySelectedEvent;
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
