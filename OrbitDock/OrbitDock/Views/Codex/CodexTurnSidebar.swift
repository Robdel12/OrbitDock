//
//  CodexTurnSidebar.swift
//  OrbitDock
//
//  Right rail with independently collapsible sections for plan,
//  changes, servers, and skills. Preset picker controls initial
//  expansion state; users can still manually toggle each section.
//

import SwiftUI

struct CodexTurnSidebar: View {
  let sessionId: String
  let sessionScopedId: String?
  let onClose: () -> Void
  @Binding var railPreset: RailPreset
  @Binding var selectedSkills: Set<String>
  @Binding var selectedCommentIds: Set<String>
  var onOpenReview: (() -> Void)?
  var onNavigateToSession: ((String) -> Void)?
  var onNavigateToComment: ((ServerReviewComment) -> Void)?
  var onSendReview: (() -> Void)?

  @Environment(ServerAppState.self) private var serverState
  @Environment(AttentionService.self) private var attentionService

  // Section expansion state
  @State private var expandPlan = true
  @State private var expandChanges = false
  @State private var expandServers = false
  @State private var expandSkills = false
  @State private var expandComments = false

  @State private var expandTokens = false

  private var plan: [Session.PlanStep]? {
    serverState.session(sessionId).getPlanSteps()
  }

  private var diff: String? {
    serverState.session(sessionId).diff
  }

  private var skills: [ServerSkillMetadata] {
    serverState.session(sessionId).skills.filter(\.enabled)
  }

  private var hasPlan: Bool {
    if let steps = plan { return !steps.isEmpty }
    return false
  }

  private var hasDiff: Bool {
    if let d = diff { return !d.isEmpty }
    return false
  }

  private var hasMcp: Bool {
    serverState.session(sessionId).hasMcpData
  }

  private var hasSkills: Bool {
    !skills.isEmpty || !serverState.session(sessionId).claudeSkillNames.isEmpty
  }

  private var reviewComments: [ServerReviewComment] {
    serverState.session(sessionId).reviewComments
  }

  private var hasComments: Bool {
    !reviewComments.isEmpty
  }

  private var openCommentCount: Int {
    reviewComments.filter { $0.status == .open }.count
  }

  private var hasTokens: Bool {
    serverState.session(sessionId).turnDiffs.contains { $0.tokenUsage != nil }
      || serverState.session(sessionId).tokenUsage?.inputTokens ?? 0 > 0
  }

  private var hasAnyContent: Bool {
    hasPlan || hasDiff || hasMcp || hasSkills || hasComments || hasTokens
  }

