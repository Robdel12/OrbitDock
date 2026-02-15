-- Add environment tracking columns for cwd, git branch, and git sha
ALTER TABLE sessions ADD COLUMN current_cwd TEXT;
ALTER TABLE sessions ADD COLUMN git_branch TEXT;
ALTER TABLE sessions ADD COLUMN git_sha TEXT;
