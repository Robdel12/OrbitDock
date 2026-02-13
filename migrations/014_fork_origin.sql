-- Track fork origin for forked sessions
ALTER TABLE sessions ADD COLUMN forked_from_session_id TEXT;