  var body: some View {
    VStack(spacing: 0) {
      // Rail header: preset picker + close
      railHeader

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Attention strip for cross-session urgency
      AttentionStripView(
        events: attentionService.events,
        currentSessionId: sessionScopedId ?? sessionId,
        onNavigateToSession: onNavigateToSession
      )

      if hasAnyContent {
        // Scrollable collapsible sections
        ScrollView(.vertical, showsIndicators: true) {
          VStack(spacing: 1) {
            // Plan section
            if hasPlan {
              CollapsibleSection(
                title: "Plan",
                icon: "list.bullet.clipboard",
                isExpanded: $expandPlan,
                badge: planBadge
              ) {
                planContent(steps: plan!)
              }
            }

            // Changes section
            if hasDiff {
              CollapsibleSection(
                title: "Changes",
                icon: "doc.badge.plus",
                isExpanded: $expandChanges,
                badge: diffBadge
              ) {
                diffContent(diff: diff!)
              }
            }

            // Comments section
            if hasComments {
              CollapsibleSection(
                title: "Comments",
                icon: "text.bubble",
                isExpanded: $expandComments,
                badge: openCommentCount > 0 ? "\(openCommentCount) open" : nil,
                badgeColor: .statusQuestion
              ) {
                ReviewChecklistSection(
                  comments: reviewComments,
                  selectedIds: selectedCommentIds,
                  onNavigate: { comment in
                    onNavigateToComment?(comment)
                  },
                  onToggleSelection: { comment in
                    if selectedCommentIds.contains(comment.id) {
                      selectedCommentIds.remove(comment.id)
                    } else {
                      selectedCommentIds.insert(comment.id)
                    }
                  },
                  onSendReview: onSendReview
                )
              }
            }

            // Servers section
            if hasMcp {
              CollapsibleSection(
                title: "Servers",
                icon: "puzzlepiece.extension",
                isExpanded: $expandServers
              ) {
                McpServersTab(sessionId: sessionId)
                  .onAppear { fetchMcpToolsIfNeeded() }
              }
            }

            // Skills section
            if hasSkills {
              let skillCount = skills.isEmpty
                ? serverState.session(sessionId).claudeSkillNames.count
                : skills.count
              CollapsibleSection(
                title: "Skills",
                icon: "bolt.fill",
                isExpanded: $expandSkills,
                badge: "\(skillCount)"
              ) {
                SkillsTab(sessionId: sessionId, selectedSkills: $selectedSkills)
                  .onAppear { fetchSkillsIfNeeded() }
              }
            }

            // Tokens section
            if hasTokens {
              CollapsibleSection(
                title: "Tokens",
                icon: "chart.bar",
                isExpanded: $expandTokens
              ) {
                TokenTimelineView(sessionId: sessionId)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        emptyRailState
      }
    }
    .background(Color.backgroundSecondary)
    .onAppear {
      applyPreset(railPreset)
    }
    .onChange(of: railPreset) { _, newPreset in
      applyPreset(newPreset)
    }
  }

  // MARK: - Rail Header

  private var railHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Preset picker (segmented icon buttons)
      HStack(spacing: Spacing.xxs) {
        ForEach(RailPreset.allCases, id: \.self) { preset in
          presetButton(preset)
        }
      }
      .padding(Spacing.xxs)
      .background(
        Color.backgroundTertiary.opacity(0.5),
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )

      Spacer()

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
          .frame(width: 24, height: 24)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundSecondary)
  }

  private func presetButton(_ preset: RailPreset) -> some View {
    let isSelected = railPreset == preset

    return Button {
      withAnimation(Motion.standard) {
        railPreset = preset
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: preset.icon)
          .font(.system(size: TypeScale.micro, weight: .medium))
        Text(preset.label)
          .font(.system(size: TypeScale.micro, weight: .medium))
      }
      .foregroundStyle(isSelected ? Color.accent : .secondary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        isSelected ? Color.accent.opacity(0.15) : Color.clear,
        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Preset Application

  private func applyPreset(_ preset: RailPreset) {
    withAnimation(Motion.standard) {
      expandPlan = preset.expandPlan
      expandChanges = preset.expandChanges
      expandServers = preset.expandServers
      expandSkills = preset.expandSkills
      expandComments = preset.expandComments
    }
  }

  // MARK: - Badges

  private var planBadge: String? {
    guard let steps = plan, !steps.isEmpty else { return nil }
    let completed = steps.filter(\.isCompleted).count
    return "\(completed)/\(steps.count)"
  }

  private var diffBadge: String? {
    guard let d = diff, !d.isEmpty else { return nil }
    let model = DiffModel.parse(unifiedDiff: d)
    let adds = model.files.reduce(0) { $0 + $1.stats.additions }
    let dels = model.files.reduce(0) { $0 + $1.stats.deletions }
    return "+\(adds) −\(dels)"
  }

  // MARK: - Empty State

  private var emptyRailState: some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: "sidebar.right")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(Color.textTertiary)

      Text("No Content Yet")
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(.secondary)

      Text("Plan, changes, servers, and skills will appear here as the agent works")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textTertiary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.backgroundPrimary)
  }

  // MARK: - Data Fetching

  private func fetchMcpToolsIfNeeded() {
    let hasTools = !serverState.session(sessionId).mcpTools.isEmpty
    if !hasTools {
      serverState.listMcpTools(sessionId: sessionId)
    }
  }

  private func fetchSkillsIfNeeded() {
    if skills.isEmpty {
      serverState.listSkills(sessionId: sessionId)
    }
  }

  // MARK: - Plan Content

  private func planContent(steps: [Session.PlanStep]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // Progress header
      HStack {
        Text("\(completedCount(steps))/\(steps.count) steps")
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer()

        CircularProgressView(progress: progress(steps))
          .frame(width: 14, height: 14)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
        PlanStepRow(
          step: step,
          index: index + 1,
          isLast: index == steps.count - 1
        )
      }
    }
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundPrimary)
  }

  // MARK: - Diff Content (Compact Summary)

  @ViewBuilder
  private func diffContent(diff: String) -> some View {
    let model = DiffModel.parse(unifiedDiff: diff)
    let totalAdds = model.files.reduce(0) { $0 + $1.stats.additions }
    let totalDels = model.files.reduce(0) { $0 + $1.stats.deletions }

    VStack(alignment: .leading, spacing: 0) {
      // Stats header
      HStack {
        Text("\(model.files.count) file\(model.files.count == 1 ? "" : "s") changed")
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer()

        HStack(spacing: Spacing.xs) {
          Text("+\(totalAdds)")
            .foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.5))
          Text("−\(totalDels)")
            .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5))
        }
        .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      // Compact file list (max 5, then "+N more")
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(model.files.prefix(5).enumerated()), id: \.element.id) { _, file in
          HStack(spacing: Spacing.sm_) {
            Circle()
              .fill(compactChangeColor(file.changeType))
              .frame(width: 5, height: 5)

            Text(file.newPath.components(separatedBy: "/").last ?? file.newPath)
              .font(.system(size: TypeScale.micro, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
              .lineLimit(1)

            Spacer()
          }
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.gap)
        }

        if model.files.count > 5 {
          Text("+\(model.files.count - 5) more")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.gap)
        }
      }
      .padding(.vertical, Spacing.xs)

      // Open Review button
      if onOpenReview != nil {
        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.5))

        Button {
          onOpenReview?()
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "doc.text.magnifyingglass")
              .font(.system(size: TypeScale.micro, weight: .medium))
            Text("Open Review")
              .font(.system(size: TypeScale.meta, weight: .medium))
          }
          .foregroundStyle(Color.accent)
          .frame(maxWidth: .infinity)
          .padding(.vertical, Spacing.sm)
        }
        .buttonStyle(.plain)
      }
    }
    .background(Color.backgroundPrimary)
  }

  private func compactChangeColor(_ type: FileChangeType) -> Color {
    switch type {
      case .added: Color(red: 0.4, green: 0.95, blue: 0.5)
      case .deleted: Color(red: 1.0, green: 0.5, blue: 0.5)
      case .renamed: Color.accent
      case .modified: Color.accent
    }
  }

  // MARK: - Helpers

  private func completedCount(_ steps: [Session.PlanStep]) -> Int {
    steps.filter(\.isCompleted).count
  }

  private func progress(_ steps: [Session.PlanStep]) -> Double {
    guard !steps.isEmpty else { return 0 }
    return Double(completedCount(steps)) / Double(steps.count)
  }

}

