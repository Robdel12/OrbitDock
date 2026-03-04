-- Unread message tracking: global read watermark per session
ALTER TABLE sessions ADD COLUMN last_read_sequence INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sessions ADD COLUMN unread_count INTEGER NOT NULL DEFAULT 0;

-- Backfill: mark all existing sessions as fully read
UPDATE sessions
SET last_read_sequence = COALESCE(
    (SELECT MAX(sequence) FROM messages WHERE messages.session_id = sessions.id),
    0
),
unread_count = 0;
