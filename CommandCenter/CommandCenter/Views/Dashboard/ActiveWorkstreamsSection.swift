//
//  ActiveWorkstreamsSection.swift
//  OrbitDock
//
//  Shows active workstreams as a strip in the Sessions tab
//

import SwiftUI

struct ActiveWorkstreamsSection: View {
  var onSelectSession: ((String) -> Void)? = nil

  @State private var workstreams: [Workstream] = []
  @State private var repos: [String: Repo] = [:]
  @State private var selectedWorkstream: Workstream?
  @State private var isExpanded = true
  @State private var showingCreateSheet = false

  private let db = DatabaseManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      header

      // Content
      if isExpanded && !workstreams.isEmpty {
        VStack(spacing: 6) {
          ForEach(workstreams, id: \.id) { workstream in
            WorkstreamRow(
              workstream: workstream,
              repo: repos[workstream.repoId],
              onSelect: { selectedWorkstream = workstream },
              onStageChange: { stage in
                updateStage(workstream, to: stage)
              }
            )
          }
        }
        .padding(.top, 10)
      }
    }
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
    Button {
      withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
        isExpanded.toggle()
      }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))

        Image(systemName: "scope")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.accent)

        Text("Active Workstreams")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)

        Text("\(workstreams.count)")
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Color.surfaceHover, in: Capsule())

        Spacer()

        // Stage summary chips
        if !workstreams.isEmpty {
          HStack(spacing: 8) {
            let stageCounts = Dictionary(grouping: workstreams, by: \.stage)
              .mapValues(\.count)

            ForEach([Workstream.Stage.working, .prOpen, .inReview], id: \.self) { stage in
              if let count = stageCounts[stage], count > 0 {
                HStack(spacing: 4) {
                  Circle()
                    .fill(stage.color)
                    .frame(width: 6, height: 6)
                  Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(stage.color)
                }
              }
            }
          }
        }

        // Create button
        Button {
          showingCreateSheet = true
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.accent)
            .frame(width: 22, height: 22)
            .background(Color.accent.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Create Workstream")
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
      .background(
        Color.backgroundTertiary.opacity(0.5),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Data

  private func loadData() {
    workstreams = db.fetchActiveWorkstreams()
    let allRepos = db.fetchRepos()
    repos = Dictionary(uniqueKeysWithValues: allRepos.map { ($0.id, $0) })
  }

  private func updateStage(_ workstream: Workstream, to stage: Workstream.Stage) {
    db.updateWorkstreamStage(workstream.id, to: stage)
    loadData()
  }
}

// MARK: - Workstream Row

struct WorkstreamRow: View {
  let workstream: Workstream
  let repo: Repo?
  let onSelect: () -> Void
  let onStageChange: (Workstream.Stage) -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Stage indicator
        Circle()
          .fill(workstream.stage.color)
          .frame(width: 8, height: 8)
          .frame(width: 20)

        // Branch + ticket info
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            // Branch name
            HStack(spacing: 5) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(Color.gitBranch)
              Text(workstream.branch)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            }

            // Ticket badge
            if let origin = workstream.originLabel {
              Text(origin)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.serverLinear)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.serverLinear.opacity(0.15), in: Capsule())
            }
          }

          // Stats row
          HStack(spacing: 10) {
            // Sessions
            HStack(spacing: 4) {
              Image(systemName: "cpu")
                .font(.system(size: 9))
              Text("\(workstream.sessionCount)")
                .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.tertiary)

            // Time
            if workstream.totalSessionSeconds > 0 {
              HStack(spacing: 4) {
                Image(systemName: "clock")
                  .font(.system(size: 9))
                Text(workstream.formattedSessionTime)
                  .font(.system(size: 10, weight: .medium))
              }
              .foregroundStyle(.tertiary)
            }

            // Last activity
            if let lastActivity = workstream.lastActivityAt {
              Text(lastActivity.relativeFormatted)
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            }
          }
        }

        Spacer()

        // Stage badge
        HStack(spacing: 5) {
          Image(systemName: workstream.stageIcon)
            .font(.system(size: 10, weight: .medium))
          Text(workstream.stage.displayName)
            .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(workstream.stage.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(workstream.stage.color.opacity(0.15), in: Capsule())

        // Repo badge
        if let repo = repo {
          Text(repo.name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.surfaceHover, in: Capsule())
        }
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(isHovering ? Color.surfaceSelected : Color.backgroundTertiary.opacity(0.5))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(workstream.stage.color.opacity(isHovering ? 0.25 : 0.1), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu {
      if workstream.isActive && !workstream.isArchived {
        Button {
          onStageChange(.merged)
        } label: {
          Label("Complete", systemImage: "checkmark.circle")
        }

        Button {
          onStageChange(.closed)
        } label: {
          Label("Cancel", systemImage: "xmark.circle")
        }

        Divider()

        Button {
          DatabaseManager.shared.archiveWorkstream(workstream.id)
        } label: {
          Label("Archive", systemImage: "archivebox")
        }
      } else if workstream.isArchived {
        Button {
          DatabaseManager.shared.unarchiveWorkstream(workstream.id)
        } label: {
          Label("Unarchive", systemImage: "archivebox.fill")
        }
      } else {
        Button {
          onStageChange(.working)
        } label: {
          Label("Reopen", systemImage: "arrow.counterclockwise")
        }
      }

      Divider()

      if let repo = repo {
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
}

// MARK: - Create Workstream Sheet

struct CreateWorkstreamSheet: View {
  let onSave: () -> Void

  enum RepoSource: Hashable {
    case sessions
    case existing
    case browse
  }

  /// Represents a unique project from recent sessions
  struct RecentProject: Identifiable, Hashable {
    let id: String  // path
    let path: String
    let name: String
    let branch: String?
    let lastUsed: Date?
  }

  @State private var repoSource: RepoSource = .sessions
  @State private var selectedRepo: Repo?
  @State private var selectedProject: RecentProject?
  @State private var repoPath = ""
  @State private var branch = ""
  @State private var name = ""
  @State private var repos: [Repo] = []
  @State private var recentProjects: [RecentProject] = []

  @Environment(\.dismiss) private var dismiss
  private let db = DatabaseManager.shared

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack(spacing: 12) {
        ZStack {
          Circle()
            .fill(Color.accent.opacity(0.15))
            .frame(width: 36, height: 36)
          Image(systemName: "scope")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.accent)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text("New Workstream")
            .font(.headline)
            .foregroundStyle(Color.textPrimary)
          Text("Track work on a feature branch")
            .font(.caption)
            .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.textTertiary)
            .frame(width: 24, height: 24)
            .background(Color.surfaceHover, in: Circle())
        }
        .buttonStyle(.plain)
      }
      .padding(20)
      .background(Color.backgroundSecondary)

      // Form
      VStack(alignment: .leading, spacing: 24) {
        // Repository section
        VStack(alignment: .leading, spacing: 10) {
          Text("REPOSITORY")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .tracking(0.5)

          // Source picker
          HStack(spacing: 0) {
            ForEach([RepoSource.sessions, .existing, .browse], id: \.self) { source in
              Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                  repoSource = source
                  // Clear selections when switching
                  if source != .sessions { selectedProject = nil }
                  if source != .existing { selectedRepo = nil }
                  if source != .browse { repoPath = "" }
                }
              } label: {
                HStack(spacing: 5) {
                  Image(systemName: source.icon)
                    .font(.system(size: 10))
                  Text(source.label)
                    .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(repoSource == source ? Color.textPrimary : Color.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(repoSource == source ? Color.surfaceSelected : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
              }
              .buttonStyle(.plain)
            }
          }
          .padding(3)
          .background(Color.backgroundTertiary)
          .clipShape(RoundedRectangle(cornerRadius: 8))

          // Content based on source
          switch repoSource {
          case .sessions:
            if recentProjects.isEmpty {
              emptySessionsState
            } else {
              ScrollView {
                VStack(spacing: 6) {
                  ForEach(recentProjects) { project in
                    ProjectRow(project: project, isSelected: selectedProject?.id == project.id) {
                      selectedProject = project
                      // Auto-fill branch if available
                      if let projectBranch = project.branch, !projectBranch.isEmpty,
                         projectBranch != "main", projectBranch != "master" {
                        branch = projectBranch
                      }
                    }
                  }
                }
              }
              .frame(maxHeight: 200)
            }

          case .existing:
            if repos.isEmpty {
              emptyReposState
            } else {
              ScrollView {
                VStack(spacing: 6) {
                  ForEach(repos, id: \.id) { repo in
                    RepoRow(repo: repo, isSelected: selectedRepo?.id == repo.id) {
                      selectedRepo = repo
                    }
                  }
                }
              }
              .frame(maxHeight: 200)
            }

          case .browse:
            // Browse for path
            HStack(spacing: 10) {
              HStack(spacing: 8) {
                Image(systemName: "folder")
                  .font(.system(size: 12))
                  .foregroundStyle(Color.textTertiary)
                TextField("Select or drop a folder...", text: $repoPath)
                  .textFieldStyle(.plain)
                  .font(.system(size: 13))
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(Color.backgroundTertiary)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .overlay(
                RoundedRectangle(cornerRadius: 8)
                  .strokeBorder(Color.surfaceBorder, lineWidth: 1)
              )

              Button {
                selectFolder()
              } label: {
                Text("Browse")
                  .font(.system(size: 12, weight: .medium))
                  .foregroundStyle(Color.accent)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(Color.accent.opacity(0.1))
                  .clipShape(RoundedRectangle(cornerRadius: 6))
              }
              .buttonStyle(.plain)
            }
          }
        }

        // Branch name
        VStack(alignment: .leading, spacing: 8) {
          Text("BRANCH")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .tracking(0.5)

          HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
              .font(.system(size: 12))
              .foregroundStyle(Color.gitBranch)
            TextField("feat/my-feature", text: $branch)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(Color.backgroundTertiary)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(Color.surfaceBorder, lineWidth: 1)
          )

          Text("Enter the name of an existing git branch to track")
            .font(.system(size: 10))
            .foregroundStyle(Color.textQuaternary)
        }

        // Display name (optional)
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            Text("DISPLAY NAME")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .tracking(0.5)
            Text("optional")
              .font(.system(size: 10))
              .foregroundStyle(Color.textQuaternary)
          }

          HStack(spacing: 8) {
            Image(systemName: "textformat")
              .font(.system(size: 12))
              .foregroundStyle(Color.textTertiary)
            TextField("Add Authentication System", text: $name)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(Color.backgroundTertiary)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(Color.surfaceBorder, lineWidth: 1)
          )
        }

      }
      .padding(20)

      Spacer(minLength: 0)

      // Footer
      HStack {
        // Preview of what will be created
        if canCreate {
          HStack(spacing: 6) {
            Circle()
              .fill(Color.statusWorking)
              .frame(width: 6, height: 6)
            Text(branch.isEmpty ? "branch" : branch)
              .font(.system(size: 11, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(1)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Color.surfaceHover)
          .clipShape(Capsule())
        }

        Spacer()

        Button {
          createWorkstream()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "plus")
              .font(.system(size: 11, weight: .bold))
            Text("Create")
              .font(.system(size: 13, weight: .semibold))
          }
          .foregroundStyle(canCreate ? Color.textPrimary : Color.textTertiary)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(canCreate ? Color.accent : Color.surfaceHover)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!canCreate)
      }
      .padding(20)
      .background(Color.backgroundSecondary)
    }
    .frame(width: 500, height: 600)
    .background(Color.backgroundPrimary)
    .onAppear {
      loadData()
    }
  }

  // MARK: - Empty States

  private var emptySessionsState: some View {
    HStack(spacing: 12) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 16))
        .foregroundStyle(Color.textTertiary)
      Text("No recent sessions found")
        .font(.system(size: 12))
        .foregroundStyle(Color.textTertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.backgroundTertiary.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var emptyReposState: some View {
    HStack(spacing: 12) {
      Image(systemName: "folder")
        .font(.system(size: 16))
        .foregroundStyle(Color.textTertiary)
      Text("No repositories tracked yet")
        .font(.system(size: 12))
        .foregroundStyle(Color.textTertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.backgroundTertiary.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - Helpers

  private var canCreate: Bool {
    let hasRepo = selectedProject != nil || selectedRepo != nil || !repoPath.isEmpty
    let hasBranch = !branch.trimmingCharacters(in: .whitespaces).isEmpty
    return hasRepo && hasBranch
  }

  private func loadData() {
    repos = db.fetchRepos()

    // Get unique recent projects from sessions
    let sessions = db.fetchSessions()
    var seenPaths = Set<String>()
    var projects: [RecentProject] = []

    for session in sessions {
      let path = session.projectPath
      guard !path.isEmpty, !seenPaths.contains(path) else { continue }
      seenPaths.insert(path)

      projects.append(RecentProject(
        id: path,
        path: path,
        name: session.projectName ?? URL(fileURLWithPath: path).lastPathComponent,
        branch: session.branch,
        lastUsed: session.startedAt
      ))

      if projects.count >= 10 { break }
    }

    recentProjects = projects

    // Default to sessions if we have any, otherwise browse
    if recentProjects.isEmpty && repos.isEmpty {
      repoSource = .browse
    }
  }

  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a git repository"

    if panel.runModal() == .OK, let url = panel.url {
      repoPath = url.path
    }
  }

  private func createWorkstream() {
    let repo: Repo?

    if let project = selectedProject {
      // From session - find or create repo
      let repoName = URL(fileURLWithPath: project.path).lastPathComponent
      repo = db.findOrCreateRepo(path: project.path, name: repoName)
    } else if let selected = selectedRepo {
      repo = selected
    } else if !repoPath.isEmpty {
      let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
      repo = db.findOrCreateRepo(path: repoPath, name: repoName)
    } else {
      return
    }

    guard let repo else { return }

    let trimmedBranch = branch.trimmingCharacters(in: .whitespaces)
    let trimmedName = name.trimmingCharacters(in: .whitespaces)

    _ = db.createWorkstream(
      repoId: repo.id,
      branch: trimmedBranch,
      name: trimmedName.isEmpty ? nil : trimmedName
    )

    onSave()
    dismiss()
  }
}

// MARK: - RepoSource Extension

extension CreateWorkstreamSheet.RepoSource {
  var icon: String {
    switch self {
    case .sessions: "clock.arrow.circlepath"
    case .existing: "folder"
    case .browse: "plus.rectangle.on.folder"
    }
  }

  var label: String {
    switch self {
    case .sessions: "Recent"
    case .existing: "Repos"
    case .browse: "Browse"
    }
  }
}

// MARK: - Project Row

struct ProjectRow: View {
  let project: CreateWorkstreamSheet.RecentProject
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Selection indicator
        ZStack {
          Circle()
            .strokeBorder(isSelected ? Color.accent : Color.surfaceBorder, lineWidth: 1.5)
            .frame(width: 18, height: 18)
          if isSelected {
            Circle()
              .fill(Color.accent)
              .frame(width: 10, height: 10)
          }
        }

        // Project info
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text(project.name)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Color.textPrimary)

            if let branch = project.branch, !branch.isEmpty {
              HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                  .font(.system(size: 9))
                Text(branch)
                  .font(.system(size: 10, weight: .medium, design: .monospaced))
              }
              .foregroundStyle(Color.gitBranch)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.gitBranch.opacity(0.1))
              .clipShape(Capsule())
            }
          }

          Text(shortenPath(project.path))
            .font(.system(size: 10))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
        }

        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(isSelected ? Color.accent.opacity(0.08) : Color.backgroundTertiary.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isSelected ? Color.accent.opacity(0.4) : Color.surfaceBorder.opacity(0.5), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private func shortenPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
      return "~" + path.dropFirst(home.count)
    }
    return path
  }
}

