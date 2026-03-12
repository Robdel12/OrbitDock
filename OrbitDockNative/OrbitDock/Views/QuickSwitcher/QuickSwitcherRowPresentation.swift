import SwiftUI

enum QuickSwitcherRowPresentation {
  static func displayPath(_ path: String) -> String {
    if path.hasPrefix("/Users/") {
      let parts = path.split(separator: "/", maxSplits: 3)
      if parts.count >= 2 {
        return "~/" + (parts.count > 2 ? String(parts[2...].joined(separator: "/")) : "")
      }
    }
    return path.isEmpty ? "~" : path
  }

  static func projectName(for session: RootSessionNode) -> String {
    session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
  }

  static func activityText(
    for session: RootSessionNode,
    status: SessionDisplayStatus
  ) -> String {
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
  static func activityIcon(
    for session: RootSessionNode,
    status: SessionDisplayStatus
  ) -> String {
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