// MARK: - Plan Step Row

private struct PlanStepRow: View {
  let step: Session.PlanStep
  let index: Int
  let isLast: Bool

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.md_) {
      // Status indicator with connector line
      VStack(spacing: 0) {
        statusIcon
          .frame(width: 20, height: 20)

        if !isLast {
          Rectangle()
            .fill(connectorColor)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
        }
      }

      // Step content
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(step.step)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(textColor)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)

        Text(statusLabel)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(statusLabelColor)
      }
      .padding(.bottom, isLast ? 0 : Spacing.md)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .contentShape(Rectangle())
    .animation(Motion.gentle, value: step.status)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch step.status {
      case "completed":
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: TypeScale.large, weight: .medium))
          .foregroundStyle(Color.feedbackPositive)

      case "inProgress":
        ZStack {
          Circle()
            .stroke(Color.accent.opacity(0.3), lineWidth: 2)
          Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.accent, lineWidth: 2)
            .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .modifier(SpinningModifier())

      case "failed":
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: TypeScale.large, weight: .medium))
          .foregroundStyle(Color.statusPermission)

      default: // pending
        Circle()
          .stroke(Color.secondary.opacity(0.4), lineWidth: 2)
          .frame(width: 16, height: 16)
    }
  }

  private var textColor: Color {
    switch step.status {
      case "completed": .primary.opacity(0.6)
      case "inProgress": .primary
      case "failed": .statusPermission
      default: .secondary
    }
  }

  private var statusLabel: String {
    switch step.status {
      case "completed": "Done"
      case "inProgress": "In progress..."
      case "failed": "Failed"
      default: "Pending"
    }
  }

  private var statusLabelColor: Color {
    switch step.status {
      case "completed": .feedbackPositive.opacity(0.8)
      case "inProgress": Color.accent
      case "failed": .statusPermission
      default: .secondary.opacity(0.6)
    }
  }

  private var connectorColor: Color {
    switch step.status {
      case "completed": .feedbackPositive.opacity(0.3)
      case "inProgress": Color.accent.opacity(0.3)
      default: Color.secondary.opacity(0.2)
    }
  }
}

