import Foundation

// MARK: - Session Inputs

public struct SessionStartInput: Codable {
    public let session_id: String
    public let cwd: String
    public let model: String?
    public let source: String?
    public let context_label: String?
    public let transcript_path: String?

    public init(
        session_id: String,
        cwd: String,
        model: String? = nil,
        source: String? = nil,
        context_label: String? = nil,
        transcript_path: String? = nil
    ) {
        self.session_id = session_id
        self.cwd = cwd
        self.model = model
        self.source = source
        self.context_label = context_label
        self.transcript_path = transcript_path
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

    public init(
        session_id: String,
        cwd: String,
        transcript_path: String? = nil,
        hook_event_name: String,
        notification_type: String? = nil,
        tool_name: String? = nil
    ) {
        self.session_id = session_id
        self.cwd = cwd
        self.transcript_path = transcript_path
        self.hook_event_name = hook_event_name
        self.notification_type = notification_type
        self.tool_name = tool_name
    }
}

// MARK: - Tool Tracker Input

public struct ToolTrackerInput: Codable {
    public let session_id: String
    public let cwd: String
    public let hook_event_name: String
    public let tool_name: String
    public let tool_input: ToolInput?
    public let tool_use_id: String?
    public let error: String?
    public let is_interrupt: Bool?

    public init(
        session_id: String,
        cwd: String,
        hook_event_name: String,
        tool_name: String,
        tool_input: ToolInput? = nil,
        tool_use_id: String? = nil,
        error: String? = nil,
        is_interrupt: Bool? = nil
    ) {
        self.session_id = session_id
        self.cwd = cwd
        self.hook_event_name = hook_event_name
        self.tool_name = tool_name
        self.tool_input = tool_input
        self.tool_use_id = tool_use_id
        self.error = error
        self.is_interrupt = is_interrupt
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
