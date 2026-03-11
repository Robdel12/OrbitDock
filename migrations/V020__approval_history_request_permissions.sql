ALTER TABLE approval_history ADD COLUMN permission_reason TEXT;
ALTER TABLE approval_history ADD COLUMN requested_permissions TEXT;
ALTER TABLE approval_history ADD COLUMN granted_permissions TEXT;
