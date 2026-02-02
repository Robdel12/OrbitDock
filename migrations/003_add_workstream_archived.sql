-- Migration 003: Add archived state to workstreams
-- Allows hiding workstreams without deleting or changing their stage

ALTER TABLE workstreams ADD COLUMN is_archived INTEGER DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_workstreams_archived ON workstreams(is_archived);