// MARK: - Circular Progress View

private struct CircularProgressView: View {
  let progress: Double

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.2), lineWidth: 2)

      Circle()
        .trim(from: 0, to: progress)
        .stroke(
          progress >= 1.0 ? Color.feedbackPositive : Color.accent,
          style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
    }
  }
}

// MARK: - Spinning Animation Modifier

private struct SpinningModifier: ViewModifier {
  @State private var isSpinning = false

  func body(content: Content) -> some View {
    content
      .rotationEffect(.degrees(isSpinning ? 360 : 0))
      .onAppear {
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
          isSpinning = true
        }
      }
  }
}

// MARK: - Token Timeline View

/// Per-turn token breakdown for the sidebar.
private struct TokenTimelineView: View {
  let sessionId: String
  @Environment(ServerAppState.self) private var serverState

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  private var turnDiffs: [ServerTurnDiff] {
    obs.turnDiffs
  }

  private var currentUsage: ServerTokenUsage? {
    obs.tokenUsage
  }

  private var currentSession: Session? {
    serverState.sessions.first(where: { $0.id == sessionId })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Summary header
      if let usage = currentUsage, usage.contextWindow > 0 {
        let kind = obs.tokenUsageSnapshotKind
        let fill = contextFillPercent(usage: usage, snapshotKind: kind)
        HStack {
          Text("Context")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(Color.textSecondary)
          Spacer()
          Text(String(format: "%.0f%%", fill))
            .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
            .foregroundStyle(fillColor(for: fill))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)

        // Fill bar
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
              .fill(Color.surfaceBorder.opacity(0.3))
            RoundedRectangle(cornerRadius: 3)
              .fill(fillColor(for: fill))
              .frame(width: geo.size.width * min(fill / 100, 1.0))
          }
        }
        .frame(height: 6)
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.sm)

        HStack(spacing: Spacing.md) {
          tokenStat("In", value: effectiveContextInputTokens(usage: usage, snapshotKind: kind))
          tokenStat("Out", value: usage.outputTokens)
          if usage.cachedTokens > 0 {
            tokenStat("Cache", value: usage.cachedTokens)
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.sm)
      }

      // Per-turn rows
      let diffs = turnDiffs.filter { $0.tokenUsage != nil }
      if !diffs.isEmpty {
        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.5))

        ForEach(Array(diffs.enumerated()), id: \.element.turnId) { index, td in
          if let usage = td.tokenUsage {
            let turnSnapshotKind = td.snapshotKind ?? obs.tokenUsageSnapshotKind
            let fill = contextFillPercent(usage: usage, snapshotKind: turnSnapshotKind)
            let prevInput: UInt64 = {
              guard index > 0, let prevUsage = diffs[index - 1].tokenUsage else { return 0 }
              let prevKind = diffs[index - 1].snapshotKind ?? obs.tokenUsageSnapshotKind
              return effectiveContextInputTokens(usage: prevUsage, snapshotKind: prevKind)
            }()
            let currentInput = effectiveContextInputTokens(usage: usage, snapshotKind: turnSnapshotKind)
            let delta = Int(currentInput) - Int(prevInput)

            HStack(spacing: Spacing.sm) {
              Text("T\(index + 1)")
                .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
                .frame(width: 22, alignment: .trailing)

              // Mini fill bar
              GeometryReader { geo in
                ZStack(alignment: .leading) {
                  RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(Color.surfaceBorder.opacity(0.2))
                  RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(fillColor(for: fill))
                    .frame(width: geo.size.width * min(fill / 100, 1.0))
                }
              }
              .frame(height: 4)

              Text(String(format: "%.0f%%", fill))
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(fillColor(for: fill))
                .frame(width: 32, alignment: .trailing)

              if delta > 0 {
                Text("+\(formatK(delta))")
                  .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
                  .foregroundStyle(Color.textSecondary)
              }

              Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
          }
        }
      }
    }
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundPrimary)
  }

  private func fillColor(for percent: Double) -> Color {
    if percent >= 90 { return Color(red: 1.0, green: 0.4, blue: 0.4) }
    if percent >= 70 { return Color(red: 1.0, green: 0.7, blue: 0.3) }
    return Color.accent
  }

  private func effectiveContextInputTokens(
    usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) -> UInt64 {
    switch snapshotKind {
      case .mixedLegacy:
        return usage.inputTokens + usage.cachedTokens
      case .compactionReset:
        return 0
      case .contextTurn:
        if currentSession?.provider == .claude {
          return usage.inputTokens + usage.cachedTokens
        }
        return usage.inputTokens
      case .lifetimeTotals:
        return usage.inputTokens
      case .unknown:
        if currentSession?.provider == .claude {
          return usage.inputTokens + usage.cachedTokens
        }
        return usage.inputTokens
    }
  }

  private func contextFillPercent(
    usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) -> Double {
    guard usage.contextWindow > 0 else { return 0 }
    let contextInput = effectiveContextInputTokens(usage: usage, snapshotKind: snapshotKind)
    guard contextInput > 0 else { return 0 }
    return min(Double(contextInput) / Double(usage.contextWindow) * 100, 100)
  }

  private func tokenStat(_ label: String, value: UInt64) -> some View {
    VStack(spacing: Spacing.xxs) {
      Text(formatK(Int(value)))
        .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
      Text(label)
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }

  private func formatK(_ tokens: Int) -> String {
    if tokens >= 1_000 {
      let k = Double(tokens) / 1_000.0
      return k >= 100 ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
    return "\(tokens)"
  }
}

// MARK: - Preview

#Preview("With Content") {
  @Previewable @State var preset: RailPreset = .planFocused
  @Previewable @State var skills: Set<String> = []
  @Previewable @State var selectedComments: Set<String> = []
  CodexTurnSidebar(
    sessionId: "test",
    sessionScopedId: nil,
    onClose: {},
    railPreset: $preset,
    selectedSkills: $skills,
    selectedCommentIds: $selectedComments
  )
  .environment(ServerAppState())
  .environment(AttentionService())
  .frame(width: 320, height: 500)
  .background(Color.backgroundPrimary)
}

#Preview("Empty") {
  @Previewable @State var preset: RailPreset = .planFocused
  @Previewable @State var skills: Set<String> = []
  @Previewable @State var selectedComments: Set<String> = []
  CodexTurnSidebar(
    sessionId: "empty",
    sessionScopedId: nil,
    onClose: {},
    railPreset: $preset,
    selectedSkills: $skills,
    selectedCommentIds: $selectedComments
  )
  .environment(ServerAppState())
  .environment(AttentionService())
  .frame(width: 320, height: 400)
  .background(Color.backgroundPrimary)
}
