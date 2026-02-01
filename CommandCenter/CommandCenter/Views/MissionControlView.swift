//
//  MissionControlView.swift
//  OrbitDock
//
//  Mission Control - Overview of all active workstreams
//  Shows workstreams grouped by stage with quick stats
//

import SwiftUI

struct MissionControlView: View {
  var onSelectSession: ((String) -> Void)?

  @State private var workstreams: [Workstream] = []
  @State private var repos: [String: Repo] = [:]
  @State private var selectedWorkstream: Workstream?
  @State private var filterStage: Workstream.Stage?
  @State private var showingCreateSheet = false

  private let db = DatabaseManager.shared

  var body: some View {
    VStack(spacing: 0) {
      // Header
      header

      // Content
      ScrollView {
        LazyVStack(spacing: 16) {
          if workstreams.isEmpty {
            emptyState
          } else {
            // Group by stage
            ForEach(stageGroups, id: \.stage) { group in
              stageSection(group)
            }
          }
        }
        .padding(20)
      }
    }
    .background(Color.backgroundPrimary)
    .onAppear(perform: loadData)
    .onReceive(NotificationCenter.default.publisher(for: .init("DatabaseChanged"))) { _ in
      loadData()
    }
    .sheet(item: $selectedWorkstream) { workstream in
      WorkstreamDetailView(
        workstream: workstream,
        repo: repos[workstream.repoId],
        onSelectSession: onSelectSession
      )
      .frame(minWidth: 600, minHeight: 500)
    }
    .sheet(isPresented: $showingCreateSheet) {
      CreateWorkstreamSheet {
        loadData()
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Mission Control")
          .font(.title.bold())
          .foregroundStyle(Color.textPrimary)

        Text("\(workstreams.count) active workstreams")
          .font(.subheadline)
          .foregroundStyle(Color.textSecondary)
      }

      Spacer()

      // Stage filter
      Menu {
        Button("All Stages") {
          filterStage = nil
        }
        Divider()
        ForEach([Workstream.Stage.working, .prOpen, .inReview, .approved], id: \.self) { stage in
          Button(stage.displayName) {
            filterStage = stage
          }
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "line.3.horizontal.decrease.circle")
          Text(filterStage?.displayName ?? "All")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.surfaceHover)
        .clipShape(Capsule())
      }
      .buttonStyle(.plain)

      // Create button
      Button {
        showingCreateSheet = true
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "plus")
          Text("New")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accent)
        .clipShape(Capsule())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .background(Color.backgroundSecondary)
  }

  // MARK: - Stage Sections

  private var stageGroups: [(stage: Workstream.Stage, workstreams: [Workstream])] {
    let filtered = filterStage.map { stage in
      workstreams.filter { $0.stage == stage }
    } ?? workstreams

    let grouped = Dictionary(grouping: filtered, by: \.stage)
    let order: [Workstream.Stage] = [.inReview, .prOpen, .working, .approved, .merged]

    return order.compactMap { stage in
      guard let items = grouped[stage], !items.isEmpty else { return nil }
      return (stage: stage, workstreams: items)
    }
  }

  private func stageSection(_ group: (stage: Workstream.Stage, workstreams: [Workstream])) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      // Section header
      HStack(spacing: 8) {
        Circle()
          .fill(group.stage.color)
          .frame(width: 8, height: 8)

        Text(group.stage.displayName.uppercased())
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.textSecondary)
          .tracking(1.5)

        Text("\(group.workstreams.count)")
          .font(.caption.weight(.medium))
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.surfaceHover)
          .clipShape(Capsule())

        Spacer()
      }

      // Workstream cards
      ForEach(group.workstreams, id: \.id) { workstream in
        WorkstreamCard(
          workstream: workstream,
          repo: repos[workstream.repoId],
          onStageChange: { stage in
            db.updateWorkstreamStage(workstream.id, to: stage)
            loadData()
          }
        )
        .onTapGesture {
          selectedWorkstream = workstream
        }
      }
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "scope")
        .font(.system(size: 48))
        .foregroundStyle(Color.textTertiary)

      Text("No Active Workstreams")
        .font(.headline)
        .foregroundStyle(Color.textSecondary)

      Text("Start a Claude session on a feature branch to create a workstream")
        .font(.subheadline)
        .foregroundStyle(Color.textTertiary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
  }

  // MARK: - Data Loading

  private func loadData() {
    workstreams = db.fetchActiveWorkstreams()

    // Load repos for all workstreams
    let allRepos = db.fetchRepos()
    repos = Dictionary(uniqueKeysWithValues: allRepos.map { ($0.id, $0) })
  }
}

// MARK: - Workstream Card

struct WorkstreamCard: View {
  let workstream: Workstream
  let repo: Repo?
  var onStageChange: ((Workstream.Stage) -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Top row: Branch + Repo
      HStack {
        // Branch name
        HStack(spacing: 6) {
          Image(systemName: "arrow.triangle.branch")
            .font(.caption)
            .foregroundStyle(Color.gitBranch)

          Text(workstream.branch)
            .font(.headline)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
        }

        Spacer()

        // Repo badge
        if let repo {
          Text(repo.name)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.surfaceHover)
            .clipShape(Capsule())
        }
      }

