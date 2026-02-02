import Foundation
import SQLite

// MARK: - Session Operations

extension CLIDatabase {

    /// Upsert a session (create or update)
    public func upsertSession(
        id sessionId: String,
        projectPath path: String,
        projectName name: String?,
        branch branchName: String?,
        model modelName: String?,
        contextLabel label: String?,
        transcriptPath transcript: String?,
        status sessionStatus: String,
        workStatus work: String,
        startedAt started: String?,
        terminalSessionId terminalId: String?,
        terminalApp terminal: String?
    ) throws {
        let now = Self.formatDate()

        try connection.run("""
            INSERT INTO sessions (
                id, project_path, project_name, branch, model, context_label,
                transcript_path, status, work_status, started_at, last_activity_at,
                terminal_session_id, terminal_app, provider
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'claude')
            ON CONFLICT(id) DO UPDATE SET
                project_path = excluded.project_path,
                project_name = excluded.project_name,
                branch = excluded.branch,
                model = excluded.model,
                context_label = excluded.context_label,
                transcript_path = excluded.transcript_path,
                status = excluded.status,
                work_status = excluded.work_status,
                last_activity_at = excluded.last_activity_at,
                terminal_session_id = COALESCE(excluded.terminal_session_id, terminal_session_id),
                terminal_app = COALESCE(excluded.terminal_app, terminal_app)
            """,
            sessionId, path, name, branchName, modelName, label,
            transcript, sessionStatus, work, started ?? now, now,
            terminalId, terminal
        )
    }

    /// Update specific session fields
    public func updateSession(
        id sessionId: String,
        workStatus: String? = nil,
        attentionReason: String? = nil,
        lastTool: String? = nil,
        lastToolAt: String? = nil,
        pendingToolName: String? = nil,
        pendingToolInput: String? = nil,
        pendingQuestion: String? = nil,
        branch: String? = nil,
        source: String? = nil,
        agentType: String? = nil,
        permissionMode: String? = nil,
        activeSubagentId: String? = nil,
        activeSubagentType: String? = nil,
        firstPrompt: String? = nil,
        workstreamId: String? = nil
    ) throws {
        var updates: [String] = ["last_activity_at = ?"]
        var values: [Binding?] = [Self.formatDate()]

        if let ws = workStatus {
            updates.append("work_status = ?")
            values.append(ws)
        }
        if let ar = attentionReason {
            updates.append("attention_reason = ?")
            values.append(ar)
        }
        if let lt = lastTool {
            updates.append("last_tool = ?")
            values.append(lt)
        }
        if let lta = lastToolAt {
            updates.append("last_tool_at = ?")
            values.append(lta)
        }
        if let ptn = pendingToolName {
            updates.append("pending_tool_name = ?")
            values.append(ptn)
        } else if pendingToolName == nil && workStatus == "working" {
            // Clear pending tool when starting to work
        }
        if let pti = pendingToolInput {
            updates.append("pending_tool_input = ?")
            values.append(pti)
        }
        if let pq = pendingQuestion {
            updates.append("pending_question = ?")
            values.append(pq)
        }
        if let br = branch {
            updates.append("branch = ?")
            values.append(br)
        }
        if let src = source {
            updates.append("source = ?")
            values.append(src)
        }
        if let at = agentType {
            updates.append("agent_type = ?")
            values.append(at)
        }
        if let pm = permissionMode {
            updates.append("permission_mode = ?")
            values.append(pm)
        }
        if let asid = activeSubagentId {
            updates.append("active_subagent_id = ?")
            values.append(asid)
        }
        if let ast = activeSubagentType {
            updates.append("active_subagent_type = ?")
            values.append(ast)
        }
        if let fp = firstPrompt {
            updates.append("first_prompt = COALESCE(first_prompt, ?)")
            values.append(fp)
        }
        if let wsid = workstreamId {
            updates.append("workstream_id = ?")
            values.append(wsid)
        }

        values.append(sessionId)

        let sql = "UPDATE sessions SET \(updates.joined(separator: ", ")) WHERE id = ?"
        try connection.run(sql, values)
    }

    /// Clear active subagent
    public func clearActiveSubagent(id sessionId: String) throws {
        try connection.run("""
            UPDATE sessions SET
                active_subagent_id = NULL,
                active_subagent_type = NULL,
                last_activity_at = ?
            WHERE id = ?
            """,
            Self.formatDate(), sessionId
        )
    }

