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
  let onClose: () -> Void
  @Binding var railPreset: RailPreset
  @Binding var selectedSkills: Set<String>
  @Binding var selectedCommentIds: Set<String>
  var onOpenReview: (() -> Void)? = nil
  var onNavigateToSession: ((String) -> Void)? = nil
  var onNavigateToComment: ((ServerReviewComment) -> Void)? = nil
  var onSendReview: (() -> Void)? = nil

  @Environment(ServerAppState.self) private var serverState
  @Environment(AttentionService.self) private var attentionService

  // Section expansion state
  @State private var expandPlan = true
  @State private var expandChanges = false
  @State private var expandServers = false
  @State private var expandSkills = false
  @State private var expandComments = false

  private var plan: [Session.PlanStep]? {
    serverState.session(sessionId).getPlanSteps()
  }

  private var diff: String? {
    serverState.session(sessionId).diff
  }

  private var skills: [ServerSkillMetadata] {
    serverState.session(sessionId).skills.filter { $0.enabled }
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
    !skills.isEmpty
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

  private var hasAnyContent: Bool {
    hasPlan || hasDiff || hasMcp || hasSkills || hasComments
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
        currentSessionId: sessionId,
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
              CollapsibleSection(
                title: "Skills",
                icon: "bolt.fill",
                isExpanded: $expandSkills,
                badge: "\(skills.count)"
              ) {
                SkillsTab(sessionId: sessionId, selectedSkills: $selectedSkills)
                  .onAppear { fetchSkillsIfNeeded() }
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
    HStack(spacing: 8) {
      // Preset picker (segmented icon buttons)
      HStack(spacing: 2) {
        ForEach(RailPreset.allCases, id: \.self) { preset in
          presetButton(preset)
        }
      }
      .padding(2)
      .background(Color.backgroundTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

      Spacer()

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .frame(width: 24, height: 24)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.backgroundSecondary)
  }

  private func presetButton(_ preset: RailPreset) -> some View {
    let isSelected = railPreset == preset

    return Button {
      withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
        railPreset = preset
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: preset.icon)
          .font(.system(size: 10, weight: .medium))
        Text(preset.label)
          .font(.system(size: 10, weight: .medium))
      }
      .foregroundStyle(isSelected ? Color.accent : .secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        isSelected ? Color.accent.opacity(0.15) : Color.clear,
        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Preset Application

  private func applyPreset(_ preset: RailPreset) {
    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
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
    VStack(spacing: 12) {
      Image(systemName: "sidebar.right")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(.tertiary)

      Text("No Content Yet")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)

      Text("Plan, changes, servers, and skills will appear here as the agent works")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 24)
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
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer()

        CircularProgressView(progress: progress(steps))
          .frame(width: 14, height: 14)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

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
    .padding(.vertical, 4)
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
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer()

        HStack(spacing: 4) {
          Text("+\(totalAdds)")
            .foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.5))
          Text("−\(totalDels)")
            .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5))
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      // Compact file list (max 5, then "+N more")
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(model.files.prefix(5).enumerated()), id: \.element.id) { _, file in
          HStack(spacing: 6) {
            Circle()
              .fill(compactChangeColor(file.changeType))
              .frame(width: 5, height: 5)

            Text(file.newPath.components(separatedBy: "/").last ?? file.newPath)
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
              .lineLimit(1)

            Spacer()
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 3)
        }

        if model.files.count > 5 {
          Text("+\(model.files.count - 5) more")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
        }
      }
      .padding(.vertical, 4)

      // Open Review button
      if onOpenReview != nil {
        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.5))

        Button {
          onOpenReview?()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "doc.text.magnifyingglass")
              .font(.system(size: 10, weight: .medium))
            Text("Open Review")
              .font(.system(size: 11, weight: .medium))
          }
          .foregroundStyle(Color.accent)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
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
    HStack(alignment: .top, spacing: 10) {
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
      VStack(alignment: .leading, spacing: 2) {
        Text(step.step)
          .font(.system(size: 12))
          .foregroundStyle(textColor)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)

        Text(statusLabel)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(statusLabelColor)
      }
      .padding(.bottom, isLast ? 0 : 12)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .contentShape(Rectangle())
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step.status)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch step.status {
      case "completed":
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(Color.statusReady)

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
          .font(.system(size: 16, weight: .medium))
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
      case "completed": .statusReady.opacity(0.8)
      case "inProgress": Color.accent
      case "failed": .statusPermission
      default: .secondary.opacity(0.6)
    }
  }

  private var connectorColor: Color {
    switch step.status {
      case "completed": .statusReady.opacity(0.3)
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
          progress >= 1.0 ? Color.statusReady : Color.accent,
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

// MARK: - Preview

#Preview("With Content") {
  @Previewable @State var preset: RailPreset = .planFocused
  @Previewable @State var skills: Set<String> = []
  @Previewable @State var selectedComments: Set<String> = []
  CodexTurnSidebar(
    sessionId: "test",
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
