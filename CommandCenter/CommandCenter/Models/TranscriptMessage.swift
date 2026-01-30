//
//  TranscriptMessage.swift
//  CommandCenter
//

import Foundation

struct TranscriptMessage: Identifiable, Hashable {
    let id: String
    let type: MessageType
    let content: String
    let timestamp: Date
    let toolName: String?
    let toolInput: [String: Any]?
    let inputTokens: Int?
    let outputTokens: Int?

    enum MessageType: String {
        case user
        case assistant
        case tool      // Tool call from assistant
        case toolResult // Result of tool call
        case system
    }

    var isUser: Bool { type == .user }
    var isAssistant: Bool { type == .assistant }
    var isTool: Bool { type == .tool }

    // Hashable conformance - exclude toolInput since [String: Any] isn't Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(type)
        hasher.combine(content)
        hasher.combine(timestamp)
        hasher.combine(toolName)
    }

    static func == (lhs: TranscriptMessage, rhs: TranscriptMessage) -> Bool {
        lhs.id == rhs.id
    }

    var preview: String {
        let cleaned = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 200 {
            return String(cleaned.prefix(200)) + "..."
        }
        return cleaned
    }

    // Helper for tool display
    var toolIcon: String {
        guard let tool = toolName?.lowercased() else { return "gearshape" }
        switch tool {
        case "read": return "doc.text"
        case "edit": return "pencil"
        case "write": return "square.and.pencil"
        case "bash": return "terminal"
        case "glob": return "folder.badge.gearshape"
        case "grep": return "magnifyingglass"
        case "task": return "person.2"
        case "webfetch": return "globe"
        case "websearch": return "magnifyingglass.circle"
        default: return "gearshape"
        }
    }

    var toolColor: String {
        guard let tool = toolName?.lowercased() else { return "secondary" }
        switch tool {
        case "read": return "blue"
        case "edit", "write": return "orange"
        case "bash": return "green"
        case "glob", "grep": return "purple"
        case "task": return "indigo"
        case "webfetch", "websearch": return "teal"
        default: return "secondary"
        }
    }

    // Extract file path from tool input if present
    var filePath: String? {
        guard let input = toolInput else { return nil }
        return input["file_path"] as? String ?? input["path"] as? String
    }

    // Extract command from Bash tool
    var bashCommand: String? {
        guard toolName?.lowercased() == "bash", let input = toolInput else { return nil }
        return input["command"] as? String
    }
}
