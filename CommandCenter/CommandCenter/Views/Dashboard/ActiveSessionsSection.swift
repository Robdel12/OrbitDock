//
//  ActiveSessionsSection.swift
//  OrbitDock
//
//  Triage-first dashboard:
//  state lanes -> workstream rows (project + branch) -> session rows.
//

import SwiftUI

enum ActiveSessionWorkbenchMode: String, CaseIterable, Identifiable {
  case now
  case all

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .now: "Now"
      case .all: "All"
    }
  }
}

enum ActiveSessionWorkbenchFilter: String, CaseIterable, Identifiable {
  case all
  case direct
  case attention
  case running
  case ready

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .all: "All"
      case .direct: "Direct"
      case .attention: "Attention"
      case .running: "Running"
      case .ready: "Ready"
    }
  }
}

enum ActiveSessionSort: String, CaseIterable, Identifiable {
  case status
  case recent
  case tokens
  case cost

  var id: String {
    rawValue
  }

  var label: String {
    switch self {
      case .status: "Status"
      case .recent: "Recent"
      case .tokens: "Tokens"
      case .cost: "Cost"
    }
  }

  var icon: String {
    switch self {
      case .status: "arrow.up.arrow.down"
      case .recent: "clock"
      case .tokens: "number"
      case .cost: "dollarsign"
    }
  }
}

enum ActiveSessionProviderFilter: String, CaseIterable, Identifiable {
  case all
  case claude
  case codex

  var id: String {
    rawValue
  }

  var label: String {
    switch self {
      case .all: "All"
      case .claude: "Claude"
      case .codex: "Codex"
    }
  }

  var icon: String {
    switch self {
      case .all: "circle.grid.2x2"
      case .claude: "sparkle"
      case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }

  var color: Color {
    switch self {
      case .all: .textSecondary
      case .claude: .accent
      case .codex: .providerCodex
    }
  }
}

private enum TriageLane: String, CaseIterable, Identifiable {
  case attention
  case running
  case ready

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .attention: "Needs Attention"
      case .running: "Running"
      case .ready: "Ready"
    }
  }

  var shortTitle: String {
    switch self {
      case .attention: "Attention"
      case .running: "Running"
      case .ready: "Ready"
    }
  }

  var icon: String {
    switch self {
      case .attention: "exclamationmark.circle.fill"
      case .running: "bolt.fill"
      case .ready: "bubble.left.fill"
    }
  }

  var color: Color {
    switch self {
      case .attention: .statusPermission
      case .running: .statusWorking
      case .ready: .statusReply
    }
  }

  static func from(_ status: SessionDisplayStatus) -> TriageLane? {
    switch status {
      case .permission, .question: .attention
      case .working: .running
      case .reply: .ready
      case .ended: nil
    }
  }
}

private struct TriageCounts {
  var attention = 0
  var running = 0
  var ready = 0

  init(sessions: [Session]) {
    for session in sessions {
      switch TriageLane.from(SessionDisplayStatus.from(session)) {
        case .attention: attention += 1
        case .running: running += 1
        case .ready: ready += 1
        case .none: break
      }
    }
  }
}

private struct ProviderMix: Identifiable {
  let provider: Provider
  let count: Int

  var id: String {
    provider.id
  }
}

private struct WorkstreamCluster: Identifiable {
  let id: String
  let projectPath: String
  let projectName: String
  let branchName: String
  let sessions: [Session]
  let providerMix: [ProviderMix]
  let directCount: Int
  let tokenTotal: Int
  let costTotal: Double
  let latestActivityAt: Date
  let oldestBlockedAt: Date?
}

private struct LaneSectionModel: Identifiable {
  let lane: TriageLane
  let workstreams: [WorkstreamCluster]
  let totalSessions: Int
  let totalDirect: Int

  var id: String {
    lane.id
  }
}

struct ActiveSessionsSection: View {
  let sessions: [Session]
  let onSelectSession: (String) -> Void
  var selectedIndex: Int?
  @Binding var mode: ActiveSessionWorkbenchMode
  @Binding var filter: ActiveSessionWorkbenchFilter

