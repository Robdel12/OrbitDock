//
//  ToolCardStyle.swift
//  CommandCenter
//
//  Shared styling and helpers for tool cards
//

import SwiftUI

// MARK: - Tool Card Colors

enum ToolCardStyle {
    static func color(for toolName: String?) -> Color {
        guard let tool = toolName?.lowercased() else { return .secondary }

        switch tool {
        case "read":
            return Color(red: 0.4, green: 0.6, blue: 1.0)      // Soft blue
        case "edit", "write", "notebookedit":
            return Color(red: 1.0, green: 0.55, blue: 0.25)    // Warm orange
        case "bash":
            return Color(red: 0.35, green: 0.8, blue: 0.5)     // Soft green
        case "glob", "grep":
            return Color(red: 0.65, green: 0.45, blue: 0.9)    // Purple
        case "task":
            return Color(red: 0.45, green: 0.45, blue: 0.95)   // Indigo
        case "webfetch", "websearch":
            return Color(red: 0.3, green: 0.75, blue: 0.75)    // Teal
        default:
            return .secondary
        }
    }

    static func icon(for toolName: String?) -> String {
        guard let tool = toolName?.lowercased() else { return "gearshape" }

        switch tool {
        case "read": return "doc.text.fill"
        case "edit": return "pencil"
        case "write": return "square.and.pencil"
        case "bash": return "terminal"
        case "glob": return "folder.badge.gearshape"
        case "grep": return "magnifyingglass"
        case "task": return "person.2.fill"
        case "webfetch": return "globe"
        case "websearch": return "magnifyingglass.circle"
        default: return "gearshape"
        }
    }

    // Detect language from file extension
    static func detectLanguage(from path: String?) -> String {
        guard let path = path else { return "" }
        let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""

        switch ext {
        case "swift": return "swift"
        case "ts", "tsx": return "typescript"
        case "js", "jsx": return "javascript"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt": return "kotlin"
        case "css", "scss": return "css"
        case "html": return "html"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "md": return "markdown"
        case "sh", "bash", "zsh": return "bash"
        case "sql": return "sql"
        default: return ""
        }
    }

    // Shorten path for display
    static func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return path
    }
}
