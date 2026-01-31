//
//  Activity.swift
//  OrbitDock
//

import Foundation

struct Activity: Identifiable {
    let id: Int
    let sessionId: String
    let timestamp: Date
    let eventType: String?
    let toolName: String?
    let filePath: String?
    let summary: String?
    let tokensUsed: Int?
    let costUSD: Double?

    var displaySummary: String {
        if let summary = summary, !summary.isEmpty {
            return summary
        }
        if let tool = toolName {
            if let file = filePath {
                return "\(tool): \(file.components(separatedBy: "/").last ?? file)"
            }
            return tool
        }
        return eventType ?? "Activity"
    }

    var icon: String {
        switch toolName?.lowercased() {
        case "edit": return "pencil"
        case "write": return "doc.badge.plus"
        case "read": return "doc.text"
        case "bash": return "terminal"
        case "glob": return "magnifyingglass"
        case "grep": return "text.magnifyingglass"
        default: return "circle.fill"
        }
    }
}
