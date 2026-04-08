-- Enforce immutability of provider session IDs.
-- Once set, claude_sdk_session_id and codex_thread_id cannot be changed.
-- This prevents hook sessions from overwriting real session IDs.

CREATE TRIGGER prevent_sdk_session_id_overwrite
BEFORE UPDATE OF claude_sdk_session_id ON sessions
WHEN OLD.claude_sdk_session_id IS NOT NULL
  AND NEW.claude_sdk_session_id IS NOT NULL
  AND OLD.claude_sdk_session_id != NEW.claude_sdk_session_id
BEGIN
  SELECT RAISE(ABORT, 'claude_sdk_session_id is immutable once set');
END;

CREATE TRIGGER prevent_thread_id_overwrite
BEFORE UPDATE OF codex_thread_id ON sessions
WHEN OLD.codex_thread_id IS NOT NULL
  AND NEW.codex_thread_id IS NOT NULL
  AND OLD.codex_thread_id != NEW.codex_thread_id
BEGIN
  SELECT RAISE(ABORT, 'codex_thread_id is immutable once set');
END;
