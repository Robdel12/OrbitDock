use orbitdock_protocol::{SessionState, StateChanges};

use crate::domain::sessions::session::SessionSnapshot;

pub(crate) fn include_snapshot_delta_changes(
  changes: &mut StateChanges,
  previous_transport: &SessionSnapshot,
  previous_state: &SessionState,
  current_transport: &SessionSnapshot,
  current_state: &SessionState,
) -> bool {
  let mut changed = false;

  if current_transport.status != previous_transport.status {
    changes.status = Some(current_transport.status);
    changed = true;
  }
  if current_transport.work_status != previous_transport.work_status {
    changes.work_status = Some(current_transport.work_status);
    changes.steerable = Some(current_transport.steerable);
    changed = true;
  }
  if current_transport.control_mode != previous_transport.control_mode {
    changes.control_mode = Some(current_transport.control_mode);
    changed = true;
  }
  if current_transport.lifecycle_state != previous_transport.lifecycle_state {
    changes.lifecycle_state = Some(current_transport.lifecycle_state);
    changed = true;
  }
  if current_state.accepts_user_input != previous_state.accepts_user_input {
    changes.accepts_user_input = Some(current_state.accepts_user_input);
    changed = true;
  }
  if current_transport.steerable != previous_transport.steerable {
    changes.steerable = Some(current_transport.steerable);
    changed = true;
  }
  if current_state.current_turn_id != previous_state.current_turn_id {
    changes.current_turn_id = Some(current_state.current_turn_id.clone());
    changed = true;
  }

  changed
}