// MARK: - Repo Row

struct RepoRow: View {
  let repo: Repo
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Selection indicator
        ZStack {
          Circle()
            .strokeBorder(isSelected ? Color.accent : Color.surfaceBorder, lineWidth: 1.5)
            .frame(width: 18, height: 18)
          if isSelected {
            Circle()
              .fill(Color.accent)
              .frame(width: 10, height: 10)
          }
        }

        // Repo info
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Image(systemName: "folder.fill")
              .font(.system(size: 11))
              .foregroundStyle(Color.textTertiary)
            Text(repo.name)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
          }

          Text(shortenPath(repo.path))
            .font(.system(size: 10))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
        }

        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(isSelected ? Color.accent.opacity(0.08) : Color.backgroundTertiary.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isSelected ? Color.accent.opacity(0.4) : Color.surfaceBorder.opacity(0.5), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private func shortenPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
      return "~" + path.dropFirst(home.count)
    }
    return path
  }
}

// MARK: - Archived Workstreams Section

struct ArchivedWorkstreamsSection: View {
  var onSelectSession: ((String) -> Void)? = nil

  @State private var workstreams: [Workstream] = []
  @State private var repos: [String: Repo] = [:]
  @State private var selectedWorkstream: Workstream?
  @State private var isExpanded = false

