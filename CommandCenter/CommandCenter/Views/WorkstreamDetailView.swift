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
  var onSelectSession: ((String) -> Void)?

  @State private var sessions: [Session] = []
  @State private var tickets: [WorkstreamTicket] = []
  @State private var notes: [WorkstreamNote] = []
  @State private var showingLinkTicket = false
  @State private var showingAddNote = false

  // State flags - local copies for immediate UI updates
  @State private var activeFlags: Set<Workstream.StateFlag> = []

  @Environment(\.openURL) private var openURL
  @Environment(\.dismiss) private var dismiss

  private let db = DatabaseManager.shared

  /// Primary flag for display (most "advanced" active state)
  private var primaryFlag: Workstream.StateFlag {
    if activeFlags.contains(Workstream.StateFlag.closed) { return Workstream.StateFlag.closed }
    if activeFlags.contains(Workstream.StateFlag.merged) { return Workstream.StateFlag.merged }
    if activeFlags.contains(Workstream.StateFlag.hasApproval) { return Workstream.StateFlag.hasApproval }
    if activeFlags.contains(Workstream.StateFlag.inReview) { return Workstream.StateFlag.inReview }
    if activeFlags.contains(Workstream.StateFlag.hasOpenPR) { return Workstream.StateFlag.hasOpenPR }
    return Workstream.StateFlag.working
  }

  /// Computed workstream with loaded relations
  private var workstreamWithRelations: Workstream {
    var ws = workstream
    ws.tickets = tickets.isEmpty ? nil : tickets
    ws.notes = notes.isEmpty ? nil : notes
    ws.sessions = sessions.isEmpty ? nil : sessions
    return ws
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      // Main content
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          // Header
          header

          // Quick Actions
          actionButtons

          // Tickets Section (always show - can link tickets)
          ticketsSection

          // PR Section
          if workstream.hasPR {
            prSection
          }

          // Notes & Decisions Section
          notesSection

          // Sessions Section
          sessionsSection
        }
        .padding(20)
        .padding(.top, 20) // Extra top padding for close button
      }

      // Floating close button
      Button(action: { dismiss() }) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(Color.textTertiary)
          .frame(width: 26, height: 26)
          .background(Color.backgroundSecondary.opacity(0.9))
          .clipShape(Circle())
          .overlay(
            Circle()
              .strokeBorder(Color.surfaceBorder.opacity(0.5), lineWidth: 1)
          )
      }
      .buttonStyle(.borderless)
      .keyboardShortcut(.escape, modifiers: [])
      .help("Close (Esc)")
      .padding(16)
    }
    .background(Color.backgroundPrimary)
    .onAppear(perform: loadData)
    .sheet(isPresented: $showingLinkTicket) {
      LinkTicketSheet(workstreamId: workstream.id) {
        loadData() // Refresh after adding
      }
    }
    .sheet(isPresented: $showingAddNote) {
      AddNoteSheet(workstreamId: workstream.id) {
        loadData() // Refresh after adding
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(spacing: 0) {
      // Hero area with gradient background
      VStack(alignment: .leading, spacing: 16) {
        // Top row: State flags + Repo
        HStack(alignment: .center) {
          // Active state chips with multi-select menu
          stateSelector

          Spacer()

          // Repo badge
          if let repo {
            HStack(spacing: 5) {
              Image(systemName: "folder.fill")
                .font(.caption2)
              Text(repo.name)
                .font(.caption.weight(.medium))
            }
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.surfaceHover.opacity(0.6))
            .clipShape(Capsule())
          }
        }

        // Branch name - hero treatment
        HStack(spacing: 10) {
          Image(systemName: "arrow.triangle.branch")
            .font(.title2.weight(.medium))
            .foregroundStyle(Color.gitBranch)

          Text(workstream.branch)
            .font(.title.bold())
            .foregroundStyle(Color.textPrimary)
        }

        // Title (if different from branch)
        if workstream.displayName != workstream.branch {
          Text(workstream.displayName)
            .font(.body.weight(.medium))
            .foregroundStyle(Color.textSecondary)
            .padding(.leading, 2)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        LinearGradient(
          colors: [
            primaryFlag.color.opacity(0.08),
            Color.backgroundTertiary.opacity(0.5),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .strokeBorder(
            LinearGradient(
              colors: [
                primaryFlag.color.opacity(0.3),
                Color.surfaceBorder.opacity(0.2),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1
          )
      )

      // Stats bar - below hero
      HStack(spacing: 0) {
        statCard(icon: "cpu", value: "\(workstream.sessionCount)", label: "sessions")

        Divider()
          .frame(height: 24)
          .background(Color.surfaceBorder)

        statCard(icon: "clock", value: workstream.formattedSessionTime, label: "total time")

        Divider()
          .frame(height: 24)
          .background(Color.surfaceBorder)

        statCard(icon: "point.3.connected.trianglepath.dotted", value: "\(workstream.commitCount)", label: "commits")

        if let lastActivity = workstream.lastActivityAt {
          Spacer()
          Text("Last active \(lastActivity.relativeFormatted)")
            .font(.caption)
            .foregroundStyle(Color.textQuaternary)
            .padding(.trailing, 4)
        }
      }
      .padding(.vertical, 12)
      .padding(.horizontal, 16)
      .background(Color.backgroundSecondary.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .padding(.top, 12)
    }
  }

  private func statCard(icon: String, value: String, label: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.accent)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 1) {
        Text(value)
          .font(.subheadline.weight(.bold).monospacedDigit())
          .foregroundStyle(Color.textPrimary)
        Text(label)
          .font(.caption2)
          .foregroundStyle(Color.textTertiary)
      }
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - State Selector

  private var stateSelector: some View {
    Menu {
      // Combinable flags section
      Section("Status") {
        ForEach(Workstream.StateFlag.combinableFlags) { flag in
          Toggle(isOn: flagBinding(for: flag)) {
            Label(flag.label, systemImage: flag.icon)
          }
        }
      }

      Divider()

      // Terminal flags section
      Section("Complete") {
        ForEach(Workstream.StateFlag.terminalFlags) { flag in
          Button {
            toggleFlag(flag)
          } label: {
            HStack {
              Label(flag.label, systemImage: flag.icon)
              Spacer()
              if activeFlags.contains(flag) {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        // Show active flags as mini chips
        ForEach(Array(activeFlags).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { flag in
          HStack(spacing: 4) {
            Image(systemName: flag.icon)
              .font(.system(size: 10, weight: .semibold))
            Text(flag.label)
              .font(.system(size: 11, weight: .semibold))
          }
          .foregroundStyle(flag.color)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(
            Capsule()
              .fill(flag.color.opacity(0.2))
              .overlay(
                Capsule()
                  .strokeBorder(flag.color.opacity(0.4), lineWidth: 1)
              )
          )
        }

        // Edit indicator
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.textTertiary)
          .padding(.leading, 2)
      }
    }
    .buttonStyle(.plain)
  }

  /// Creates a binding for a specific flag to use with Toggle
  private func flagBinding(for flag: Workstream.StateFlag) -> Binding<Bool> {
    Binding(
      get: { activeFlags.contains(flag) },
      set: { _ in toggleFlag(flag) }
    )
  }

  // MARK: - Action Buttons

  private var actionButtons: some View {
    HStack(spacing: 10) {
      if let prURL = workstream.githubPRURL, let url = URL(string: prURL) {
        Button {
          openURL(url)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.pull")
            Text("View PR")
          }
          .font(.subheadline.weight(.medium))
        }
        .buttonStyle(ActionButtonStyle(color: Color.serverGitHub))
      }

      if let linearURL = workstream.linearIssueURL, let url = URL(string: linearURL) {
        Button {
          openURL(url)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "checklist")
            Text("Linear Issue")
          }
          .font(.subheadline.weight(.medium))
        }
        .buttonStyle(ActionButtonStyle(color: Color.serverLinear))
      }

      if let repo, let ghURL = repo.githubURL {
        Button {
          openURL(ghURL)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "folder.fill")
            Text("Repository")
          }
          .font(.subheadline.weight(.medium))
        }
        .buttonStyle(ActionButtonStyle(color: Color.textSecondary))
      }

      Spacer()
    }
  }

  // MARK: - Tickets Section (Multi-ticket)

  private var ticketsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeader("Linked Tickets", icon: "ticket", count: tickets.count) {
        showingLinkTicket = true
      }

      if !tickets.isEmpty {
        VStack(spacing: 8) {
          ForEach(tickets, id: \.id) { ticket in
            ticketRow(ticket)
          }
        }
      } else if workstream.hasOrigin {
        // Fallback to legacy single-ticket display
        VStack(alignment: .leading, spacing: 8) {
          if let linearId = workstream.linearIssueId {
            legacyTicketRow(
              icon: "checklist",
              color: Color.serverLinear,
              id: linearId,
              title: workstream.linearIssueTitle,
              state: workstream.linearIssueState
            )
          }

          if let issueNum = workstream.githubIssueNumber {
            legacyTicketRow(
              icon: "number",
              color: Color.serverGitHub,
              id: "#\(issueNum)",
              title: workstream.githubIssueTitle,
              state: workstream.githubIssueState
            )
          }
        }
      } else {
        // Empty state - more engaging design
        HStack(spacing: 16) {
          // Icon with subtle background
          ZStack {
            Circle()
              .fill(Color.serverLinear.opacity(0.1))
              .frame(width: 44, height: 44)
            Image(systemName: "ticket")
              .font(.system(size: 18, weight: .medium))
              .foregroundStyle(Color.serverLinear.opacity(0.6))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("No linked tickets")
              .font(.subheadline.weight(.medium))
              .foregroundStyle(Color.textSecondary)
            Text("Click + to link Linear or GitHub issues")
              .font(.caption)
              .foregroundStyle(Color.textTertiary)
          }

          Spacer()
        }
        .padding(16)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color.backgroundTertiary.opacity(0.4))
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.surfaceBorder.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
        )
      }
    }
  }

  private func ticketRow(_ ticket: WorkstreamTicket) -> some View {
    HStack(spacing: 12) {
      // Source icon
      Image(systemName: ticket.source.icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(ticket.source == .linear ? Color.serverLinear : Color.serverGitHub)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          // Ticket ID
          Text(ticket.displayId)
            .font(.headline.monospacedDigit())
            .foregroundStyle(Color.textPrimary)

          // Primary badge
          if ticket.isPrimary {
            Text("Primary")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(Color.accent)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.accent.opacity(0.15))
              .clipShape(Capsule())
          }

          // State badge
          if let state = ticket.state {
            Text(state)
              .font(.caption)
              .foregroundStyle(Color.textSecondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.surfaceHover)
              .clipShape(Capsule())
          }
        }

        // Title
        if let title = ticket.title {
          Text(title)
            .font(.subheadline)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(2)
        }
      }

      Spacer()

      // Open link
      if let urlString = ticket.url, let url = URL(string: urlString) {
        Button {
          openURL(url)
        } label: {
          Image(systemName: "arrow.up.right.square")
            .font(.system(size: 14))
            .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(12)
    .background(Color.backgroundTertiary)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func legacyTicketRow(icon: String, color: Color, id: String, title: String?, state: String?) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(color)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(id)
            .font(.headline)
            .foregroundStyle(Color.textPrimary)

          if let state {
            Text(state)
              .font(.caption)
              .foregroundStyle(Color.textSecondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.surfaceHover)
              .clipShape(Capsule())
          }
        }

        if let title {
          Text(title)
            .font(.subheadline)
            .foregroundStyle(Color.textSecondary)
        }
      }

      Spacer()
    }
    .padding(12)
    .background(Color.backgroundTertiary)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - Notes Section

  private var notesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeader("Notes & Decisions", icon: "note.text", count: notes.count) {
        showingAddNote = true
      }

      if !notes.isEmpty {
        VStack(spacing: 8) {
          ForEach(notes, id: \.id) { note in
            noteRow(note)
          }
        }
      } else {
        // Empty state - matching ticket style
        HStack(spacing: 16) {
          ZStack {
            Circle()
              .fill(Color.accent.opacity(0.1))
              .frame(width: 44, height: 44)
            Image(systemName: "note.text")
              .font(.system(size: 18, weight: .medium))
              .foregroundStyle(Color.accent.opacity(0.6))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("No notes yet")
              .font(.subheadline.weight(.medium))
              .foregroundStyle(Color.textSecondary)
            Text("Decisions, blockers, and milestones will appear here")
              .font(.caption)
              .foregroundStyle(Color.textTertiary)
          }

          Spacer()
        }
        .padding(16)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color.backgroundTertiary.opacity(0.4))
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.surfaceBorder.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
        )
      }
    }
  }

  private func noteRow(_ note: WorkstreamNote) -> some View {
    HStack(alignment: .top, spacing: 12) {
      // Type icon
      Image(systemName: note.type.icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(noteTypeColor(note.type))
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(note.type.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(noteTypeColor(note.type))

          if note.isResolved {
            Text("Resolved")
              .font(.caption2)
              .foregroundStyle(Color.statusSuccess)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.statusSuccess.opacity(0.15))
              .clipShape(Capsule())
          }

          Spacer()

          Text(note.createdAt, style: .relative)
            .font(.caption)
            .foregroundStyle(Color.textQuaternary)
        }

        Text(note.content)
          .font(.subheadline)
          .foregroundStyle(Color.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .background(Color.backgroundTertiary)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func noteTypeColor(_ type: WorkstreamNote.NoteType) -> Color {
    switch type {
      case .note: Color.textSecondary
      case .decision: Color.accent
      case .blocker: Color.statusError
      case .pivot: Color.statusWaiting
      case .milestone: Color.statusSuccess
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
      sectionHeader("Sessions", icon: "cpu", count: sessions.count)

      if sessions.isEmpty {
        // Empty state matching other sections
        HStack(spacing: 16) {
          ZStack {
            Circle()
              .fill(Color.statusWorking.opacity(0.1))
              .frame(width: 44, height: 44)
            Image(systemName: "cpu")
              .font(.system(size: 18, weight: .medium))
              .foregroundStyle(Color.statusWorking.opacity(0.6))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("No sessions yet")
              .font(.subheadline.weight(.medium))
              .foregroundStyle(Color.textSecondary)
            Text("AI sessions on this branch will appear here")
              .font(.caption)
              .foregroundStyle(Color.textTertiary)
          }

          Spacer()
        }
        .padding(16)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color.backgroundTertiary.opacity(0.4))
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.surfaceBorder.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
        )
      } else {
        VStack(spacing: 8) {
          ForEach(sessions, id: \.id) { session in
            SessionRowButton(session: session) {
              dismiss()
              onSelectSession?(session.id)
            }
          }
        }
      }
    }
  }

  // MARK: - Helpers

  private func sectionHeader(
    _ title: String,
    icon: String,
    count: Int? = nil,
    action: (() -> Void)? = nil
  ) -> some View {
    HStack(spacing: 10) {
      // Icon with subtle background
      ZStack {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.accent.opacity(0.1))
          .frame(width: 26, height: 26)
        Image(systemName: icon)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.accent)
      }

      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.textPrimary)

      if let count, count > 0 {
        Text("\(count)")
          .font(.caption.weight(.medium).monospacedDigit())
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.surfaceHover)
          .clipShape(Capsule())
      }

      Spacer()

      // Action button (e.g., "+" to add)
      if let action {
        Button(action: action) {
          Image(systemName: "plus")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.accent)
            .frame(width: 22, height: 22)
            .background(Color.accent.opacity(0.1))
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
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

  private func reviewStateColor(_ state: Workstream.ReviewState) -> Color {
    switch state {
      case .pending: Color.textTertiary
      case .changesRequested: Color.statusWaiting
      case .approved: Color.statusSuccess
    }
  }

  private func loadData() {
    // Initialize flags from workstream
    if activeFlags.isEmpty {
      var flags = Set<Workstream.StateFlag>()
      if workstream.isWorking { flags.insert(Workstream.StateFlag.working) }
      if workstream.hasOpenPR { flags.insert(Workstream.StateFlag.hasOpenPR) }
      if workstream.inReview { flags.insert(Workstream.StateFlag.inReview) }
      if workstream.hasApproval { flags.insert(Workstream.StateFlag.hasApproval) }
      if workstream.isMerged { flags.insert(Workstream.StateFlag.merged) }
      if workstream.isClosed { flags.insert(Workstream.StateFlag.closed) }
      // Ensure at least one flag
      if flags.isEmpty { flags.insert(Workstream.StateFlag.working) }
      activeFlags = flags
    }

    // Load sessions for this workstream
    let allSessions = db.fetchSessions()
    sessions = allSessions.filter { session in
      // Match by workstream_id if available, otherwise by branch
      if let wsId = session.workstreamId {
        return wsId == workstream.id
      }
      return session.branch == workstream.branch
    }

    // Load tickets and notes
    tickets = db.fetchTickets(workstreamId: workstream.id)
    notes = db.fetchNotes(workstreamId: workstream.id)
  }

  private func toggleFlag(_ flag: Workstream.StateFlag) {
    let newValue = !activeFlags.contains(flag)

    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      if flag.isTerminal && newValue {
        // Terminal flag clears all others
        activeFlags = [flag]
      } else if newValue {
        // Add flag, remove terminal flags if present
        activeFlags.remove(Workstream.StateFlag.merged)
        activeFlags.remove(Workstream.StateFlag.closed)
        activeFlags.insert(flag)
      } else {
        activeFlags.remove(flag)
        // Ensure at least one flag remains
        if activeFlags.isEmpty {
          activeFlags.insert(Workstream.StateFlag.working)
        }
      }
    }

    db.toggleWorkstreamFlag(workstream.id, flag: flag, value: newValue)
  }
}

