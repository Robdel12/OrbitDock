//
//  QuestLink.swift
//  OrbitDock
//

import Foundation

struct QuestLink: Identifiable, Hashable {
  let id: String
  let questId: String
  let source: Source
  let url: String
  var title: String?
  var externalId: String? // e.g., "VIZ-123" or "#456"
  let detectedFrom: Detection
  let createdAt: Date

  enum Source: String {
    case githubPR = "github_pr"
    case githubIssue = "github_issue"
    case linear
    case planFile = "plan_file"

    var label: String {
      switch self {
        case .githubPR: "Pull Request"
        case .githubIssue: "Issue"
        case .linear: "Linear"
        case .planFile: "Plan"
      }
    }

    var icon: String {
      switch self {
        case .githubPR: "arrow.triangle.pull"
        case .githubIssue: "number"
        case .linear: "checklist"
        case .planFile: "doc.plaintext"
      }
    }

    var shortLabel: String {
      switch self {
        case .githubPR: "PR"
        case .githubIssue: "Issue"
        case .linear: "Linear"
        case .planFile: "Plan"
      }
    }
  }

  enum Detection: String {
    case cliOutput = "cli_output"
    case manual

    var label: String {
      switch self {
        case .cliOutput: "Auto-detected"
        case .manual: "Manual"
      }
    }
  }

  /// Display name (title or external ID or truncated URL)
  var displayName: String {
    if let title, !title.isEmpty {
      return title
    }
    if let externalId, !externalId.isEmpty {
      return externalId
    }
    // Extract repo/number from GitHub URL
    if source == .githubPR || source == .githubIssue {
      let components = url.components(separatedBy: "/")
      if components.count >= 2 {
        let number = components.last ?? ""
        let repo = components.dropLast().last ?? ""
        return "\(repo)#\(number)"
      }
    }
    return url
  }
}
