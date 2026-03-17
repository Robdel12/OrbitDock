-- Allow custom MISSION.md file path per mission.
-- Defaults to NULL which means "MISSION.md" in repo_root.
ALTER TABLE missions ADD COLUMN mission_file_path TEXT;