// MARK: - Review State Extension

extension Workstream.ReviewState {
  var displayName: String {
    switch self {
      case .pending: "Pending Review"
      case .changesRequested: "Changes Requested"
      case .approved: "Approved"
    }
  }
}

// MARK: - Session Row Button (Clickable)

struct SessionRowButton: View {
  let session: Session
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        // Status indicator with glow
        ZStack {
          if session.isActive {
            Circle()
              .fill(Color.statusWorking.opacity(0.3))
              .frame(width: 16, height: 16)
          }
          Circle()
            .fill(session.isActive ? Color.statusWorking : Color.textQuaternary)
            .frame(width: 8, height: 8)
        }
        .frame(width: 16)

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

        // Duration badge
        Text(session.formattedDuration)
          .font(.caption.weight(.medium).monospacedDigit())
          .foregroundStyle(Color.textSecondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.surfaceHover.opacity(0.6))
          .clipShape(Capsule())

        // Arrow indicator
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(isHovered ? Color.accent : Color.textQuaternary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(isHovered ? Color.surfaceHover : Color.backgroundTertiary)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(
            isHovered ? Color.accent.opacity(0.3) : Color.clear,
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovered = hovering
      }
    }
  }
}

// MARK: - Action Button Style

struct ActionButtonStyle: ButtonStyle {
  var color: Color = .accent

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(color)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(color.opacity(0.1))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(color.opacity(0.2), lineWidth: 1)
      )
      .opacity(configuration.isPressed ? 0.7 : 1.0)
  }
}

