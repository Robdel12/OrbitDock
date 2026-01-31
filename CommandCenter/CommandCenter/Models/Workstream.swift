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

    // Origin - Linear
    var linearIssueId: String?
    var linearIssueTitle: String?
    var linearIssueState: String?
    var linearIssueURL: String?

    // Origin - GitHub Issue
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

    // Lifecycle
    var stage: Stage

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

    enum Stage: String {
        case working
        case prOpen = "pr_open"
        case inReview = "in_review"
        case approved
        case merged
        case closed
    }

    // MARK: - Computed Properties

    var displayName: String {
        linearIssueTitle ?? githubIssueTitle ?? githubPRTitle ?? branch
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
        linearIssueId != nil || githubIssueNumber != nil
    }

    var hasPR: Bool {
        githubPRNumber != nil
    }

    var isActive: Bool {
        stage == .working || stage == .prOpen || stage == .inReview
    }

    var stageIcon: String {
        switch stage {
        case .working: return "hammer.fill"
        case .prOpen: return "arrow.up.circle.fill"
        case .inReview: return "eye.fill"
        case .approved: return "checkmark.seal.fill"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle.fill"
        }
    }

    var formattedSessionTime: String {
        let hours = totalSessionSeconds / 3600
        let minutes = (totalSessionSeconds % 3600) / 60
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
              let range = Range(match.range(at: 1), in: branch) else {
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
              let number = Int(branch[range]) else {
            return nil
        }
        return number
    }
}