  private var modeScopedSessions: [Session] {
    let active = Self.sortedActiveSessions(from: sessions)
    return Self.filterSessions(active, mode: mode)
  }

  private var orderedSessions: [Session] {
    Self.keyboardNavigableSessions(from: sessions, mode: mode, filter: filter)
  }

  private var laneSections: [LaneSectionModel] {
    Self.makeLaneSections(from: orderedSessions)
  }

  private var sessionIndexByID: [String: Int] {
    Dictionary(uniqueKeysWithValues: orderedSessions.enumerated().map { ($1.id, $0) })
  }

  private var counts: TriageCounts {
    TriageCounts(sessions: modeScopedSessions)
  }

  private var directCodexCount: Int {
    modeScopedSessions.filter(\.isDirect).count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader

      if counts.attention > 0 || counts.running > 0 || counts.ready > 0 {
        quickJumpStrip
          .padding(.top, 12)
      }

      if laneSections.isEmpty {
        emptyState
      } else {
        VStack(spacing: 12) {
          ForEach(laneSections) { section in
            laneSectionCard(section)
          }
        }
        .padding(.top, 12)
      }
    }
  }

  // MARK: - Public Ordering API (used by Dashboard keyboard navigation)

  static func keyboardNavigableSessions(
    from sessions: [Session],
    mode: ActiveSessionWorkbenchMode,
    filter: ActiveSessionWorkbenchFilter
  ) -> [Session] {
    let active = sortedActiveSessions(from: sessions)
    let modeFiltered = filterSessions(active, mode: mode)
    let filtered = applyWorkbenchFilter(modeFiltered, filter: filter)
    let sections = makeLaneSections(from: filtered)

    return sections.flatMap { section in
      section.workstreams.flatMap(\.sessions)
    }
  }

  // MARK: - Header

  private var sectionHeader: some View {
    HStack(spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "cpu")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("Active Workbench")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.primary)

        Text("\(orderedSessions.count)")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.surfaceHover, in: Capsule())
      }

      Spacer()

      HStack(spacing: 8) {
        modeToggle

        if directCodexCount > 0 || filter == .direct {
          headerFilterChip(
            target: .direct,
            icon: "chevron.left.forwardslash.chevron.right",
            title: "Direct",
            count: directCodexCount,
            color: .providerCodex
          )
        }

        if counts.attention > 0 || filter == .attention {
          headerFilterChip(
            target: .attention,
            icon: "exclamationmark.circle.fill",
            title: "Attention",
            count: counts.attention,
            color: .statusPermission
          )
        }

        if counts.running > 0 || filter == .running {
          headerFilterChip(
            target: .running,
            icon: "bolt.fill",
            title: "Running",
            count: counts.running,
            color: .statusWorking
          )
        }

        if counts.ready > 0 || filter == .ready {
          headerFilterChip(
            target: .ready,
            icon: "bubble.left.fill",
            title: "Ready",
            count: counts.ready,
            color: .statusReply
          )
        }
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .background(Color.backgroundTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var modeToggle: some View {
    HStack(spacing: 2) {
      ForEach(ActiveSessionWorkbenchMode.allCases) { candidate in
        Button {
          mode = candidate
        } label: {
          Text(candidate.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(mode == candidate ? Color.accent : Color.white.opacity(0.55))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
              mode == candidate ? Color.accent.opacity(OpacityTier.light) : Color.clear,
              in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(2)
    .background(Color.backgroundSecondary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func headerFilterChip(
    target: ActiveSessionWorkbenchFilter,
    icon: String,
    title: String,
    count: Int,
    color: Color
  ) -> some View {
    let isSelected = filter == target

    return Button {
      toggleFilter(target)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 9, weight: .bold))
        Text("\(count)")
          .font(.system(size: 10, weight: .bold, design: .rounded))
        Text(title)
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundStyle(isSelected ? color : color.opacity(0.92))
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        Capsule()
          .fill(isSelected ? color.opacity(0.22) : color.opacity(0.10))
          .overlay(
            Capsule()
              .stroke(color.opacity(isSelected ? 0.32 : 0.20), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private func compactStat(icon: String, text: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .bold))
      Text(text)
        .font(.system(size: 10, weight: .semibold))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(color.opacity(0.12), in: Capsule())
  }

  private var quickJumpStrip: some View {
    HStack(spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "scope")
          .font(.system(size: 9, weight: .bold))
        Text("TRIAGE")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .tracking(0.6)
      }
      .foregroundStyle(.tertiary)

      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(Color.surfaceBorder.opacity(0.55))
        .frame(width: 1, height: 16)

      if counts.attention > 0 {
        quickJumpButton(lane: .attention, count: counts.attention)
      }

      if counts.running > 0 {
        quickJumpButton(lane: .running, count: counts.running)
      }

      if counts.ready > 0 {
        quickJumpButton(lane: .ready, count: counts.ready)
      }

      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.52))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(0.45), lineWidth: 1)
        )
    )
  }

  private func quickJumpButton(lane: TriageLane, count: Int) -> some View {
    let target = workbenchFilter(for: lane)
    let isSelected = filter == target

    return Button {
      toggleFilter(target)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: lane.icon)
          .font(.system(size: 10, weight: .bold))
        Text("\(count)")
          .font(.system(size: 11, weight: .bold, design: .rounded))
        Text(lane.shortTitle)
          .font(.system(size: 10, weight: .medium))
      }
      .foregroundStyle(isSelected ? lane.color : lane.color.opacity(0.92))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        Capsule()
          .fill(isSelected ? lane.color.opacity(0.22) : lane.color.opacity(0.12))
          .overlay(
            Capsule()
              .stroke(lane.color.opacity(isSelected ? 0.36 : 0.24), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private func workbenchFilter(for lane: TriageLane) -> ActiveSessionWorkbenchFilter {
    switch lane {
      case .attention: .attention
      case .running: .running
      case .ready: .ready
    }
  }

  private func toggleFilter(_ target: ActiveSessionWorkbenchFilter) {
    filter = filter == target ? .all : target
  }

  // MARK: - Lane Sections

  private func laneSectionCard(_ section: LaneSectionModel) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: section.lane.icon)
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(section.lane.color)

        Text(section.lane.title)
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(.primary)

        Text("\(section.totalSessions)")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(section.lane.color)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(section.lane.color.opacity(0.14), in: Capsule())

        Text("\(section.workstreams.count) \(pluralizedLabel("workstream", count: section.workstreams.count))")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.tertiary)

        if section.totalDirect > 0 {
          compactStat(icon: "terminal.fill", text: "\(section.totalDirect) direct", color: .providerCodex)
        }

        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(Color.backgroundSecondary.opacity(0.60))

      Rectangle()
        .fill(Color.surfaceBorder.opacity(0.18))
        .frame(height: 1)

      VStack(spacing: 10) {
        ForEach(section.workstreams) { workstream in
          workstreamCard(workstream, lane: section.lane)
        }
      }
      .padding(10)
    }
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.46))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(0.22), lineWidth: 1)
        )
    )
  }

  private func workstreamCard(_ workstream: WorkstreamCluster, lane: TriageLane) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Image(systemName: "folder.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text(workstream.projectName)
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        Text("•")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.tertiary)

        branchBadge(workstream.branchName)

        Text("\(workstream.sessions.count) \(pluralizedLabel("session", count: workstream.sessions.count))")
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.surfaceHover.opacity(0.6), in: Capsule())

        if workstream.directCount > 0 {
          compactStat(icon: "terminal.fill", text: "\(workstream.directCount)", color: .providerCodex)
        }

        Spacer()

        workstreamActivityBadge(workstream, lane: lane)
      }

      HStack(spacing: 8) {
        Text(shortProjectPath(workstream.projectPath))
          .font(.system(size: 9, weight: .medium, design: .monospaced))
          .foregroundStyle(.tertiary)
          .lineLimit(1)

        HStack(spacing: 6) {
          ForEach(workstream.providerMix) { mix in
            HStack(spacing: 3) {
              Image(systemName: mix.provider.icon)
                .font(.system(size: 7, weight: .bold))
              Text("\(mix.provider.displayName) \(mix.count)")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(mix.provider.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(mix.provider.accentColor.opacity(0.12), in: Capsule())
          }
        }

        Spacer()

        compactMetric(icon: "sum", text: formatTokens(workstream.tokenTotal))
        compactMetric(icon: "dollarsign", text: formatCost(workstream.costTotal))
      }

      Divider()
        .foregroundStyle(Color.surfaceBorder.opacity(0.28))

      VStack(spacing: 6) {
        ForEach(workstream.sessions) { session in
          laneSessionRow(session)
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.62))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(0.20), lineWidth: 1)
        )
    )
  }

  private func laneSessionRow(_ session: Session) -> some View {
    let rowIndex = sessionIndexByID[session.id]
    let isSelected = rowIndex == selectedIndex

    return ActiveSessionRow(
      session: session,
      onSelect: { onSelectSession(session.id) },
      onFocusTerminal: nil,
      isSelected: isSelected
    )
    .activeSessionScrollID(rowIndex)
  }

  private func branchBadge(_ branch: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 8, weight: .semibold))
      Text(branch)
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .lineLimit(1)
    }
    .foregroundStyle(Color.gitBranch.opacity(0.92))
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(
      Capsule()
        .fill(Color.gitBranch.opacity(0.10))
        .overlay(
          Capsule()
            .stroke(Color.gitBranch.opacity(0.24), lineWidth: 1)
        )
    )
  }

  @ViewBuilder
  private func workstreamActivityBadge(_ workstream: WorkstreamCluster, lane: TriageLane) -> some View {
    if lane == .attention, let oldestBlockedAt = workstream.oldestBlockedAt {
      HStack(spacing: 4) {
        Image(systemName: "hourglass.bottomhalf.filled")
          .font(.system(size: 8, weight: .semibold))
        Text("Blocked")
          .font(.system(size: 9, weight: .semibold))
        Text(oldestBlockedAt, style: .relative)
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
      }
      .foregroundStyle(Color.statusPermission)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        Capsule()
          .fill(Color.statusPermission.opacity(0.12))
          .overlay(
            Capsule()
              .stroke(Color.statusPermission.opacity(0.24), lineWidth: 1)
          )
      )
    } else {
      HStack(spacing: 4) {
        Image(systemName: "clock")
          .font(.system(size: 8, weight: .semibold))
        Text(workstream.latestActivityAt, style: .relative)
          .font(.system(size: 9, weight: .medium, design: .monospaced))
      }
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color.backgroundSecondary.opacity(0.75), in: Capsule())
    }
  }

  private func compactMetric(icon: String, text: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
      Text(text)
        .font(.system(size: 9, weight: .semibold, design: .rounded))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(
      Capsule()
        .fill(Color.backgroundSecondary.opacity(0.55))
        .overlay(
          Capsule()
            .stroke(Color.surfaceBorder.opacity(0.38), lineWidth: 1)
        )
    )
  }

  private func pluralizedLabel(_ singular: String, count: Int) -> String {
    count == 1 ? singular : "\(singular)s"
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
          .foregroundStyle(.tertiary)
      }

      VStack(spacing: 4) {
        if filter != .all {
          Text("No \(filter.title) Sessions")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
          Text("Try a different filter or clear the current one.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        } else {
          Text(mode == .now ? "No Sessions Need Action Right Now" : "No Active Sessions")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          Text(mode == .now ? "Switch to All to browse every active project." :
            "Start an AI coding session to see it here.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
  }

  // MARK: - Data Builders

  private static func sortedActiveSessions(from sessions: [Session]) -> [Session] {
    sessions
      .filter(\.isActive)
      .sorted { lhs, rhs in
        let lhsStatus = statusPriority(SessionDisplayStatus.from(lhs))
        let rhsStatus = statusPriority(SessionDisplayStatus.from(rhs))

        if lhsStatus != rhsStatus {
          return lhsStatus < rhsStatus
        }

        let lhsDate = sortDate(lhs)
        let rhsDate = sortDate(rhs)
        if lhsDate != rhsDate {
          return lhsDate > rhsDate
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
  }

  private static func filterSessions(_ sessions: [Session], mode: ActiveSessionWorkbenchMode) -> [Session] {
    switch mode {
      case .all:
        sessions
      case .now:
        sessions.filter {
          let status = SessionDisplayStatus.from($0)
          return status.needsAttention || status == .working || $0.isDirect
        }
    }
  }

  private static func applyWorkbenchFilter(_ sessions: [Session], filter: ActiveSessionWorkbenchFilter) -> [Session] {
    switch filter {
      case .all:
        sessions
      case .direct:
        sessions.filter(\.isDirect)
      case .attention:
        sessions.filter {
          let status = SessionDisplayStatus.from($0)
          return status == .permission || status == .question
        }
      case .running:
        sessions.filter { SessionDisplayStatus.from($0) == .working }
      case .ready:
        sessions.filter { SessionDisplayStatus.from($0) == .reply }
    }
  }

  private static func makeLaneSections(from sessions: [Session]) -> [LaneSectionModel] {
    let groupedByLane = Dictionary(grouping: sessions) { session in
      TriageLane.from(SessionDisplayStatus.from(session))
    }

    return TriageLane.allCases.compactMap { lane in
      guard let laneSessions = groupedByLane[lane], !laneSessions.isEmpty else {
        return nil
      }

      let groupedByWorkstream = Dictionary(grouping: laneSessions) { session in
        "\(session.projectPath)::\(branchName(for: session))"
      }

      let workstreams = groupedByWorkstream.compactMap { workstreamKey, workstreamSessions -> WorkstreamCluster? in
        guard let first = workstreamSessions.first else {
          return nil
        }

        let sortedSessions = workstreamSessions.sorted { lhs, rhs in
          let lhsStatus = statusPriority(SessionDisplayStatus.from(lhs))
          let rhsStatus = statusPriority(SessionDisplayStatus.from(rhs))

          if lhsStatus != rhsStatus {
            return lhsStatus < rhsStatus
          }

          return sortDate(lhs) > sortDate(rhs)
        }

        let providerMix = Dictionary(grouping: sortedSessions, by: \.provider)
          .map { ProviderMix(provider: $0.key, count: $0.value.count) }
          .sorted { lhs, rhs in
            if lhs.count != rhs.count {
              return lhs.count > rhs.count
            }
            return lhs.provider.displayName
              .localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
          }

        let oldestBlockedAt = sortedSessions
          .filter {
            let status = SessionDisplayStatus.from($0)
            return status == .permission || status == .question
          }
          .map { sortDate($0) }
          .min()

        let projectName = first.projectName
          ?? first.projectPath.components(separatedBy: "/").last
          ?? "Unknown"

        return WorkstreamCluster(
          id: "\(lane.rawValue)::\(workstreamKey)",
          projectPath: first.projectPath,
          projectName: projectName,
          branchName: branchName(for: first),
          sessions: sortedSessions,
          providerMix: providerMix,
          directCount: sortedSessions.filter(\.isDirect).count,
          tokenTotal: sortedSessions.reduce(0) { $0 + $1.totalTokens },
          costTotal: sortedSessions.reduce(0) { $0 + $1.totalCostUSD },
          latestActivityAt: sortedSessions.map { sortDate($0) }.max() ?? .distantPast,
          oldestBlockedAt: oldestBlockedAt
        )
      }
      .sorted { lhs, rhs in
        if lane == .attention {
          let lhsBlocked = lhs.oldestBlockedAt ?? .distantFuture
          let rhsBlocked = rhs.oldestBlockedAt ?? .distantFuture
          if lhsBlocked != rhsBlocked {
            return lhsBlocked < rhsBlocked
          }
        }

        if lhs.latestActivityAt != rhs.latestActivityAt {
          return lhs.latestActivityAt > rhs.latestActivityAt
        }

        if lhs.sessions.count != rhs.sessions.count {
          return lhs.sessions.count > rhs.sessions.count
        }

        if lhs.projectName != rhs.projectName {
          return lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName) == .orderedAscending
        }

        return lhs.branchName.localizedCaseInsensitiveCompare(rhs.branchName) == .orderedAscending
      }

      return LaneSectionModel(
        lane: lane,
        workstreams: workstreams,
        totalSessions: laneSessions.count,
        totalDirect: laneSessions.filter(\.isDirect).count
      )
    }
  }

  private static func branchName(for session: Session) -> String {
    if let branch = session.branch?.trimmingCharacters(in: .whitespacesAndNewlines),
       !branch.isEmpty
    {
      return branch
    }
    return "detached"
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

  private func shortProjectPath(_ projectPath: String) -> String {
    let parts = projectPath.split(separator: "/")
    if parts.count <= 3 {
      return projectPath
    }
    return "~/" + parts.suffix(3).joined(separator: "/")
  }

  private func formatTokens(_ value: Int) -> String {
    if value <= 0 {
      return "0"
    }
    if value >= 1_000_000 {
      return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fk", Double(value) / 1_000)
    }
    return "\(value)"
  }

  private func formatCost(_ value: Double) -> String {
    if value <= 0 {
      return "$0"
    }
    if value < 1 {
      return String(format: "$%.2f", value)
    }
    return String(format: "$%.1f", value)
  }
}

private extension View {
  @ViewBuilder
  func activeSessionScrollID(_ index: Int?) -> some View {
    if let index {
      self.id("active-session-\(index)")
    } else {
      self
    }
  }
}

// MARK: - Preview

#Preview {
  @Previewable @State var mode: ActiveSessionWorkbenchMode = .all
  @Previewable @State var filter: ActiveSessionWorkbenchFilter = .all

  ScrollView {
    VStack(spacing: 24) {
      ActiveSessionsSection(
        sessions: [
          Session(
            id: "1",
            projectPath: "/Users/developer/Developer/vizzly-cli",
            projectName: "vizzly-cli",
            branch: "main",
            model: "claude-opus-4-5-20251101",
            summary: "Building the new CLI",
            status: .active,
            workStatus: .working,
            startedAt: Date().addingTimeInterval(-8_100),
            lastActivityAt: Date().addingTimeInterval(-120),
            lastTool: "Edit"
          ),
          Session(
            id: "2",
            projectPath: "/Users/developer/Developer/vizzly-cli",
            projectName: "vizzly-cli",
            branch: "feature/auth",
            model: "gpt-5.3",
            summary: "Implementing OAuth",
            status: .active,
            workStatus: .permission,
            startedAt: Date().addingTimeInterval(-2_700),
            lastActivityAt: Date().addingTimeInterval(-1_200),
            attentionReason: .awaitingPermission,
            pendingToolName: "Bash",
            provider: .codex,
            codexIntegrationMode: .direct
          ),
          Session(
            id: "3",
            projectPath: "/Users/developer/Developer/marketing",
            projectName: "marketing",
            branch: "main",
            model: "claude-sonnet-4-20250514",
            summary: "Landing page redesign",
            status: .active,
            workStatus: .waiting,
            startedAt: Date().addingTimeInterval(-1_500),
            lastActivityAt: Date().addingTimeInterval(-900),
            attentionReason: .awaitingQuestion,
            pendingQuestion: "Should I use the editorial type scale or keep the current one?"
          ),
          Session(
            id: "4",
            projectPath: "/Users/developer/Developer/marketing",
            projectName: "marketing",
            branch: "main",
            model: "claude-haiku-3-5-20241022",
            summary: "Documentation updates",
            status: .active,
            workStatus: .waiting,
            startedAt: Date().addingTimeInterval(-720),
            lastActivityAt: Date().addingTimeInterval(-300),
            attentionReason: .awaitingReply
          ),
        ],
        onSelectSession: { _ in },
        selectedIndex: 0,
        mode: $mode,
        filter: $filter
      )

      ActiveSessionsSection(
        sessions: [],
        onSelectSession: { _ in },
        mode: $mode,
        filter: $filter
      )
    }
    .padding(24)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 1_000, height: 760)
}