// MARK: - Link Ticket Sheet

struct LinkTicketSheet: View {
  let workstreamId: String
  let onSave: () -> Void

  @State private var source: WorkstreamTicket.Source = .linear
  @State private var externalId = ""
  @State private var title = ""
  @State private var url = ""
  @State private var isPrimary = false
  @Environment(\.dismiss) private var dismiss

  private let db = DatabaseManager.shared

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Link Ticket")
          .font(.headline)
          .foregroundStyle(Color.textPrimary)
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(.plain)
          .foregroundStyle(Color.textSecondary)
      }
      .padding()
      .background(Color.backgroundSecondary)

      // Form
      VStack(alignment: .leading, spacing: 16) {
        // Source picker
        VStack(alignment: .leading, spacing: 6) {
          Text("Source")
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
          Picker("Source", selection: $source) {
            Text("Linear").tag(WorkstreamTicket.Source.linear)
            Text("GitHub Issue").tag(WorkstreamTicket.Source.githubIssue)
            Text("GitHub PR").tag(WorkstreamTicket.Source.githubPR)
          }
          .pickerStyle(.segmented)
        }

        // ID field
        VStack(alignment: .leading, spacing: 6) {
          Text(source == .linear ? "Issue ID (e.g., VIZ-123)" : "Number (e.g., 456)")
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
          TextField("", text: $externalId)
            .textFieldStyle(.roundedBorder)
        }

        // Title field
        VStack(alignment: .leading, spacing: 6) {
          Text("Title (optional)")
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
          TextField("", text: $title)
            .textFieldStyle(.roundedBorder)
        }

        // URL field
        VStack(alignment: .leading, spacing: 6) {
          Text("URL (optional)")
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
          TextField("", text: $url)
            .textFieldStyle(.roundedBorder)
        }

        // Primary toggle
        Toggle("Primary ticket for this workstream", isOn: $isPrimary)
          .font(.subheadline)
      }
      .padding()

      Spacer()

      // Save button
      HStack {
        Spacer()
        Button("Link Ticket") {
          save()
        }
        .buttonStyle(.borderedProminent)
        .disabled(externalId.isEmpty)
      }
      .padding()
      .background(Color.backgroundSecondary)
    }
    .frame(width: 400, height: 420)
    .background(Color.backgroundPrimary)
  }

  private func save() {
    // Parse the externalId based on source
    switch source {
      case .linear:
        db.addTicket(
          to: workstreamId,
          source: source,
          linearIssueId: externalId,
          title: title.isEmpty ? nil : title,
          state: nil,
          url: url.isEmpty ? nil : url,
          isPrimary: isPrimary
        )
      case .githubIssue, .githubPR:
        let number = Int(externalId.replacingOccurrences(of: "#", with: ""))
        db.addTicket(
          to: workstreamId,
          source: source,
          githubNumber: number,
          title: title.isEmpty ? nil : title,
          state: nil,
          url: url.isEmpty ? nil : url,
          isPrimary: isPrimary
        )
    }
    onSave()
    dismiss()
  }
}

