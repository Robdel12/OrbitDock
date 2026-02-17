-- Add token usage columns to turn_diffs for per-turn token tracking
ALTER TABLE turn_diffs ADD COLUMN input_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE turn_diffs ADD COLUMN output_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE turn_diffs ADD COLUMN cached_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE turn_diffs ADD COLUMN context_window INTEGER NOT NULL DEFAULT 0;
