-- Migration 008: Codex Direct Integration
-- Adds columns to support first-class Codex app-server integration

-- Integration mode distinguishes passive (FSEvents) from direct (JSON-RPC) sessions
ALTER TABLE sessions ADD COLUMN codex_integration_mode TEXT;

-- Thread ID for direct Codex sessions (maps to app-server thread)
ALTER TABLE sessions ADD COLUMN codex_thread_id TEXT;

-- Pending approval request ID for correlation when approving/rejecting
ALTER TABLE sessions ADD COLUMN pending_approval_id TEXT;

-- Index for looking up sessions by thread ID
CREATE INDEX IF NOT EXISTS idx_sessions_codex_thread_id ON sessions(codex_thread_id);
