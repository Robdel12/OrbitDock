-- Add required name column to missions (default to repo folder name for existing rows)
ALTER TABLE missions ADD COLUMN name TEXT NOT NULL DEFAULT '';

-- Backfill existing missions: use the last path segment of repo_root as the name
UPDATE missions SET name = REPLACE(repo_root, RTRIM(repo_root, REPLACE(repo_root, '/', '')), '');