  private let db = DatabaseManager.shared

  var body: some View {
    if !workstreams.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        // Header
        Button {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            isExpanded.toggle()
          }
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.tertiary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))

            Image(systemName: "archivebox")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(Color.textTertiary)

            Text("Archived")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.secondary)

            Text("\(workstreams.count)")
              .font(.system(size: 11, weight: .medium, design: .rounded))
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())

            Spacer()
          }
          .padding(.vertical, 8)
          .padding(.horizontal, 14)
          .background(
            Color.backgroundTertiary.opacity(0.3),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
        }
        .buttonStyle(.plain)

        // Content
        if isExpanded {
          VStack(spacing: 6) {
            ForEach(workstreams, id: \.id) { workstream in
              ArchivedWorkstreamRow(
                workstream: workstream,
                repo: repos[workstream.repoId],
                onSelect: { selectedWorkstream = workstream }
              )
            }
          }
          .padding(.top, 10)
        }
      }
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
    }
  }

  private func loadData() {
    workstreams = db.fetchArchivedWorkstreams()
    let allRepos = db.fetchRepos()
    repos = Dictionary(uniqueKeysWithValues: allRepos.map { ($0.id, $0) })
  }
}

// MARK: - Archived Workstream Row

struct ArchivedWorkstreamRow: View {
  let workstream: Workstream
  let repo: Repo?
  let onSelect: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Archive indicator
        Image(systemName: "archivebox.fill")
          .font(.system(size: 10))
          .foregroundStyle(Color.textTertiary)
          .frame(width: 20)

