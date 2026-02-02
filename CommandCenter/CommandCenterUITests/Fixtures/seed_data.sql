-- Test fixture data for OrbitDock UI tests
-- Creates realistic sample data for visual testing

-- Repos
INSERT INTO repos (id, name, path, github_owner, github_name, created_at) VALUES
  ('repo-1', 'orbitdock', '/Users/test/Developer/orbitdock', 'testuser', 'orbitdock', datetime('now', '-30 days')),
  ('repo-2', 'vizzly-cli', '/Users/test/Developer/vizzly-cli', 'vizzly-testing', 'cli', datetime('now', '-20 days')),
  ('repo-3', 'webapp', '/Users/test/Developer/webapp', 'testuser', 'webapp', datetime('now', '-10 days'));

-- Active sessions (various states)
INSERT INTO sessions (id, project_path, project_name, branch, model, summary, first_prompt, transcript_path, status, work_status, attention_reason, started_at, last_activity_at, total_tokens, total_cost_usd, prompt_count, tool_count, provider) VALUES
  -- Working session (cyan indicator)
  ('session-1', '/Users/test/Developer/orbitdock', 'orbitdock', 'feat/visual-tests', 'claude-sonnet-4-20250514', 'Setting up Vizzly visual testing', 'Help me set up visual tests', '/tmp/test-transcript-1.jsonl', 'active', 'working', 'none', datetime('now', '-2 hours'), datetime('now', '-1 minute'), 45000, 0.15, 12, 45, 'claude'),

  -- Permission needed (coral indicator)
  ('session-2', '/Users/test/Developer/vizzly-cli', 'vizzly-cli', 'main', 'claude-sonnet-4-20250514', 'Refactoring CLI commands', 'Refactor the screenshot command', '/tmp/test-transcript-2.jsonl', 'active', 'permission', 'awaitingPermission', datetime('now', '-1 hour'), datetime('now', '-30 seconds'), 32000, 0.11, 8, 23, 'claude'),

  -- Question pending (purple indicator)
  ('session-3', '/Users/test/Developer/webapp', 'webapp', 'feat/dark-mode', 'claude-sonnet-4-20250514', 'Implementing dark mode theme', 'Add dark mode support', '/tmp/test-transcript-3.jsonl', 'active', 'waiting', 'awaitingQuestion', datetime('now', '-45 minutes'), datetime('now', '-2 minutes'), 28000, 0.09, 6, 18, 'claude'),

  -- Awaiting reply (blue indicator)
  ('session-4', '/Users/test/Developer/orbitdock', 'orbitdock', 'fix/menu-bar', 'claude-sonnet-4-20250514', 'Fixing menu bar layout issues', 'The menu bar icons are misaligned', '/tmp/test-transcript-4.jsonl', 'active', 'waiting', 'awaitingReply', datetime('now', '-30 minutes'), datetime('now', '-5 minutes'), 15000, 0.05, 4, 12, 'claude');

-- Ended sessions (for history)
INSERT INTO sessions (id, project_path, project_name, branch, model, summary, first_prompt, transcript_path, status, work_status, started_at, ended_at, end_reason, last_activity_at, total_tokens, total_cost_usd, prompt_count, tool_count, provider) VALUES
  ('session-5', '/Users/test/Developer/orbitdock', 'orbitdock', 'main', 'claude-sonnet-4-20250514', 'Initial project setup', 'Create the basic app structure', '/tmp/test-transcript-5.jsonl', 'ended', 'unknown', datetime('now', '-2 days'), datetime('now', '-2 days', '+3 hours'), 'manual', datetime('now', '-2 days', '+3 hours'), 85000, 0.28, 25, 120, 'claude'),
  ('session-6', '/Users/test/Developer/vizzly-cli', 'vizzly-cli', 'feat/swift-sdk', 'claude-opus-4-20250514', 'Building Swift SDK', 'Create a Swift package for Vizzly', '/tmp/test-transcript-6.jsonl', 'ended', 'unknown', datetime('now', '-1 day'), datetime('now', '-1 day', '+2 hours'), 'clear', datetime('now', '-1 day', '+2 hours'), 120000, 0.95, 35, 89, 'claude'),
  ('session-7', '/Users/test/Developer/webapp', 'webapp', 'main', 'claude-sonnet-4-20250514', 'Bug fixes and cleanup', 'Fix the login redirect bug', '/tmp/test-transcript-7.jsonl', 'ended', 'unknown', datetime('now', '-3 days'), datetime('now', '-3 days', '+1 hour'), 'manual', datetime('now', '-3 days', '+1 hour'), 22000, 0.07, 8, 32, 'claude');

