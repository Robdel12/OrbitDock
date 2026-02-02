//
//  Workstream.swift
//  OrbitDock
//

import Foundation

struct Workstream: Identifiable, Equatable {
  let id: String
  let repoId: String
  let branch: String
  let directory: String?

  // Workstream identity
  var name: String?
  var description: String?

  // Multi-ticket support (populated separately)
  var tickets: [WorkstreamTicket]?
  var notes: [WorkstreamNote]?

  // Legacy single-ticket fields (kept for backwards compat)
  var linearIssueId: String?
  var linearIssueTitle: String?
  var linearIssueState: String?
  var linearIssueURL: String?

  // Legacy GitHub issue
  var githubIssueNumber: Int?
  var githubIssueTitle: String?
  var githubIssueState: String?

  // Delivery - PR
  var githubPRNumber: Int?
  var githubPRTitle: String?
  var githubPRState: PRState?
  var githubPRURL: String?
  var githubPRAdditions: Int?
  var githubPRDeletions: Int?

  // Review status
  var reviewState: ReviewState?
  var reviewApprovals: Int
  var reviewComments: Int

  // Lifecycle - legacy single stage (computed from flags for backwards compat)
  var stage: Stage

  // Lifecycle - combinable state flags
  var isWorking: Bool = true
  var hasOpenPR: Bool = false
  var inReview: Bool = false
  var hasApproval: Bool = false
  var isMerged: Bool = false
  var isClosed: Bool = false

  // Archive state - hides from active list without changing stage
  var isArchived: Bool = false

  // Stats
  var sessionCount: Int
  var totalSessionSeconds: Int
  var commitCount: Int

  // Timestamps
  var lastActivityAt: Date?
  let createdAt: Date
  var updatedAt: Date

  // Relationships (populated separately, excluded from Equatable)
  var repo: Repo?
  var sessions: [Session]?

  static func == (lhs: Workstream, rhs: Workstream) -> Bool {
    lhs.id == rhs.id
  }

  enum PRState: String {
    case draft
    case open
    case merged
    case closed
  }

  enum ReviewState: String {
    case pending
    case changesRequested = "changes_requested"
    case approved
  }

  enum Stage: String, CaseIterable {
    case working
    case prOpen = "pr_open"
    case inReview = "in_review"
    case approved
    case merged
    case closed

    var icon: String {
      switch self {
      case .working: "hammer.fill"
      case .prOpen: "arrow.up.circle.fill"
      case .inReview: "eye.fill"
      case .approved: "checkmark.seal.fill"
      case .merged: "arrow.triangle.merge"
      case .closed: "xmark.circle.fill"
      }
    }
  }

  /// Combinable state flags - can have multiple active at once
  enum StateFlag: String, CaseIterable, Identifiable {
    case working
    case hasOpenPR = "has_open_pr"
    case inReview = "in_review"
    case hasApproval = "has_approval"
    case merged
    case closed

    var id: String { rawValue }

    var label: String {
      switch self {
      case .working: "Working"
      case .hasOpenPR: "PR Open"
      case .inReview: "In Review"
      case .hasApproval: "Approved"
      case .merged: "Merged"
      case .closed: "Closed"
      }
    }

    var icon: String {
      switch self {
      case .working: "hammer.fill"
      case .hasOpenPR: "arrow.up.circle.fill"
      case .inReview: "eye.fill"
      case .hasApproval: "checkmark.seal.fill"
      case .merged: "arrow.triangle.merge"
      case .closed: "xmark.circle.fill"
      }
    }

    /// Whether this flag can be combined with others
    var isCombinable: Bool {
      switch self {
      case .working, .hasOpenPR, .inReview, .hasApproval: true
      case .merged, .closed: false
      }
    }

    /// Terminal flags that end the workstream
    var isTerminal: Bool {
      switch self {
      case .merged, .closed: true
      default: false
      }
    }

    static var combinableFlags: [StateFlag] {
      allCases.filter(\.isCombinable)
    }

    static var terminalFlags: [StateFlag] {
      allCases.filter(\.isTerminal)
    }
  }

  // MARK: - Computed Properties