        // Branch + ticket info
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            // Branch name
            HStack(spacing: 5) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(Color.gitBranch.opacity(0.6))
              Text(workstream.branch)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            // Ticket badge
            if let origin = workstream.originLabel {
              Text(origin)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.serverLinear.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.serverLinear.opacity(0.08), in: Capsule())
            }
          }

          // Stats row
          HStack(spacing: 10) {
            // Sessions
            HStack(spacing: 4) {
              Image(systemName: "cpu")
                .font(.system(size: 9))
              Text("\(workstream.sessionCount)")
                .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.quaternary)

            // Last activity
            if let lastActivity = workstream.lastActivityAt {
              Text(lastActivity.relativeFormatted)
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            }
          }
        }

        Spacer()

        // Stage badge (dimmed)
        HStack(spacing: 5) {
          Image(systemName: workstream.stageIcon)
            .font(.system(size: 10, weight: .medium))
          Text(workstream.stage.displayName)
            .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(workstream.stage.color.opacity(0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(workstream.stage.color.opacity(0.08), in: Capsule())

        // Repo badge
        if let repo = repo {
          Text(repo.name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.surfaceHover.opacity(0.5), in: Capsule())
        }
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(isHovering ? Color.surfaceSelected.opacity(0.5) : Color.backgroundTertiary.opacity(0.3))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.surfaceBorder.opacity(isHovering ? 0.2 : 0.1), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu {
      Button {
        DatabaseManager.shared.unarchiveWorkstream(workstream.id)
      } label: {
        Label("Unarchive", systemImage: "archivebox.fill")
      }

      Divider()

      Button {
        DatabaseManager.shared.updateWorkstreamStage(workstream.id, to: .merged)
      } label: {
        Label("Complete", systemImage: "checkmark.circle")
      }

      Button {
        DatabaseManager.shared.updateWorkstreamStage(workstream.id, to: .closed)
      } label: {
        Label("Close", systemImage: "xmark.circle")
      }

      Divider()

      if let repo = repo {
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
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 20) {
    ActiveWorkstreamsSection()
  }
  .padding(24)
  .background(Color.backgroundPrimary)
  .frame(width: 800)
}