// MARK: - Add Note Sheet

struct AddNoteSheet: View {
  let workstreamId: String
  let onSave: () -> Void

  @State private var noteType: WorkstreamNote.NoteType = .note
  @State private var content = ""
  @Environment(\.dismiss) private var dismiss

  private let db = DatabaseManager.shared

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Add Note")
          .font(.headline)
          .foregroundStyle(Color.textPrimary)
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(.plain)
          .foregroundStyle(Color.textSecondary)
      }
      .padding()
      .background(Color.backgroundSecondary)

      // Form
      VStack(alignment: .leading, spacing: 16) {
        // Type picker
        VStack(alignment: .leading, spacing: 6) {
          Text("Type")
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
          Picker("Type", selection: $noteType) {
            Label("Note", systemImage: "note.text").tag(WorkstreamNote.NoteType.note)
            Label("Decision", systemImage: "checkmark.seal").tag(WorkstreamNote.NoteType.decision)
            Label("Blocker", systemImage: "exclamationmark.triangle").tag(WorkstreamNote.NoteType.blocker)
            Label("Pivot", systemImage: "arrow.triangle.swap").tag(WorkstreamNote.NoteType.pivot)
            Label("Milestone", systemImage: "flag").tag(WorkstreamNote.NoteType.milestone)
          }
          .pickerStyle(.segmented)
        }

        // Content
        VStack(alignment: .leading, spacing: 6) {
          Text("Content")
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
          TextEditor(text: $content)
            .font(.body)
            .frame(minHeight: 120)
            .padding(8)
            .background(Color.backgroundTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        // Hint
        Text(noteTypeHint)
          .font(.caption)
          .foregroundStyle(Color.textTertiary)
      }
      .padding()

      Spacer()

      // Save button
      HStack {
        Spacer()
        Button("Add Note") {
          save()
        }
        .buttonStyle(.borderedProminent)
        .disabled(content.isEmpty)
      }
      .padding()
      .background(Color.backgroundSecondary)
    }
    .frame(width: 450, height: 380)
    .background(Color.backgroundPrimary)
  }

  private var noteTypeHint: String {
    switch noteType {
      case .note: "General observations or context"
      case .decision: "Important technical decisions with reasoning"
      case .blocker: "Something blocking progress"
      case .pivot: "Change in approach or direction"
      case .milestone: "Significant progress or achievement"
    }
  }

  private func save() {
    db.addNote(
      to: workstreamId,
      sessionId: nil,
      type: noteType,
      content: content
    )
    onSave()
    dismiss()
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
      totalSessionSeconds: 15_120,
      commitCount: 12,
      lastActivityAt: Date().addingTimeInterval(-3_600),
      createdAt: Date().addingTimeInterval(-86_400 * 3),
      updatedAt: Date().addingTimeInterval(-3_600)
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
