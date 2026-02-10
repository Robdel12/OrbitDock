-- Migration 013: Guard against direct-thread shadow rows from legacy writers.
-- Prevent non-codex rows whose session id is a direct codex thread id,
-- and normalize codex_cli_rs passive rows to codex/passive identity.

CREATE TRIGGER IF NOT EXISTS trg_sessions_block_direct_thread_shadow_insert
BEFORE INSERT ON sessions
WHEN EXISTS (
  SELECT 1
  FROM sessions direct
  WHERE direct.codex_integration_mode = 'direct'
    AND direct.codex_thread_id = NEW.id
)
AND COALESCE(NEW.provider, 'claude') != 'codex'
BEGIN
  SELECT RAISE(IGNORE);
END;

CREATE TRIGGER IF NOT EXISTS trg_sessions_block_direct_thread_shadow_update
BEFORE UPDATE ON sessions
WHEN EXISTS (
  SELECT 1
  FROM sessions direct
  WHERE direct.codex_integration_mode = 'direct'
    AND direct.codex_thread_id = NEW.id
)
AND COALESCE(NEW.provider, 'claude') != 'codex'
BEGIN
  SELECT RAISE(IGNORE);
END;

CREATE TRIGGER IF NOT EXISTS trg_sessions_normalize_codex_cli_rs_insert
AFTER INSERT ON sessions
WHEN NEW.context_label = 'codex_cli_rs'
BEGIN
  UPDATE sessions
  SET provider = 'codex',
      codex_integration_mode = COALESCE(codex_integration_mode, 'passive'),
      codex_thread_id = COALESCE(codex_thread_id, id)
  WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_sessions_normalize_codex_cli_rs_update
AFTER UPDATE ON sessions
WHEN NEW.context_label = 'codex_cli_rs'
BEGIN
  UPDATE sessions
  SET provider = 'codex',
      codex_integration_mode = COALESCE(codex_integration_mode, 'passive'),
      codex_thread_id = COALESCE(codex_thread_id, id)
  WHERE id = NEW.id;
END;
