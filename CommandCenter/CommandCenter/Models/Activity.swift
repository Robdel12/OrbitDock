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
    if let summary, !summary.isEmpty {
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
      case "edit": "pencil"
      case "write": "doc.badge.plus"
      case "read": "doc.text"
      case "bash": "terminal"
      case "glob": "magnifyingglass"
      case "grep": "text.magnifyingglass"
      default: "circle.fill"
    }
  }
}
