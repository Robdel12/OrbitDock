-- Migration 011: Session Autonomy Config
-- Stores approval_policy and sandbox_mode so restored sessions use correct settings

-- Approval policy: untrusted, on-failure, on-request, never
ALTER TABLE sessions ADD COLUMN approval_policy TEXT;

-- Sandbox mode: read-only, workspace-write, danger-full-access
ALTER TABLE sessions ADD COLUMN sandbox_mode TEXT;
