import SwiftUI

enum QuickSwitcherRowPresentation {
  nonisolated static func displayPath(_ path: String) -> String {
    if path.hasPrefix("/Users/") {
      let parts = path.split(separator: "/", maxSplits: 3)
      if parts.count >= 2 {
        return "~/" + (parts.count > 2 ? String(parts[2...].joined(separator: "/")) : "")
      }
    }
    return path.isEmpty ? "~" : path
  }

  nonisolated static func projectName(for session: Session) -> String {
    session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
  }

  nonisolated static func activityText(for session: Session, status: SessionDisplayStatus) -> String {
    switch status {
      case .permission:
        session.pendingToolName ?? "Permission"
      case .question:
        "Question"
      case .working:
        session.lastTool ?? "Working"
      case .reply:
        "Ready"
      case .ended:
        "Ended"
    }
  }

  @MainActor
  static func activityIcon(for session: Session, status: SessionDisplayStatus) -> String {
    switch status {
      case .permission:
        return "lock.fill"
      case .question:
        return "questionmark.bubble"
      case .working:
        if let tool = session.lastTool {
          return ToolCardStyle.icon(for: tool)
        }
        return "bolt.fill"
      case .reply:
        return "checkmark.circle"
      case .ended:
        return "moon.fill"
    }
  }
}
