//! Panic payload utilities for connector error recovery.

use std::any::Any;

/// Extract a human-readable message from a panic payload.
///
/// Panics in Rust can carry either a `&'static str` or `String` message.
/// This helper handles both cases and returns a fallback for other types.
pub fn panic_payload_message(payload: &(dyn Any + Send)) -> String {
  if let Some(message) = payload.downcast_ref::<&'static str>() {
    return (*message).to_string();
  }

  if let Some(message) = payload.downcast_ref::<String>() {
    return message.clone();
  }

  "non-string panic payload".to_string()
}
