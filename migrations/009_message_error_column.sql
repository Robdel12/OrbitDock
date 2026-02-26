-- Add explicit error flag for messages.
-- Existing `is_in_progress` is reserved for live tool/shell progress state.
ALTER TABLE messages ADD COLUMN is_error INTEGER NOT NULL DEFAULT 0;
