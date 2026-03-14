CREATE TABLE IF NOT EXISTS rollout_checkpoints (
  path TEXT PRIMARY KEY,
  offset INTEGER NOT NULL,
  session_id TEXT,
  project_path TEXT,
  model_provider TEXT,
  ignore_existing INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rollout_checkpoints_updated_at
ON rollout_checkpoints(updated_at);
