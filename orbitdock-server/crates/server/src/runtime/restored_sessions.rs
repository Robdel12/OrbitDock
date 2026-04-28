#[path = "session_restore/direct_resume.rs"]
mod direct_resume;
#[path = "session_restore/hydration.rs"]
mod hydration;
#[path = "session_restore/parsing.rs"]
mod parsing;
#[path = "session_restore/state.rs"]
mod state;

#[cfg(test)]
use crate::infrastructure::persistence::RestoredSession;
#[cfg(test)]
use orbitdock_protocol::Provider;

pub(crate) use direct_resume::{load_prepared_resume_session, PreparedResumeSession};
pub(crate) use hydration::hydrate_restored_rows_if_missing;
pub(crate) use parsing::{parse_provider, parse_session_status, parse_work_status};
pub(crate) use state::{restored_session_to_persisted_handle, restored_session_to_state};

#[cfg(test)]
#[path = "restored_sessions_tests.rs"]
mod restored_sessions_tests;
