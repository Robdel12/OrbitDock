-- Add row_data column to messages table for typed ConversationRow JSON storage.
-- The existing flat columns (type, content, tool_name, etc.) remain for backwards
-- compatibility and index-based queries. The row_data column is authoritative
-- when present.

ALTER TABLE messages ADD COLUMN row_data TEXT;
