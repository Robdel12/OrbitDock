-- Migration 009: Codex Token Usage Tracking
-- Adds columns to track real-time token usage for Codex sessions

-- Input tokens used in the session
ALTER TABLE sessions ADD COLUMN codex_input_tokens INTEGER;

-- Output tokens generated in the session
ALTER TABLE sessions ADD COLUMN codex_output_tokens INTEGER;

-- Cached input tokens (for cost savings display)
ALTER TABLE sessions ADD COLUMN codex_cached_tokens INTEGER;

-- Model context window size (for percentage calculation)
ALTER TABLE sessions ADD COLUMN codex_context_window INTEGER;
