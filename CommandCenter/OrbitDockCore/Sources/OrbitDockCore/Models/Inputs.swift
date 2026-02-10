import Foundation

// MARK: - Session Inputs

public struct SessionStartInput: Codable {
    public let session_id: String
    public let cwd: String
    public let model: String?
    public let source: String?               // 'startup', 'resume', 'clear', 'compact'
    public let context_label: String?
    public let transcript_path: String?
    public let permission_mode: String?      // 'default', 'plan', 'acceptEdits', 'dontAsk', 'bypassPermissions'
    public let agent_type: String?           // If started with --agent flag

    public init(
        session_id: String,
        cwd: String,
        model: String? = nil,
        source: String? = nil,
        context_label: String? = nil,
        transcript_path: String? = nil,
        permission_mode: String? = nil,
        agent_type: String? = nil
    ) {
        self.session_id = session_id
        self.cwd = cwd
        self.model = model
        self.source = source
        self.context_label = context_label
        self.transcript_path = transcript_path
        self.permission_mode = permission_mode
        self.agent_type = agent_type
    }
}

extension SessionStartInput {
    /// Detect Codex rollout/session-start payloads so Claude hooks don't clobber Codex rows.
    public var isCodexRolloutPayload: Bool {
        if context_label == "codex_cli_rs" {
            return true
        }
        if let path = transcript_path?.lowercased(), path.contains("/.codex/sessions/") {
            return true
        }
        if let model = model?.lowercased(), model.contains("codex") || model.hasPrefix("gpt-") {
            return true
        }
        return false
    }
}

public struct SessionEndInput: Codable {
    public let session_id: String
    public let cwd: String
    public let reason: String?

    public init(session_id: String, cwd: String, reason: String? = nil) {
        self.session_id = session_id
        self.cwd = cwd
        self.reason = reason
    }
}

// MARK: - Status Tracker Input

public struct StatusTrackerInput: Codable {
    public let session_id: String
    public let cwd: String
    public let transcript_path: String?
    public let hook_event_name: String
    public let notification_type: String?
    public let tool_name: String?
    public let stop_hook_active: Bool?       // True if in stop hook loop
    public let prompt: String?               // User's prompt (UserPromptSubmit)
    public let message: String?              // Notification message
    public let title: String?                // Notification title
    public let trigger: String?              // PreCompact: 'manual' or 'auto'
    public let custom_instructions: String?  // PreCompact: user's /compact instructions

    public init(
        session_id: String,
        cwd: String,
        transcript_path: String? = nil,
        hook_event_name: String,
        notification_type: String? = nil,
        tool_name: String? = nil,
        stop_hook_active: Bool? = nil,
        prompt: String? = nil,
        message: String? = nil,
        title: String? = nil,
        trigger: String? = nil,
        custom_instructions: String? = nil
    ) {
        self.session_id = session_id
        self.cwd = cwd
        self.transcript_path = transcript_path
        self.hook_event_name = hook_event_name
        self.notification_type = notification_type
        self.tool_name = tool_name
        self.stop_hook_active = stop_hook_active
        self.prompt = prompt
        self.message = message
        self.title = title
        self.trigger = trigger
        self.custom_instructions = custom_instructions
    }
}

// MARK: - Tool Tracker Input

public struct ToolTrackerInput: Codable {
    public let session_id: String
    public let cwd: String
    public let hook_event_name: String
    public let tool_name: String
    public let tool_input: ToolInput?
    public let tool_response: ToolResponse?  // PostToolUse: tool output
    public let tool_use_id: String?
    public let error: String?
    public let is_interrupt: Bool?

    public init(
        session_id: String,
        cwd: String,
        hook_event_name: String,
        tool_name: String,
        tool_input: ToolInput? = nil,
        tool_response: ToolResponse? = nil,
        tool_use_id: String? = nil,
        error: String? = nil,
        is_interrupt: Bool? = nil
    ) {
        self.session_id = session_id
        self.cwd = cwd
        self.hook_event_name = hook_event_name
        self.tool_name = tool_name
        self.tool_input = tool_input
        self.tool_response = tool_response
        self.tool_use_id = tool_use_id
        self.error = error
        self.is_interrupt = is_interrupt
    }
}

/// Tool response from PostToolUse - captures stdout/stderr for Bash
public struct ToolResponse: Codable {
    public let stdout: String?
    public let stderr: String?
    public let exitCode: Int?

    // Allow other fields to pass through (different tools have different responses)
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(stdout: String? = nil, stderr: String? = nil, exitCode: Int? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        self.stdout = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "stdout")!)
        self.stderr = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "stderr")!)
        self.exitCode = try container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "exitCode")!)
    }
}

public struct ToolInput: Codable {
    public let command: String?
    public let question: String?

    // Allow other fields to pass through
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(command: String? = nil, question: String? = nil) {
        self.command = command
        self.question = question
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        self.command = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "command")!)
        self.question = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "question")!)
    }
}

// MARK: - Enums

public enum WorkStatus: String, Codable {
    case working
    case waiting
    case permission
    case unknown
}

public enum AttentionReason: String, Codable {
    case none
    case awaitingReply
    case awaitingPermission
    case awaitingQuestion
}

public enum SessionStatus: String, Codable {
    case active
    case idle
    case ended
}

// MARK: - Subagent Tracker Input

public struct SubagentInput: Codable {
    public let session_id: String
    public let cwd: String
    public let transcript_path: String?
    public let hook_event_name: String           // 'SubagentStart' or 'SubagentStop'
    public let agent_id: String                  // Unique subagent identifier
    public let agent_type: String?               // 'Bash', 'Explore', 'Plan', custom names (optional for compat)
    public let agent_transcript_path: String?    // Subagent's transcript (SubagentStop only)
    public let stop_hook_active: Bool?           // True if in stop hook loop (SubagentStop only)

    public init(
        session_id: String,
        cwd: String,
        transcript_path: String? = nil,
        hook_event_name: String,
        agent_id: String,
        agent_type: String? = nil,
        agent_transcript_path: String? = nil,
        stop_hook_active: Bool? = nil
    ) {
        self.session_id = session_id
        self.cwd = cwd
        self.transcript_path = transcript_path
        self.hook_event_name = hook_event_name
        self.agent_id = agent_id
        self.agent_type = agent_type
        self.agent_transcript_path = agent_transcript_path
        self.stop_hook_active = stop_hook_active
    }
}

// MARK: - Permission Request Input (richer than Notification:permission_prompt)

public struct PermissionRequestInput: Codable {
    public let session_id: String
    public let cwd: String
    public let transcript_path: String?
    public let hook_event_name: String
    public let tool_name: String
    public let tool_input: ToolInput?
    public let permission_suggestions: [PermissionSuggestion]?

    public init(
        session_id: String,
        cwd: String,
        transcript_path: String? = nil,
        hook_event_name: String = "PermissionRequest",
        tool_name: String,
        tool_input: ToolInput? = nil,
        permission_suggestions: [PermissionSuggestion]? = nil
    ) {
        self.session_id = session_id
        self.cwd = cwd
        self.transcript_path = transcript_path
        self.hook_event_name = hook_event_name
        self.tool_name = tool_name
        self.tool_input = tool_input
        self.permission_suggestions = permission_suggestions
    }
}

public struct PermissionSuggestion: Codable {
    public let type: String      // e.g., 'toolAlwaysAllow'
    public let tool: String?

    public init(type: String, tool: String? = nil) {
        self.type = type
        self.tool = tool
    }
}
