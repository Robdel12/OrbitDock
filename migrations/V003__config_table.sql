-- Key-value config table for server settings (API keys, preferences, etc.)
CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
