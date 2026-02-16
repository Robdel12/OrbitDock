-- Rename Codex-specific token columns to provider-agnostic names
-- These columns are used by both Codex and Claude direct sessions
ALTER TABLE sessions RENAME COLUMN codex_input_tokens TO input_tokens;
ALTER TABLE sessions RENAME COLUMN codex_output_tokens TO output_tokens;
ALTER TABLE sessions RENAME COLUMN codex_cached_tokens TO cached_tokens;
ALTER TABLE sessions RENAME COLUMN codex_context_window TO context_window;