-- Codex session
INSERT INTO sessions (id, project_path, project_name, branch, model, summary, first_prompt, transcript_path, status, work_status, started_at, last_activity_at, total_tokens, total_cost_usd, prompt_count, tool_count, provider) VALUES
  ('session-codex-1', '/Users/test/Developer/webapp', 'webapp', 'feat/api-v2', 'codex-1', 'API v2 endpoints', 'Create REST endpoints for v2', '/tmp/codex-transcript-1.jsonl', 'active', 'working', datetime('now', '-20 minutes'), datetime('now', '-1 minute'), 18000, 0.06, 3, 15, 'codex');

-- Quests
INSERT INTO quests (id, name, description, status, color, created_at, updated_at) VALUES
  ('quest-1', 'Visual Testing Integration', 'Set up Vizzly for screenshot testing across all views', 'active', '#00D4AA', datetime('now', '-5 days'), datetime('now', '-1 hour')),
  ('quest-2', 'Menu Bar Improvements', 'Polish the menu bar UI and add usage stats', 'active', '#7C3AED', datetime('now', '-3 days'), datetime('now', '-2 hours')),
  ('quest-3', 'Dark Mode Support', 'Implement system-aware dark mode throughout the app', 'active', '#F59E0B', datetime('now', '-7 days'), datetime('now', '-1 day')),
  ('quest-4', 'CLI Refactor', 'Modernize the CLI command structure', 'completed', '#10B981', datetime('now', '-14 days'), datetime('now', '-2 days'));

-- Quest-Session links
INSERT INTO quest_sessions (quest_id, session_id, linked_at) VALUES
  ('quest-1', 'session-1', datetime('now', '-2 hours')),
  ('quest-2', 'session-4', datetime('now', '-30 minutes')),
  ('quest-3', 'session-3', datetime('now', '-45 minutes')),
  ('quest-4', 'session-6', datetime('now', '-1 day'));

-- Inbox items
INSERT INTO inbox_items (id, content, source, session_id, quest_id, status, created_at) VALUES
  ('inbox-1', 'Add keyboard shortcuts for common actions', 'claude', 'session-1', NULL, 'pending', datetime('now', '-1 hour')),
  ('inbox-2', 'Consider adding a global hotkey to show/hide the app', 'manual', NULL, NULL, 'pending', datetime('now', '-2 hours')),
  ('inbox-3', 'The settings view needs better organization', 'claude', 'session-5', 'quest-2', 'attached', datetime('now', '-1 day')),
  ('inbox-4', 'Add export functionality for session transcripts', 'manual', NULL, NULL, 'pending', datetime('now', '-3 hours'));

-- Quest links
INSERT INTO quest_links (id, quest_id, source, url, title, external_id, detected_from, created_at) VALUES
  ('link-1', 'quest-1', 'github_pr', 'https://github.com/testuser/orbitdock/pull/42', 'feat: Add Vizzly visual testing', '42', 'manual', datetime('now', '-1 day')),
  ('link-2', 'quest-2', 'linear', 'https://linear.app/team/issue/ORB-123', 'ORB-123: Menu bar polish', 'ORB-123', 'manual', datetime('now', '-2 days')),
  ('link-3', 'quest-4', 'github_pr', 'https://github.com/vizzly-testing/cli/pull/15', 'refactor: Modernize CLI', '15', 'manual', datetime('now', '-3 days'));

-- Quest notes
INSERT INTO quest_notes (id, quest_id, title, content, created_at, updated_at) VALUES
  ('note-1', 'quest-1', 'Testing Strategy', 'Focus on key views first: Dashboard, Settings, Quick Switcher. Then add tool cards.', datetime('now', '-2 days'), datetime('now', '-1 day')),
  ('note-2', 'quest-2', NULL, 'Need to handle the case where usage data is unavailable', datetime('now', '-1 day'), datetime('now', '-1 day'));

-- Activities for session-1
INSERT INTO activities (session_id, timestamp, event_type, tool_name, file_path, summary, tokens_used) VALUES
  ('session-1', datetime('now', '-1 hour', '-50 minutes'), 'tool_use', 'Read', 'CommandCenter/CommandCenterUITests/CommandCenterUITests.swift', 'Read existing UI test file', 150),
  ('session-1', datetime('now', '-1 hour', '-45 minutes'), 'tool_use', 'Write', 'package.json', 'Created package.json with Vizzly CLI', 80),
  ('session-1', datetime('now', '-1 hour', '-40 minutes'), 'tool_use', 'Bash', NULL, 'npm install', 200),
  ('session-1', datetime('now', '-1 hour', '-30 minutes'), 'tool_use', 'Edit', 'CommandCenter/CommandCenterUITests/CommandCenterUITests.swift', 'Added Vizzly screenshot calls', 350),
  ('session-1', datetime('now', '-1 hour', '-20 minutes'), 'tool_use', 'Glob', NULL, 'Found view files', 100),
  ('session-1', datetime('now', '-1 minute'), 'tool_use', 'Edit', 'CommandCenter/CommandCenter/Database/DatabaseManager.swift', 'Added test database support', 450);
