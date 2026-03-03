-- Secure auth token storage (hashed, non-recoverable secrets)
CREATE TABLE IF NOT EXISTS auth_tokens (
    id TEXT PRIMARY KEY,
    token_hash BLOB NOT NULL,
    token_salt BLOB NOT NULL,
    label TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    last_used_at TEXT,
    expires_at TEXT,
    revoked_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_auth_tokens_active
ON auth_tokens (revoked_at, expires_at, created_at);
