-- Mission-scoped tracker credentials.
-- Each mission can own its own encrypted API key instead of relying
-- on the shared global config table or environment variables.
ALTER TABLE missions ADD COLUMN tracker_api_key TEXT;
