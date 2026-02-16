-- Add claude_integration_mode column to track direct vs passive Claude sessions
ALTER TABLE sessions ADD COLUMN claude_integration_mode TEXT;
