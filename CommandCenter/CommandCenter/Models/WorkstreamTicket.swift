//
//  WorkstreamTicket.swift
//  OrbitDock
//
//  A ticket (Linear issue, GitHub issue, or GitHub PR) linked to a workstream
//

import Foundation

struct WorkstreamTicket: Identifiable, Equatable {
    let id: String
    let workstreamId: String
    let source: Source

    // Linear fields
    var linearIssueId: String?
    var linearTeamId: String?

    // GitHub fields
    var githubOwner: String?
    var githubRepo: String?
    var githubNumber: Int?

    // Common fields
    var title: String?
    var state: String?
    var url: String?

    // Relationship
    var isPrimary: Bool
    let linkedAt: Date
    var updatedAt: Date

    enum Source: String, CaseIterable {
        case linear
        case githubIssue = "github_issue"
        case githubPR = "github_pr"

        var icon: String {
            switch self {
            case .linear: return "checklist"
            case .githubIssue: return "number"
            case .githubPR: return "arrow.triangle.pull"
            }
        }

        var color: String {
            switch self {
            case .linear: return "serverLinear"
            case .githubIssue, .githubPR: return "serverGitHub"
            }
        }
    }

    // MARK: - Computed Properties

    var displayId: String {
        switch source {
        case .linear:
            return linearIssueId?.uppercased() ?? "?"
        case .githubIssue, .githubPR:
            if let num = githubNumber {
                return "#\(num)"
            }
            return "?"
        }
    }

    var displayTitle: String {
        title ?? displayId
    }

    var isOpen: Bool {
        guard let state = state?.lowercased() else { return true }
        return !["done", "closed", "merged", "cancelled", "canceled"].contains(state)
    }

    var stateColor: String {
        guard let state = state?.lowercased() else { return "textTertiary" }
        switch state {
        case "done", "merged": return "statusSuccess"
        case "in progress", "in_progress", "open", "draft": return "statusWorking"
        case "blocked", "cancelled", "canceled", "closed": return "statusError"
        default: return "textSecondary"
        }
    }
}
