//
//  WorkstreamDetailView.swift
//  OrbitDock
//
//  Detailed view of a single workstream
//  Shows timeline, sessions, commits, PR info
//

import SwiftUI

struct WorkstreamDetailView: View {
    let workstream: Workstream
    let repo: Repo?

    @State private var sessions: [Session] = []
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private let db = DatabaseManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with close button
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    header

                // Quick Actions
                actionButtons

                // Origin Section (Linear/GitHub Issue)
                if workstream.hasOrigin {
                    originSection
                }

                // PR Section
                if workstream.hasPR {
                    prSection
                }

                // Sessions Section
                sessionsSection
            }
                .padding(20)
            }
        }
        .background(Color.backgroundPrimary)
        .onAppear(perform: loadSessions)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stage badge
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: workstream.stageIcon)
                        .font(.caption)
                    Text(workstream.stage.displayName)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(workstream.stage.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(workstream.stage.color.opacity(0.15))
                .clipShape(Capsule())

                Spacer()

                // Repo badge
                if let repo = repo {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption)
                        Text(repo.name)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.textSecondary)
                }
            }

            // Branch name
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title3)
                    .foregroundStyle(Color.gitBranch)

                Text(workstream.branch)
                    .font(.title2.bold())
                    .foregroundStyle(Color.textPrimary)
            }

            // Title
            if workstream.displayName != workstream.branch {
                Text(workstream.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.textSecondary)
            }

            // Stats row
            HStack(spacing: 20) {
                statItem(icon: "cpu", value: "\(workstream.sessionCount)", label: "sessions")
                statItem(icon: "clock", value: workstream.formattedSessionTime, label: "total time")
                statItem(icon: "point.3.connected.trianglepath.dotted", value: "\(workstream.commitCount)", label: "commits")

                if let lastActivity = workstream.lastActivityAt {
                    Spacer()
                    Text("Last active \(lastActivity.relativeFormatted)")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }
            .padding(.top, 4)
        }
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color.accent)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            Text(label)
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if let prURL = workstream.githubPRURL, let url = URL(string: prURL) {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text("View PR")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(ActionButtonStyle())
            }

            if let linearURL = workstream.linearIssueURL, let url = URL(string: linearURL) {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                        Text("View Issue")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(ActionButtonStyle())
            }

            if let repo = repo, let ghURL = repo.githubURL {
                Button {
                    openURL(ghURL)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("View Repo")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(ActionButtonStyle())
            }
        }
    }

    // MARK: - Origin Section

    private var originSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Origin", icon: "flag")

            VStack(alignment: .leading, spacing: 8) {
                if let linearId = workstream.linearIssueId {
                    HStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .foregroundStyle(Color.serverLinear)
                        Text(linearId)
                            .font(.headline)
                            .foregroundStyle(Color.textPrimary)

                        if let state = workstream.linearIssueState {
                            Text(state)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.surfaceHover)
                                .clipShape(Capsule())
                        }
                    }

                    if let title = workstream.linearIssueTitle {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(Color.textSecondary)
                    }
                }

                if let issueNum = workstream.githubIssueNumber {
                    HStack(spacing: 8) {
                        Image(systemName: "number")
                            .foregroundStyle(Color.serverGitHub)
                        Text("#\(issueNum)")
                            .font(.headline)
                            .foregroundStyle(Color.textPrimary)

                        if let state = workstream.githubIssueState {
                            Text(state)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.surfaceHover)
                                .clipShape(Capsule())
                        }
                    }

                    if let title = workstream.githubIssueTitle {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
            .padding(16)
            .background(Color.backgroundTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - PR Section

    private var prSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Pull Request", icon: "arrow.triangle.pull")

            VStack(alignment: .leading, spacing: 12) {
                // PR Header
                HStack {
                    if let prNum = workstream.githubPRNumber {
                        Text("#\(prNum)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Color.serverGitHub)
                    }

                    if let title = workstream.githubPRTitle {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                    }

                    Spacer()

                    if let state = workstream.githubPRState {
                        Text(state.rawValue.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(prStateColor(state))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(prStateColor(state).opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                // Diff stats
                if let additions = workstream.githubPRAdditions, let deletions = workstream.githubPRDeletions {
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            Text("+\(additions)")
                                .foregroundStyle(Color.statusSuccess)
                        }
                        HStack(spacing: 4) {
                            Text("-\(deletions)")
                                .foregroundStyle(Color.statusError)
                        }
                    }
                    .font(.subheadline.monospacedDigit())
                }

                // Review status
                if workstream.reviewApprovals > 0 || workstream.reviewComments > 0 {
                    Divider()
                        .background(Color.surfaceBorder)

                    HStack(spacing: 20) {
                        if workstream.reviewApprovals > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.statusSuccess)
                                Text("\(workstream.reviewApprovals) approval\(workstream.reviewApprovals == 1 ? "" : "s")")
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }

                        if workstream.reviewComments > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.fill")
                                    .foregroundStyle(Color.statusWaiting)
                                Text("\(workstream.reviewComments) comment\(workstream.reviewComments == 1 ? "" : "s")")
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }

                        if let reviewState = workstream.reviewState {
                            Spacer()
                            Text(reviewState.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(reviewStateColor(reviewState))
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(16)
            .background(Color.backgroundTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Sessions Section

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Sessions", icon: "cpu")

            if sessions.isEmpty {
                Text("No sessions yet")
                    .font(.subheadline)
                    .foregroundStyle(Color.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(sessions, id: \.id) { session in
                    SessionRowCompact(session: session)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accent)

            Text(title)
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
        }
    }

    private func prStateColor(_ state: Workstream.PRState) -> Color {
        switch state {
        case .draft: return Color.textTertiary
        case .open: return Color.statusSuccess
        case .merged: return Color.serverGitHub
        case .closed: return Color.statusError
        }
    }

    private func reviewStateColor(_ state: Workstream.ReviewState) -> Color {
        switch state {
        case .pending: return Color.textTertiary
        case .changesRequested: return Color.statusWaiting
        case .approved: return Color.statusSuccess
        }
    }

    private func loadSessions() {
        // Load sessions for this workstream
        let allSessions = db.fetchSessions()
        sessions = allSessions.filter { session in
            // Match by branch for now - later we'll use workstream_id
            session.branch == workstream.branch
        }
    }
}

// MARK: - Review State Extension

extension Workstream.ReviewState {
    var displayName: String {
        switch self {
        case .pending: return "Pending Review"
        case .changesRequested: return "Changes Requested"
        case .approved: return "Approved"
        }
    }
}

// MARK: - Session Row Compact

struct SessionRowCompact: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(session.isActive ? Color.statusWorking : Color.statusIdle)
                .frame(width: 8, height: 8)

            // Session info
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let model = session.model {
                        Text(model)
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)
                    }

                    if let started = session.startedAt {
                        Text(started.relativeFormatted)
                            .font(.caption)
                            .foregroundStyle(Color.textQuaternary)
                    }
                }
            }

            Spacer()

            // Duration
            Text(session.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.textSecondary)

            // Cost
            if session.totalCostUSD > 0 {
                Text(session.formattedCost)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .padding(12)
        .background(Color.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Action Button Style

struct ActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.surfaceHover)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

#Preview {
    WorkstreamDetailView(
        workstream: Workstream(
            id: "preview",
            repoId: "repo1",
            branch: "feat/visual-diff-annotations",
            directory: nil,
            linearIssueId: "VIZ-42",
            linearIssueTitle: "Add visual diff annotations to screenshot comparisons",
            githubPRNumber: 127,
            githubPRTitle: "feat: Visual diff annotations",
            githubPRState: .open,
            githubPRURL: "https://github.com/vizzly-testing/vizzly/pull/127",
            githubPRAdditions: 847,
            githubPRDeletions: 234,
            reviewState: .pending,
            reviewApprovals: 1,
            reviewComments: 2,
            stage: .inReview,
            sessionCount: 3,
            totalSessionSeconds: 15120,
            commitCount: 12,
            lastActivityAt: Date().addingTimeInterval(-3600),
            createdAt: Date().addingTimeInterval(-86400 * 3),
            updatedAt: Date().addingTimeInterval(-3600)
        ),
        repo: Repo(
            id: "repo1",
            name: "vizzly",
            path: "/Users/rob/Dev/vizzly",
            githubOwner: "vizzly-testing",
            githubName: "vizzly",
            createdAt: Date()
        )
    )
    .frame(width: 600, height: 800)
    .darkTheme()
}