  var displayName: String {
    // Prefer explicit name, then primary ticket title, then legacy fields, then branch
    if let name, !name.isEmpty {
      return name
    }
    if let primaryTicket = tickets?.first(where: { $0.isPrimary }), let title = primaryTicket.title {
      return title
    }
    return linearIssueTitle ?? githubIssueTitle ?? githubPRTitle ?? branch
  }

  var originLabel: String? {
    if let id = linearIssueId {
      return id.uppercased()
    }
    if let num = githubIssueNumber {
      return "#\(num)"
    }
    return nil
  }

  var hasOrigin: Bool {
    // Check new multi-ticket first, then legacy
    if let tickets, !tickets.isEmpty {
      return true
    }
    return linearIssueId != nil || githubIssueNumber != nil
  }

  var hasTickets: Bool {
    if let tickets {
      return !tickets.isEmpty
    }
    return false
  }

  var openTickets: [WorkstreamTicket] {
    tickets?.filter(\.isOpen) ?? []
  }

  var primaryTicket: WorkstreamTicket? {
    tickets?.first(where: { $0.isPrimary }) ?? tickets?.first
  }

  var unresolvedBlockers: [WorkstreamNote] {
    notes?.filter { $0.type == .blocker && !$0.isResolved } ?? []
  }

  var recentNotes: [WorkstreamNote] {
    notes?.sorted { $0.createdAt > $1.createdAt } ?? []
  }

  var hasPR: Bool {
    githubPRNumber != nil
  }

  var isActive: Bool {
    !isMerged && !isClosed && !isArchived
  }

  /// Get all currently active state flags
  var activeFlags: [StateFlag] {
    var flags: [StateFlag] = []
    if isWorking { flags.append(.working) }
    if hasOpenPR { flags.append(.hasOpenPR) }
    if inReview { flags.append(.inReview) }
    if hasApproval { flags.append(.hasApproval) }
    if isMerged { flags.append(.merged) }
    if isClosed { flags.append(.closed) }
    return flags
  }

  /// Check if a specific flag is active
  func hasFlag(_ flag: StateFlag) -> Bool {
    switch flag {
    case .working: isWorking
    case .hasOpenPR: hasOpenPR
    case .inReview: inReview
    case .hasApproval: hasApproval
    case .merged: isMerged
    case .closed: isClosed
    }
  }

  /// Primary flag for display (most "advanced" active state)
  var primaryFlag: StateFlag {
    if isClosed { return .closed }
    if isMerged { return .merged }
    if hasApproval { return .hasApproval }
    if inReview { return .inReview }
    if hasOpenPR { return .hasOpenPR }
    return .working
  }

  var stageIcon: String {
    switch stage {
      case .working: "hammer.fill"
      case .prOpen: "arrow.up.circle.fill"
      case .inReview: "eye.fill"
      case .approved: "checkmark.seal.fill"
      case .merged: "arrow.triangle.merge"
      case .closed: "xmark.circle.fill"
    }
  }

  var formattedSessionTime: String {
    let hours = totalSessionSeconds / 3_600
    let minutes = (totalSessionSeconds % 3_600) / 60
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  var diffStats: String? {
    guard let additions = githubPRAdditions, let deletions = githubPRDeletions else { return nil }
    return "+\(additions) -\(deletions)"
  }

  // MARK: - Branch Parsing

  /// Parse Linear issue ID from branch name (e.g., "viz-42-description" -> "VIZ-42")
  static func parseLinearIssue(from branch: String) -> String? {
    // Match patterns like: viz-42, VIZ-42, feat/viz-42-description, fix/VIZ-123-something
    let pattern = #"(?:^|/)([a-zA-Z]+-\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: branch, range: NSRange(branch.startIndex..., in: branch)),
          let range = Range(match.range(at: 1), in: branch)
    else {
      return nil
    }
    return String(branch[range]).uppercased()
  }

  /// Parse GitHub issue number from branch name (e.g., "fix/123-bug" -> 123)
  static func parseGitHubIssue(from branch: String) -> Int? {
    // Match patterns like: fix/123-description, 123-bug, issue-123
    let pattern = #"(?:^|/|issue-)(\d+)(?:-|$)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: branch, range: NSRange(branch.startIndex..., in: branch)),
          let range = Range(match.range(at: 1), in: branch),
          let number = Int(branch[range])
    else {
      return nil
    }
    return number
  }
}
