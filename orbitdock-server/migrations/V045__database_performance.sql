-- Performance indexes and cleanup for dashboard, mission, and query planner.

-- 1. Dashboard sort: covers WHERE status = 'active' + ORDER BY timestamps.
--    Enables index-only scan for the hot dashboard query path.
CREATE INDEX IF NOT EXISTS idx_sessions_active_sort
  ON sessions(status, last_progress_at DESC, last_activity_at DESC);

-- 2. Mission issues: enable indexed lookups by mission_id (was full-scan).
CREATE INDEX IF NOT EXISTS idx_mission_issues_mission_id
  ON mission_issues(mission_id);

-- 3. Mission issues: cover the orchestration state filter used by the scheduler.
CREATE INDEX IF NOT EXISTS idx_mission_issues_orchestration
  ON mission_issues(mission_id, orchestration_state);

-- 4. Sessions: indexed lookup by mission_id for mission control joins.
CREATE INDEX IF NOT EXISTS idx_sessions_mission_id
  ON sessions(mission_id);

-- 5. Drop duplicate legacy indexes on messages that slow inserts and waste space.
--    idx_messages_session (session_id) already covers single-column lookups.
--    idx_messages_session_seq (session_id, sequence) already covers compound lookups.
DROP INDEX IF EXISTS index_messages_on_session_id;
DROP INDEX IF EXISTS index_messages_on_session_id_timestamp;

-- 6. Gather query planner statistics so SQLite can make informed index choices.
--    This has never been run on this database — the planner has been guessing.
ANALYZE;
