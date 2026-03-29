-- Drop dead/redundant columns from messages table.
--
-- These columns were superseded by `row_data` (V022) and are no longer
-- read or written by any code path:
--
--   tool_output  (V001) — legacy tool results
--   tool_input   (V001) — legacy tool payloads
--   tool_name    (V001) — legacy tool name strings
--   tool_duration(V001) — legacy duration floats
--   content      (V001) — redundant extract of row_data content
--
-- Some columns (images_json, thinking) were added ad-hoc on existing installs
-- but never by a migration, so they may not exist on fresh databases.
-- We handle those conditionally in the migration runner.
--
-- Requires SQLite >= 3.35.0 (macOS ships 3.39+).

ALTER TABLE messages DROP COLUMN tool_output;
ALTER TABLE messages DROP COLUMN tool_input;
ALTER TABLE messages DROP COLUMN tool_name;
ALTER TABLE messages DROP COLUMN tool_duration;
ALTER TABLE messages DROP COLUMN content;