      // Title (from Linear/GitHub or branch)
      if workstream.displayName != workstream.branch {
        Text(workstream.displayName)
          .font(.subheadline)
          .foregroundStyle(Color.textSecondary)
          .lineLimit(2)
      }

      // Origin + PR row
      HStack(spacing: 12) {
        // Linear/GitHub issue badge
        if let origin = workstream.originLabel {
          HStack(spacing: 4) {
            Image(systemName: workstream.linearIssueId != nil ? "checklist" : "number")
              .font(.caption2)
            Text(origin)
              .font(.caption.weight(.medium))
          }
          .foregroundStyle(Color.serverLinear)
        }

        // PR badge
        if let prNumber = workstream.githubPRNumber {
          HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull")
              .font(.caption2)
            Text("#\(prNumber)")
              .font(.caption.weight(.medium))

            if let state = workstream.githubPRState {
              Text(state.rawValue)
                .font(.caption2)
                .foregroundStyle(prStateColor(state))
            }
          }
          .foregroundStyle(Color.serverGitHub)
        }

        Spacer()

        // Review status
        if workstream.reviewApprovals > 0 || workstream.reviewComments > 0 {
          HStack(spacing: 8) {
            if workstream.reviewApprovals > 0 {
              HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                  .font(.caption2)
                Text("\(workstream.reviewApprovals)")
                  .font(.caption)
              }
              .foregroundStyle(Color.statusSuccess)
            }

            if workstream.reviewComments > 0 {
              HStack(spacing: 2) {
                Image(systemName: "bubble.left.fill")
                  .font(.caption2)
                Text("\(workstream.reviewComments)")
                  .font(.caption)
              }
              .foregroundStyle(Color.statusWaiting)
            }
          }
        }
      }

      // Stats row
      HStack(spacing: 16) {
        // Sessions
        HStack(spacing: 4) {
          Image(systemName: "cpu")
            .font(.caption2)
          Text("\(workstream.sessionCount) sessions")
            .font(.caption)
        }
        .foregroundStyle(Color.textTertiary)

        // Time spent
        if workstream.totalSessionSeconds > 0 {
          HStack(spacing: 4) {
            Image(systemName: "clock")
              .font(.caption2)
            Text(workstream.formattedSessionTime)
              .font(.caption)
          }
          .foregroundStyle(Color.textTertiary)
        }

        // Commits
        if workstream.commitCount > 0 {
          HStack(spacing: 4) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
              .font(.caption2)
            Text("\(workstream.commitCount) commits")
              .font(.caption)
          }
          .foregroundStyle(Color.textTertiary)
        }

        // Diff stats
        if let diff = workstream.diffStats {
          Text(diff)
            .font(.caption.monospaced())
            .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        // Last activity
        if let lastActivity = workstream.lastActivityAt {
          Text(lastActivity.relativeFormatted)
            .font(.caption)
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
    .padding(16)
    .background(Color.backgroundTertiary)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(workstream.stage.color.opacity(0.3), lineWidth: 1)
    )
    .contextMenu {
      if workstream.isActive {
        Button {
          onStageChange?(.merged)
        } label: {
          Label("Complete", systemImage: "checkmark.circle")
        }

        Button {
          onStageChange?(.closed)
        } label: {
          Label("Cancel", systemImage: "xmark.circle")
        }
      } else {
        Button {
          onStageChange?(.working)
        } label: {
          Label("Reopen", systemImage: "arrow.counterclockwise")
        }
      }

      Divider()

      if let repo {
        Button {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path)
        } label: {
          Label("Reveal in Finder", systemImage: "folder")
        }
      }

      if let linearURL = workstream.linearIssueURL, let url = URL(string: linearURL) {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Label("Open Linear Issue", systemImage: "link")
        }
      }

      if let prURL = workstream.githubPRURL, let url = URL(string: prURL) {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Label("Open Pull Request", systemImage: "arrow.triangle.pull")
        }
      }
    }
  }

  private func prStateColor(_ state: Workstream.PRState) -> Color {
    switch state {
      case .draft: Color.textTertiary
      case .open: Color.statusSuccess
      case .merged: Color.serverGitHub
      case .closed: Color.statusError
    }
  }
}

// MARK: - Stage Extensions

extension Workstream.Stage {
  var displayName: String {
    switch self {
      case .working: "Working"
      case .prOpen: "PR Open"
      case .inReview: "In Review"
      case .approved: "Approved"
      case .merged: "Merged"
      case .closed: "Closed"
    }
  }

  var color: Color {
    switch self {
      case .working: Color.statusWorking
      case .prOpen: Color.serverGitHub
      case .inReview: Color.statusWaiting
      case .approved: Color.statusSuccess
      case .merged: Color.serverGitHub
      case .closed: Color.textTertiary
    }
  }
}

// MARK: - StateFlag Extensions

extension Workstream.StateFlag {
  var color: Color {
    switch self {
    case .working: Color.statusWorking
    case .hasOpenPR: Color.serverGitHub
    case .inReview: Color.statusWaiting
    case .hasApproval: Color.statusSuccess
    case .merged: Color.serverGitHub
    case .closed: Color.textTertiary
    }
  }
}

// MARK: - Date Extension

extension Date {
  var relativeFormatted: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: self, relativeTo: Date())
  }
}

#Preview {
  MissionControlView()
    .frame(width: 600, height: 800)
    .darkTheme()
}
