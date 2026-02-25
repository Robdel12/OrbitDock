//
//  ProjectStreamSection.swift
//  OrbitDock
//
//  Project-first flat session layout. Groups active sessions by project directory,
//  with branches shown inline per session row. Replaces lane-based triage grouping
//  with a developer-centric project-first mental model.
//

import SwiftUI

struct ProjectStreamSection: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  let sessions: [Session]
  let onSelectSession: (String) -> Void
  var selectedIndex: Int?
  @Binding var filter: ActiveSessionWorkbenchFilter
  @Binding var sort: ActiveSessionSort
  @Binding var providerFilter: ActiveSessionProviderFilter

  private var projectGroups: [ProjectGroup] {
    Self.makeProjectGroups(from: orderedSessions, sort: sort)
  }

  private var orderedSessions: [Session] {
    Self.keyboardNavigableSessions(from: sessions, filter: filter, sort: sort, providerFilter: providerFilter)
  }

  private var sessionIndexByID: [String: Int] {
    Dictionary(uniqueKeysWithValues: orderedSessions.enumerated().map { ($1.scopedID, $0) })
  }

  private var allActiveSessions: [Session] {
    Self.sortedActiveSessions(from: sessions, sort: sort)
  }

  private var counts: ProjectStreamTriageCounts {
    ProjectStreamTriageCounts(sessions: allActiveSessions)
  }

  private var directCount: Int {
    allActiveSessions.filter(\.isDirect).count
  }

  private var passiveCount: Int {
    max(0, allActiveSessions.count - directCount)
  }

  private var claudeCount: Int {
    allActiveSessions.filter { $0.provider == .claude }.count
  }

  private var codexCount: Int {
    allActiveSessions.filter { $0.provider == .codex }.count
  }

  private var attentionSessions: [Session] {
    allActiveSessions.filter { SessionDisplayStatus.from($0).needsAttention }
  }

  private var runningSessions: [Session] {
    allActiveSessions.filter { SessionDisplayStatus.from($0) == .working }
  }

  private var readySessions: [Session] {
    allActiveSessions.filter { SessionDisplayStatus.from($0) == .reply }
  }

  private var oldestAttentionSession: Session? {
    attentionSessions.min { Self.sortDate($0) < Self.sortDate($1) }
  }

  private var oldestReadySession: Session? {
    readySessions.min { Self.sortDate($0) < Self.sortDate($1) }
  }

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var isPhoneCompact: Bool {
    layoutMode.isPhoneCompact
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader

      if projectGroups.isEmpty {
        emptyState
      } else {
        VStack(spacing: 0) {
          ForEach(projectGroups) { group in
            projectSection(group)
          }
        }
        .padding(.top, 4)
      }
    }
  }

  // MARK: - Public Ordering API

  static func keyboardNavigableSessions(
    from sessions: [Session],
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort = .status,
    providerFilter: ActiveSessionProviderFilter = .all
  ) -> [Session] {
    let active = sortedActiveSessions(from: sessions, sort: sort)
    let providerFiltered = applyProviderFilter(active, filter: providerFilter)
    let filtered = applyWorkbenchFilter(providerFiltered, filter: filter)
    let groups = makeProjectGroups(from: filtered, sort: sort)
    return groups.flatMap(\.sessions)
  }

  // MARK: - Section Header

  @ViewBuilder
  private var sectionHeader: some View {
    if isPhoneCompact {
      phoneCompactSectionHeader
    } else {
      regularSectionHeader
    }
  }

  private var regularSectionHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Conversation Operations")
          .font(.system(size: TypeScale.headline, weight: .bold))
          .foregroundStyle(.primary)
          .tracking(-0.35)

        Text("\(orderedSessions.count)")
          .font(.system(size: TypeScale.subhead, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textSecondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.surfaceHover.opacity(0.7), in: Capsule())

        if let pulse = operationsPulse {
          HStack(spacing: 4) {
            Circle()
              .fill(pulse.color)
              .frame(width: 6, height: 6)
            Text(pulse.label)
              .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
          }
          .foregroundStyle(pulse.color)
          .padding(.horizontal, 9)
          .padding(.vertical, 4)
          .background(pulse.color.opacity(0.12), in: Capsule())
        }
      }

      statusOverviewBoard

      HStack(spacing: 0) {
        sortPicker
        thinSeparator
        providerToggle
        thinSeparator

        HStack(spacing: 4) {
          if directCount > 0 || filter == .direct {
            filterChip(
              target: .direct,
              icon: "chevron.left.forwardslash.chevron.right",
              count: directCount,
              color: .providerCodex
            )
          }

          if counts.attention > 0 || filter == .attention {
            filterChip(
              target: .attention,
              icon: "exclamationmark.circle.fill",
              count: counts.attention,
              color: .statusPermission
            )
          }

          if counts.running > 0 || filter == .running {
            filterChip(
              target: .running,
              icon: "bolt.fill",
              count: counts.running,
              color: .statusWorking
            )
          }

          if counts.ready > 0 || filter == .ready {
            filterChip(
              target: .ready,
              icon: "bubble.left.fill",
              count: counts.ready,
              color: .statusReply
            )
          }
        }

        Spacer()

        if filter != .all || providerFilter != .all {
          Button {
            filter = .all
            providerFilter = .all
          } label: {
            Text("Clear")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 2)
  }

  private var phoneCompactSectionHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Active Agents")
          .font(.system(size: TypeScale.subhead, weight: .bold))
          .foregroundStyle(.primary)

        Text("\(orderedSessions.count)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Color.surfaceHover.opacity(0.6), in: Capsule())

        Spacer()

        compactFilterMenu

        if filter != .all || providerFilter != .all {
          Button {
            filter = .all
            providerFilter = .all
          } label: {
            Text("Clear")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }

      if shouldShowCompactSignalRow {
        LazyVGrid(columns: compactSignalColumns, spacing: 6) {
          if counts.attention > 0 || filter == .attention {
            compactSignalFilterChip(
              target: .attention,
              icon: "exclamationmark.circle.fill",
              title: "Needs review",
              count: counts.attention,
              color: .statusPermission
            )
          }

          if counts.running > 0 || filter == .running {
            compactSignalFilterChip(
              target: .running,
              icon: "bolt.fill",
              title: "Running",
              count: counts.running,
              color: .statusWorking
            )
          }

          if counts.ready > 0 || filter == .ready {
            compactSignalFilterChip(
              target: .ready,
              icon: "bubble.left.fill",
              title: "Ready",
              count: counts.ready,
              color: .statusReply
            )
          }

          if directCount > 0 || filter == .direct {
            compactSignalFilterChip(
              target: .direct,
              icon: "chevron.left.forwardslash.chevron.right",
              title: "Direct",
              count: directCount,
              color: .providerCodex
            )
          }

          if providerFilter != .all {
            compactProviderChip
              .gridCellColumns(2)
          }
        }
      }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 2)
  }

  private var compactSignalColumns: [GridItem] {
    [
      GridItem(.flexible(minimum: 120), spacing: 6),
      GridItem(.flexible(minimum: 120), spacing: 6),
    ]
  }

  private var shouldShowCompactSignalRow: Bool {
    counts.attention > 0 || counts.running > 0 || counts
      .ready > 0 || directCount > 0 || filter != .all || providerFilter != .all
  }

  private var operationsPulse: (label: String, color: Color)? {
    guard !orderedSessions.isEmpty else { return nil }
    if counts.attention >= 3 {
      return ("Intervene", .statusPermission)
    }
    if counts.attention > 0 {
      return ("Watch", .statusQuestion)
    }
    if counts.running > 0 {
      return ("Flowing", .statusWorking)
    }
    if counts.ready > 0 {
      return ("Awaiting Input", .statusReply)
    }
    return ("Quiet", .textTertiary)
  }

  private var statusOverviewBoard: some View {
    HStack(spacing: 10) {
      statusSignalCard(
        target: .attention,
        icon: "exclamationmark.circle.fill",
        title: "Needs Attention",
        count: counts.attention,
        subtitle: attentionNarrative,
        accent: .statusPermission
      )

      statusSignalCard(
        target: .running,
        icon: "bolt.fill",
        title: "Currently Working",
        count: counts.running,
        subtitle: runningNarrative,
        accent: .statusWorking
      )

      statusSignalCard(
        target: .ready,
        icon: "bubble.left.fill",
        title: "Ready For Reply",
        count: counts.ready,
        subtitle: readyNarrative,
        accent: .statusReply
      )

      controlSignalCard
    }
  }

  private func statusSignalCard(
    target: ActiveSessionWorkbenchFilter,
    icon: String,
    title: String,
    count: Int,
    subtitle: String,
    accent: Color
  ) -> some View {
    let isActive = filter == target

    return Button {
      filter = isActive ? .all : target
    } label: {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
          Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(accent)

          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Spacer(minLength: 4)

          Text("\(count)")
            .font(.system(size: TypeScale.title + 6, weight: .heavy, design: .rounded))
            .foregroundStyle(accent)
        }

        Text(subtitle)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(2)
          .frame(minHeight: 24, alignment: .topLeading)

        signalMeter(active: count, total: allActiveSessions.count, color: accent)

        Text(shareLabel(for: count))
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
      .background(statusCardBackground(accent: accent, isActive: isActive))
    }
    .buttonStyle(.plain)
  }

  private var controlSignalCard: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.providerCodex)

        Text("Control Mode")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        Spacer(minLength: 4)

        Button {
          filter = filter == .direct ? .all : .direct
        } label: {
          Text("\(directCount) direct")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
            .foregroundStyle(filter == .direct ? .providerCodex : Color.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
              Capsule()
                .fill((filter == .direct ? Color.providerCodex : Color.surfaceHover).opacity(0.22))
            )
        }
        .buttonStyle(.plain)
      }

      Text("\(passiveCount) passive sessions waiting for takeover")
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(2)
        .frame(minHeight: 24, alignment: .topLeading)

      signalMeter(active: directCount, total: allActiveSessions.count, color: .providerCodex)

      HStack(spacing: 6) {
        providerSignalPill(
          target: .claude,
          icon: ActiveSessionProviderFilter.claude.icon,
          label: "Claude",
          count: claudeCount,
          color: .accent
        )
        providerSignalPill(
          target: .codex,
          icon: ActiveSessionProviderFilter.codex.icon,
          label: "Codex",
          count: codexCount,
          color: .providerCodex
        )
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 10)
    .frame(width: 230)
    .frame(minHeight: 108, alignment: .topLeading)
    .background(statusCardBackground(accent: .providerCodex, isActive: filter == .direct))
  }

  private func providerSignalPill(
    target: ActiveSessionProviderFilter,
    icon: String,
    label: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = providerFilter == target

    return Button {
      providerFilter = isActive ? .all : target
    } label: {
      HStack(spacing: 4) {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .bold))
        Text("\(label) \(count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
      }
      .foregroundStyle(isActive ? color : Color.textTertiary)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill((isActive ? color : Color.surfaceHover).opacity(isActive ? 0.20 : 0.40))
      )
    }
    .buttonStyle(.plain)
  }

  private func statusCardBackground(accent: Color, isActive: Bool) -> some View {
    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
      .fill(
        LinearGradient(
          colors: [
            accent.opacity(isActive ? 0.20 : 0.10),
            Color.backgroundTertiary.opacity(0.80),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
          .stroke(accent.opacity(isActive ? 0.40 : 0.16), lineWidth: isActive ? 1.3 : 1)
      )
      .shadow(color: accent.opacity(isActive ? 0.12 : 0.06), radius: isActive ? 12 : 6, y: 2)
  }

  private func signalMeter(active: Int, total: Int, color: Color) -> some View {
    let safeTotal = max(total, 1)
    let ratio = max(0, min(1, Double(active) / Double(safeTotal)))

    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(Color.surfaceHover.opacity(0.55))

        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(color.opacity(0.8))
          .frame(width: geo.size.width * ratio)
      }
    }
    .frame(height: 6)
  }

  private func shareLabel(for value: Int) -> String {
    guard !allActiveSessions.isEmpty else { return "0%" }
    let ratio = (Double(value) / Double(allActiveSessions.count)) * 100
    return "\(Int(ratio.rounded()))%"
  }

  private var attentionNarrative: String {
    guard let session = oldestAttentionSession else {
      return "No blocked conversations."
    }

    let project = sessionProjectName(session)
    let age = relativeTimestamp(for: session)
    let status = SessionDisplayStatus.from(session)

    if status == .permission, let tool = session.pendingToolName, !tool.isEmpty {
      return "\(project) waiting on \(tool.lowercased()) for \(age)."
    }
    return "\(project) waiting for input for \(age)."
  }

  private var runningNarrative: String {
    guard !runningSessions.isEmpty else {
      return "No sessions executing right now."
    }

    let grouped = Dictionary(grouping: runningSessions, by: sessionProjectName)
    if let top = grouped.max(by: { $0.value.count < $1.value.count }) {
      let noun = top.value.count == 1 ? "agent" : "agents"
      return "\(top.key) has \(top.value.count) \(noun) in motion."
    }

    return "\(runningSessions.count) active sessions in progress."
  }

  private var readyNarrative: String {
    guard let session = oldestReadySession else {
      return "No reply backlog."
    }

    return "\(sessionProjectName(session)) has been ready for \(relativeTimestamp(for: session))."
  }

  private func sessionProjectName(_ session: Session) -> String {
    session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
  }

  private func relativeTimestamp(for session: Session) -> String {
    let activity = session.lastActivityAt ?? session.startedAt ?? .distantPast
    let interval = Date().timeIntervalSince(activity)

    if interval < 60 {
      return "under a minute"
    }
    if interval < 3_600 {
      let minutes = Int(interval / 60)
      return "\(minutes)m"
    }
    if interval < 86_400 {
      let hours = Int(interval / 3_600)
      let minutes = Int(interval.truncatingRemainder(dividingBy: 3_600) / 60)
      return "\(hours)h \(minutes)m"
    }
    let days = Int(interval / 86_400)
    return "\(days)d"
  }

  // MARK: - Sort Picker

  private var sortPicker: some View {
    Menu {
      ForEach(ActiveSessionSort.allCases) { option in
        Button {
          sort = option
        } label: {
          HStack {
            Text(option.label)
            if sort == option {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: sort.icon)
          .font(.system(size: 9, weight: .semibold))
        Text(sort.label)
          .font(.system(size: 10, weight: .medium))
      }
      .foregroundStyle(Color.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.surfaceHover.opacity(0.4), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  // MARK: - Provider Toggle

  private var providerToggle: some View {
    HStack(spacing: 2) {
      ForEach(ActiveSessionProviderFilter.allCases) { option in
        Button {
          providerFilter = providerFilter == option ? .all : option
        } label: {
          HStack(spacing: 3) {
            if option != .all {
              Image(systemName: option.icon)
                .font(.system(size: 8, weight: .bold))
            }
            Text(option.label)
              .font(.system(size: 10, weight: providerFilter == option ? .bold : .medium))
          }
          .foregroundStyle(providerFilter == option ? option.color : Color.textTertiary)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(
            providerFilter == option ? option.color.opacity(OpacityTier.light) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
          )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var compactFilterMenu: some View {
    Menu {
      Section("Sort") {
        ForEach(ActiveSessionSort.allCases) { option in
          Button {
            sort = option
          } label: {
            HStack {
              Text(option.label)
              if sort == option {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }

      Section("Provider") {
        ForEach(ActiveSessionProviderFilter.allCases) { option in
          Button {
            providerFilter = option
          } label: {
            HStack {
              Text(option.label)
              if providerFilter == option {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }

      Section("State") {
        ForEach(ActiveSessionWorkbenchFilter.allCases) { option in
          Button {
            filter = option
          } label: {
            HStack {
              Text(option.title)
              if filter == option {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .font(.system(size: 11, weight: .semibold))
        Text("Filter")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundStyle((filter != .all || providerFilter != .all) ? Color.accent : Color.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.surfaceHover.opacity(0.5), in: Capsule())
    }
    .menuStyle(.borderlessButton)
  }

  private var compactProviderChip: some View {
    let color = providerFilter.color
    let isActive = providerFilter != .all

    return Button {
      providerFilter = isActive ? .all : providerFilter
    } label: {
      HStack(spacing: 5) {
        Image(systemName: providerFilter.icon)
          .font(.system(size: 9, weight: .bold))
        Text(providerFilter.label)
          .font(.system(size: 10, weight: .semibold))
        Spacer(minLength: 0)
        Text("filtered")
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .rounded))
      }
      .foregroundStyle(isActive ? color : Color.textTertiary)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill((isActive ? color : Color.surfaceHover).opacity(isActive ? 0.18 : 0.5))
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(color.opacity(isActive ? 0.25 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .help("Provider filter active")
  }

  private func compactSignalFilterChip(
    target: ActiveSessionWorkbenchFilter,
    icon: String,
    title: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = filter == target

    return Button {
      filter = isActive ? .all : target
    } label: {
      HStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 9, weight: .bold))

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: TypeScale.micro, weight: .semibold))
          Text("\(count)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
        }

        Spacer(minLength: 0)
      }
      .foregroundStyle(isActive ? color : color.opacity(0.78))
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(isActive ? color.opacity(0.18) : color.opacity(0.10))
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(color.opacity(isActive ? 0.30 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .help(target.title)
  }

  private var thinSeparator: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(0.2))
      .frame(width: 1, height: 14)
      .padding(.horizontal, 8)
  }

  private func filterChip(
    target: ActiveSessionWorkbenchFilter,
    icon: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = filter == target

    return Button {
      filter = filter == target ? .all : target
    } label: {
      HStack(spacing: 4) {
        Image(systemName: icon)
          .font(.system(size: 9, weight: .bold))
        Text("\(count)")
          .font(.system(size: 10, weight: .bold, design: .rounded))
      }
      .foregroundStyle(isActive ? color : color.opacity(0.75))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(isActive ? color.opacity(0.20) : color.opacity(0.08))
          .overlay(
            Capsule()
              .stroke(color.opacity(isActive ? 0.30 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .help(target.title)
  }

  // MARK: - Project Section

  private func projectSection(_ group: ProjectGroup) -> some View {
    let sharedBranch = group.sharedBranch
    let projectSignals = projectSignalCounts(for: group.sessions)

    return VStack(alignment: .leading, spacing: 0) {
      // Project divider rule
      Rectangle()
        .fill(Color.surfaceBorder.opacity(0.2))
        .frame(height: 1)
        .padding(.horizontal, 4)
        .padding(.top, 10)

      // Project header
      Group {
        if isPhoneCompact {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Text(group.projectName)
                .font(.system(size: TypeScale.subhead, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

              // Shared branch — shown here when all sessions are on the same branch
              if let branch = sharedBranch {
                Text(branch.count > 22 ? String(branch.prefix(20)) + "…" : branch)
                  .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                  .foregroundStyle(Color.gitBranch.opacity(0.7))
                  .lineLimit(1)
              }

              Text("\(group.sessions.count) \(group.sessions.count == 1 ? "agent" : "agents")")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.textQuaternary)

              Spacer()
            }

            if projectSignals.attention > 0 || projectSignals.running > 0 || projectSignals.ready > 0 || projectSignals
              .direct > 0
            {
              HStack(spacing: 5) {
                if projectSignals.attention > 0 {
                  projectSignalChip(
                    icon: "exclamationmark.circle.fill",
                    count: projectSignals.attention,
                    color: .statusPermission
                  )
                }

                if projectSignals.running > 0 {
                  projectSignalChip(
                    icon: "bolt.fill",
                    count: projectSignals.running,
                    color: .statusWorking
                  )
                }

                if projectSignals.ready > 0 {
                  projectSignalChip(
                    icon: "bubble.left.fill",
                    count: projectSignals.ready,
                    color: .statusReply
                  )
                }

                if projectSignals.direct > 0 {
                  projectSignalChip(
                    icon: "chevron.left.forwardslash.chevron.right",
                    count: projectSignals.direct,
                    color: .providerCodex
                  )
                }
              }
            }
          }
        } else {
          HStack(spacing: 8) {
            Text(group.projectName)
              .font(.system(size: TypeScale.large, weight: .bold))
              .foregroundStyle(.primary)

            // Shared branch — shown here when all sessions are on the same branch
            if let branch = sharedBranch {
              Text(branch.count > 28 ? String(branch.prefix(26)) + "…" : branch)
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.gitBranch.opacity(0.7))
            }

            Text("\(group.sessions.count) \(group.sessions.count == 1 ? "agent" : "agents")")
              .font(.system(size: 10, weight: .medium, design: .rounded))
              .foregroundStyle(Color.textQuaternary)

            if projectSignals.attention > 0 {
              projectSignalChip(
                icon: "exclamationmark.circle.fill",
                count: projectSignals.attention,
                color: .statusPermission
              )
            }

            if projectSignals.running > 0 {
              projectSignalChip(
                icon: "bolt.fill",
                count: projectSignals.running,
                color: .statusWorking
              )
            }

            if projectSignals.ready > 0 {
              projectSignalChip(
                icon: "bubble.left.fill",
                count: projectSignals.ready,
                color: .statusReply
              )
            }

            if projectSignals.direct > 0 {
              projectSignalChip(
                icon: "chevron.left.forwardslash.chevron.right",
                count: projectSignals.direct,
                color: .providerCodex
              )
            }

            Spacer()

            if group.totalTokens > 0 {
              Text(formatTokens(group.totalTokens))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
            }
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 14)
      .padding(.bottom, 4)

      // Session rows
      VStack(spacing: 2) {
        ForEach(group.sessions, id: \.scopedID) { session in
          let rowIndex = sessionIndexByID[session.scopedID]
          let isSelected = rowIndex == selectedIndex

          FlatSessionRow(
            session: session,
            onSelect: { onSelectSession(session.scopedID) },
            isSelected: isSelected,
            hideBranch: sharedBranch != nil
          )
          .flatSessionScrollID(rowIndex)
        }
      }
    }
  }

  private func projectSignalCounts(for sessions: [Session]) -> ProjectStatusCounts {
    var counts = ProjectStatusCounts()
    for session in sessions {
      let status = SessionDisplayStatus.from(session)
      switch status {
        case .permission, .question:
          counts.attention += 1
        case .working:
          counts.running += 1
        case .reply:
          counts.ready += 1
        case .ended:
          break
      }
      if session.isDirect {
        counts.direct += 1
      }
    }
    return counts
  }

  private func projectSignalChip(icon: String, count: Int, color: Color) -> some View {
    HStack(spacing: 3) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
      Text("\(count)")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(color.opacity(0.10), in: Capsule())
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(Color.backgroundTertiary)
          .frame(width: 50, height: 50)

        Image(systemName: "cpu")
          .font(.system(size: 20, weight: .light))
          .foregroundStyle(Color.textTertiary)
      }

      VStack(spacing: 4) {
        if filter != .all {
          Text("No \(filter.title) Sessions")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
          Text("Try a different filter or clear the current one.")
            .font(.system(size: 11))
            .foregroundStyle(Color.textTertiary)
        } else {
          Text("No Active Sessions")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.textSecondary)

          Text("Start an AI coding session to see it here.")
            .font(.system(size: 11))
            .foregroundStyle(Color.textTertiary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
  }

  // MARK: - Data Builders

  private static func sortedActiveSessions(from sessions: [Session], sort: ActiveSessionSort = .status) -> [Session] {
    sessions
      .filter(\.isActive)
      .sorted { lhs, rhs in
        switch sort {
          case .status:
            let lhsPriority = statusPriority(SessionDisplayStatus.from(lhs))
            let rhsPriority = statusPriority(SessionDisplayStatus.from(rhs))
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return sortDate(lhs) > sortDate(rhs)

          case .recent:
            return sortDate(lhs) > sortDate(rhs)

          case .tokens:
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return sortDate(lhs) > sortDate(rhs)

          case .cost:
            if lhs.totalCostUSD != rhs.totalCostUSD { return lhs.totalCostUSD > rhs.totalCostUSD }
            return sortDate(lhs) > sortDate(rhs)
        }
      }
  }

  private static func applyProviderFilter(_ sessions: [Session], filter: ActiveSessionProviderFilter) -> [Session] {
    switch filter {
      case .all: sessions
      case .claude: sessions.filter { $0.provider == .claude }
      case .codex: sessions.filter { $0.provider == .codex }
    }
  }

  private static func applyWorkbenchFilter(_ sessions: [Session], filter: ActiveSessionWorkbenchFilter) -> [Session] {
    switch filter {
      case .all: sessions
      case .direct: sessions.filter(\.isDirect)
      case .attention: sessions.filter { SessionDisplayStatus.from($0).needsAttention }
      case .running: sessions.filter { SessionDisplayStatus.from($0) == .working }
      case .ready: sessions.filter { SessionDisplayStatus.from($0) == .reply }
    }
  }

  static func makeProjectGroups(from sessions: [Session], sort: ActiveSessionSort = .status) -> [ProjectGroup] {
    // Merge subdirectory paths into their parent project.
    // e.g., sessions in /foo/bar and /foo/bar/sub both group under /foo/bar.
    // But don't merge into overly generic parent paths like ~/Developer.
    let pathsByEndpointScope = Dictionary(grouping: sessions) { $0.endpointId?.uuidString ?? "single-endpoint" }
      .mapValues { Set($0.map(\.projectPath)) }
    let canonicalPath: (Session) -> String = { session in
      let path = session.projectPath
      let endpointScope = session.endpointId?.uuidString ?? "single-endpoint"
      let allPaths = pathsByEndpointScope[endpointScope] ?? []
      // If this path is a subdirectory of another session's path, merge up
      // Only merge into candidates that look like actual project dirs (4+ components)
      // e.g., /Users/name/Developer/project — not /Users/name/Developer
      for candidate in allPaths where candidate != path {
        let candidateComponents = candidate.components(separatedBy: "/").filter { !$0.isEmpty }
        if path.hasPrefix(candidate + "/"), candidateComponents.count >= 4 {
          return candidate
        }
      }
      return path
    }

    let grouped = Dictionary(grouping: sessions) { session in
      let path = canonicalPath(session)
      let endpointScope = session.endpointId?.uuidString ?? "single-endpoint"
      return "\(endpointScope)::\(path)"
    }

    return grouped.compactMap { _, projectSessions in
      guard let first = projectSessions.first else { return nil }
      let sorted = projectSessions.sorted { lhs, rhs in
        switch sort {
          case .status:
            let lhsPriority = statusPriority(SessionDisplayStatus.from(lhs))
            let rhsPriority = statusPriority(SessionDisplayStatus.from(rhs))
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return sortDate(lhs) > sortDate(rhs)
          case .recent:
            return sortDate(lhs) > sortDate(rhs)
          case .tokens:
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return sortDate(lhs) > sortDate(rhs)
          case .cost:
            if lhs.totalCostUSD != rhs.totalCostUSD { return lhs.totalCostUSD > rhs.totalCostUSD }
            return sortDate(lhs) > sortDate(rhs)
        }
      }

      let path = first.projectPath
      let projectName = first.projectName ?? path.components(separatedBy: "/").last ?? "Unknown"
      let endpointScope = first.endpointId?.uuidString ?? "single-endpoint"
      let groupKey = "\(endpointScope)::\(path)"

      return ProjectGroup(
        groupKey: groupKey,
        projectPath: path,
        projectName: projectName,
        endpointName: first.endpointName,
        sessions: sorted,
        totalCost: sorted.reduce(0) { $0 + $1.totalCostUSD },
        totalTokens: sorted.reduce(0) { $0 + $1.totalTokens },
        latestActivityAt: sorted.compactMap { sortDate($0) }.max() ?? .distantPast
      )
    }
    .sorted { lhs, rhs in
      // Project groups are always alphabetical — they're spatial anchors.
      // Only sessions within groups reorder based on the active sort/filter.
      let nameOrder = lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName)
      if nameOrder != .orderedSame {
        return nameOrder == .orderedAscending
      }
      let endpointOrder = (lhs.endpointName ?? "").localizedCaseInsensitiveCompare(rhs.endpointName ?? "")
      if endpointOrder != .orderedSame {
        return endpointOrder == .orderedAscending
      }
      return lhs.projectPath.localizedCaseInsensitiveCompare(rhs.projectPath) == .orderedAscending
    }
  }

  private static func statusPriority(_ status: SessionDisplayStatus) -> Int {
    switch status {
      case .permission: 0
      case .question: 1
      case .working: 2
      case .reply: 3
      case .ended: 4
    }
  }

  private static func sortDate(_ session: Session) -> Date {
    session.lastActivityAt ?? session.startedAt ?? .distantPast
  }

  // MARK: - Formatting

  private func formatTokens(_ value: Int) -> String {
    if value <= 0 { return "" }
    if value >= 1_000_000 {
      return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fk", Double(value) / 1_000)
    }
    return "\(value)"
  }

  private func formatCost(_ value: Double) -> String {
    if value <= 0 { return "" }
    if value < 1 { return String(format: "$%.2f", value) }
    return String(format: "$%.1f", value)
  }
}

// MARK: - Project Group Model

struct ProjectGroup: Identifiable {
  let groupKey: String
  let projectPath: String
  let projectName: String
  let endpointName: String?
  let sessions: [Session]
  let totalCost: Double
  let totalTokens: Int
  let latestActivityAt: Date

  var id: String {
    groupKey
  }

  /// When all sessions share the same branch, return it for the header.
  /// Returns nil if branches differ or are missing.
  var sharedBranch: String? {
    let branches = Set(sessions.compactMap(\.branch).filter { !$0.isEmpty })
    guard branches.count == 1, let branch = branches.first else { return nil }
    return branch
  }
}

// MARK: - Triage Counts (reusable)

private struct ProjectStatusCounts {
  var attention = 0
  var running = 0
  var ready = 0
  var direct = 0
}

private struct ProjectStreamTriageCounts {
  var attention = 0
  var running = 0
  var ready = 0

  init(sessions: [Session]) {
    for session in sessions {
      let status = SessionDisplayStatus.from(session)
      switch status {
        case .permission, .question: attention += 1
        case .working: running += 1
        case .reply: ready += 1
        case .ended: break
      }
    }
  }
}

// MARK: - Scroll ID

extension View {
  @ViewBuilder
  func flatSessionScrollID(_ index: Int?) -> some View {
    if let index {
      self.id("active-session-\(index)")
    } else {
      self
    }
  }
}

// Filter types defined in ActiveSessionsSection.swift

// MARK: - Preview

#Preview {
  @Previewable @State var filter: ActiveSessionWorkbenchFilter = .all
  @Previewable @State var sort: ActiveSessionSort = .status
  @Previewable @State var providerFilter: ActiveSessionProviderFilter = .all

  ScrollView {
    ProjectStreamSection(
      sessions: [
        Session(
          id: "1",
          projectPath: "/Users/dev/claude-dashboard",
          projectName: "claude-dashboard",
          branch: "main",
          model: "claude-opus-4-5-20251101",
          summary: "Refactoring layout",
          status: .active,
          workStatus: .working,
          startedAt: Date().addingTimeInterval(-2_460),
          totalTokens: 7_600,
          totalCostUSD: 2.50
        ),
        Session(
          id: "2",
          projectPath: "/Users/dev/claude-dashboard",
          projectName: "claude-dashboard",
          branch: "main",
          model: "claude-sonnet-4-20250514",
          summary: "Running tests",
          status: .active,
          workStatus: .waiting,
          startedAt: Date().addingTimeInterval(-720),
          totalTokens: 2_100,
          totalCostUSD: 0.80,
          attentionReason: .awaitingQuestion,
          pendingQuestion: "Should I use the new type scale?"
        ),
        Session(
          id: "3",
          projectPath: "/Users/dev/claude-dashboard",
          projectName: "claude-dashboard",
          branch: "feat/auth",
          model: "claude-opus-4-5-20251101",
          summary: "Auth feature",
          status: .active,
          workStatus: .working,
          startedAt: Date().addingTimeInterval(-1_200),
          totalTokens: 4_100,
          totalCostUSD: 1.20
        ),
        Session(
          id: "4",
          projectPath: "/Users/dev/vizzly",
          projectName: "vizzly",
          branch: "feat/auth",
          model: "gpt-5.3",
          summary: "Implementing OAuth",
          status: .active,
          workStatus: .working,
          startedAt: Date().addingTimeInterval(-2_460),
          totalTokens: 12_500,
          totalCostUSD: 3.00,
          provider: .codex
        ),
      ],
      onSelectSession: { _ in },
      selectedIndex: 0,
      filter: $filter,
      sort: $sort,
      providerFilter: $providerFilter
    )
    .padding(24)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 900, height: 600)
}
