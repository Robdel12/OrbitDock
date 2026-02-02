-- Inbox item status tracking
-- Adds status field and Linear integration

ALTER TABLE inbox_items ADD COLUMN status TEXT DEFAULT 'pending';
-- 'pending' = in inbox, needs processing
-- 'attached' = linked to a quest
-- 'converted' = turned into Linear issue
-- 'completed' = done/handled
-- 'archived' = saved for later / not now

ALTER TABLE inbox_items ADD COLUMN linear_issue_id TEXT;
ALTER TABLE inbox_items ADD COLUMN linear_issue_url TEXT;
ALTER TABLE inbox_items ADD COLUMN completed_at TEXT;

-- Index for filtering by status
CREATE INDEX IF NOT EXISTS idx_inbox_status ON inbox_items(status);
