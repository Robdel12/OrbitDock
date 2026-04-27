#[path = "session_queries/conversation.rs"]
mod conversation;
#[path = "session_queries/detail.rs"]
mod detail;
#[path = "session_queries/projection.rs"]
mod projection;

#[cfg(test)]
use crate::runtime::session_registry::SessionRegistry;

pub(crate) use conversation::{load_conversation_bootstrap, load_conversation_page};
#[cfg(test)]
pub(crate) use detail::hydrate_ephemeral_state;
pub(crate) use detail::{
  load_full_session_state, load_light_session_state, load_persisted_session_state,
};
pub(crate) use projection::{load_library_snapshot, SessionLoadError};

#[cfg(test)]
#[path = "session_queries_tests.rs"]
mod session_queries_tests;
