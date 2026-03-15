-- MCP elicitation support
ALTER TABLE approval_history ADD COLUMN elicitation_mode TEXT;
ALTER TABLE approval_history ADD COLUMN elicitation_schema TEXT;
ALTER TABLE approval_history ADD COLUMN elicitation_url TEXT;
ALTER TABLE approval_history ADD COLUMN elicitation_message TEXT;
ALTER TABLE approval_history ADD COLUMN mcp_server_name TEXT;

-- Network approval context
ALTER TABLE approval_history ADD COLUMN network_host TEXT;
ALTER TABLE approval_history ADD COLUMN network_protocol TEXT;
