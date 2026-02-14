-- Review comments for the agent workbench review canvas
CREATE TABLE IF NOT EXISTS review_comments (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    turn_id TEXT,
    file_path TEXT NOT NULL,
    line_start INTEGER NOT NULL,
    line_end INTEGER,
    body TEXT NOT NULL,
    tag TEXT,
    status TEXT NOT NULL DEFAULT 'open',
    created_at TEXT NOT NULL,
    updated_at TEXT,
    FOREIGN KEY (session_id) REFERENCES sessions(id)
);

CREATE INDEX IF NOT EXISTS idx_review_comments_session ON review_comments(session_id);
CREATE INDEX IF NOT EXISTS idx_review_comments_session_turn ON review_comments(session_id, turn_id);
