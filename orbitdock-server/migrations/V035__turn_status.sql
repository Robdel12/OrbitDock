-- Add turn_status to track undo/rollback lifecycle on conversation rows.
ALTER TABLE messages ADD COLUMN turn_status TEXT NOT NULL DEFAULT 'active';
