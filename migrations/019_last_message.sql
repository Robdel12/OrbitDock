-- Add last_message to sessions for dashboard context line display.
-- Stores the most recent user or assistant message content (truncated).
ALTER TABLE sessions ADD COLUMN last_message TEXT;
