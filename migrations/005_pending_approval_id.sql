-- Add pending_approval_id to sessions so the request_id from the connector path
-- survives server restarts. Previously this lived only in-memory, so after a restart
-- clicking "Allow" would silently fail because the request_id was nil.
ALTER TABLE sessions ADD COLUMN pending_approval_id TEXT;
