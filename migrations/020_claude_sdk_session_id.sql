ALTER TABLE sessions ADD COLUMN claude_sdk_session_id TEXT;
CREATE INDEX IF NOT EXISTS idx_sessions_claude_sdk_session_id ON sessions(claude_sdk_session_id);