    /// Increment compact count
    public func incrementCompactCount(id sessionId: String) throws {
        try connection.run("""
            UPDATE sessions SET
                compact_count = COALESCE(compact_count, 0) + 1,
                last_activity_at = ?
            WHERE id = ?
            """,
            Self.formatDate(), sessionId
        )
    }

    /// Clear pending tool/question fields
    public func clearPendingFields(id sessionId: String) throws {
        try connection.run("""
            UPDATE sessions SET
                pending_tool_name = NULL,
                pending_tool_input = NULL,
                pending_question = NULL,
                last_activity_at = ?
            WHERE id = ?
            """,
            Self.formatDate(), sessionId
        )
    }

    /// End a session
    public func endSession(id sessionId: String, reason: String?) throws {
        let now = Self.formatDate()
        try connection.run("""
            UPDATE sessions SET
                status = 'ended',
                ended_at = ?,
                end_reason = ?,
                work_status = 'unknown',
                attention_reason = 'none',
                pending_tool_name = NULL,
                pending_tool_input = NULL,
                pending_question = NULL
            WHERE id = ?
            """,
            now, reason, sessionId
        )
    }

    /// Increment prompt count
    public func incrementPromptCount(id sessionId: String) throws {
        try connection.run("""
            UPDATE sessions SET
                prompt_count = COALESCE(prompt_count, 0) + 1,
                last_activity_at = ?
            WHERE id = ?
            """,
            Self.formatDate(), sessionId
        )
    }

    /// Increment tool count
    public func incrementToolCount(id sessionId: String) throws {
        try connection.run("""
            UPDATE sessions SET
                tool_count = COALESCE(tool_count, 0) + 1,
                last_activity_at = ?
            WHERE id = ?
            """,
            Self.formatDate(), sessionId
        )
    }

    /// Get session by ID
    public func getSession(id sessionId: String) -> SessionRow? {
        let query = Self.sessions.filter(Self.id == sessionId)
        guard let row = try? connection.pluck(query) else { return nil }

        return SessionRow(
            id: row[Self.id],
            lastTool: row[Self.lastTool],
            workStatus: row[Self.workStatus]
        )
    }

    /// Clean up stale sessions from the same terminal
    /// A terminal can only run one Claude session at a time
    public func cleanupStaleSessions(terminalId: String, currentSessionId: String) throws -> Int {
        let now = Self.formatDate()
        _ = try connection.run("""
            UPDATE sessions SET
                status = 'ended',
                ended_at = ?,
                end_reason = 'stale'
            WHERE terminal_session_id = ?
                AND status = 'active'
                AND id != ?
            """,
            now, terminalId, currentSessionId
        )
        return connection.changes
    }
}

// MARK: - Session Row (minimal read model)

public struct SessionRow {
    public let id: String
    public let lastTool: String?
    public let workStatus: String?
}

// MARK: - Subagent Operations

extension CLIDatabase {

    /// Create a subagent record when SubagentStart fires
    public func createSubagent(
        id agentId: String,
        sessionId: String,
        agentType: String
    ) throws {
        let now = Self.formatDate()
        try connection.run("""
            INSERT INTO subagents (id, session_id, agent_type, started_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                agent_type = excluded.agent_type,
                started_at = excluded.started_at
            """,
            agentId, sessionId, agentType, now
        )
    }

    /// End a subagent when SubagentStop fires
    public func endSubagent(
        id agentId: String,
        transcriptPath: String?
    ) throws {
        let now = Self.formatDate()
        try connection.run("""
            UPDATE subagents SET
                ended_at = ?,
                transcript_path = ?
            WHERE id = ?
            """,
            now, transcriptPath, agentId
        )
    }
}

// MARK: - Compaction Operations

extension CLIDatabase {

    /// Record a context compaction event
    public func recordCompaction(
        sessionId: String,
        trigger: String,
        customInstructions: String?
    ) throws {
        let now = Self.formatDate()
        try connection.run("""
            INSERT INTO compactions (session_id, trigger, custom_instructions, compacted_at)
            VALUES (?, ?, ?, ?)
            """,
            sessionId, trigger, customInstructions, now
        )
    }
}
