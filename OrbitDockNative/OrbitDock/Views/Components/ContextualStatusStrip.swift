//
//  ContextualStatusStrip.swift
//  OrbitDock
//
//  Contextual pills that appear in the header when relevant session data exists.
//  Each pill is tappable and opens a detail popover (or sheet on compact).
//  Replaces the persistent sidebar with on-demand information surfacing.
//

import SwiftUI

struct ContextualStatusStrip: View {
  let sessionId: String
  @Binding var layoutConfig: LayoutConfiguration
  @Binding var selectedCommentIds: Set<String>
  var onNavigateToComment: ((ServerReviewComment) -> Void)?
  var onSendReview: (() -> Void)?

  @Environment(SessionStore.self) private var serverState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var showPlanPopover = false
  @State private var showChangesPopover = false
  @State private var showContextPopover = false

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  // MARK: - Data

  private var plan: [Session.PlanStep]? {
    obs.getPlanSteps()
  }

  private var hasPlan: Bool {
    if let steps = plan { return !steps.isEmpty }
    return false
  }

  private var diff: String? {
    obs.diff
  }

  private var hasDiff: Bool {
    if let d = diff { return !d.isEmpty }
    return false
  }

  private var reviewComments: [ServerReviewComment] {
    obs.reviewComments
  }

  private var hasComments: Bool {
    !reviewComments.isEmpty
  }

  private var openCommentCount: Int {
    reviewComments.filter { $0.status == .open }.count
  }

  private var hasTokens: Bool {
    obs.turnDiffs.contains { $0.tokenUsage != nil }
      || obs.tokenUsage?.inputTokens ?? 0 > 0
  }

  var body: some View {
    HStack(spacing: Spacing.xs) {
      if hasPlan {
        planPill
      }

      if hasDiff || hasComments {
        changesPill
      }

      if hasTokens {
        contextPill
      }
    }
    .animation(Motion.gentle, value: hasPlan)
    .animation(Motion.gentle, value: hasDiff)
    .animation(Motion.gentle, value: hasComments)
    .animation(Motion.gentle, value: hasTokens)
  }

  // MARK: - Plan Pill

  private var planPill: some View {
    let steps = plan ?? []
    let completed = steps.filter(\.isCompleted).count
    let total = steps.count
    let allDone = completed == total

    return Button {
      showPlanPopover.toggle()
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "list.bullet.clipboard")
          .font(.system(size: TypeScale.micro, weight: .semibold))
        Text("\(completed)/\(total)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
      }
      .foregroundStyle(allDone ? Color.feedbackPositive : Color.accent)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        (allDone ? Color.feedbackPositive : Color.accent).opacity(OpacityTier.subtle),
        in: Capsule()
      )
    }
    .buttonStyle(.plain)
    .help("Plan progress")
    .popover(isPresented: $showPlanPopover, arrowEdge: .bottom) {
      PlanPopoverContent(steps: steps)
        .frame(width: 320, height: min(CGFloat(steps.count) * 52 + 60, 400))
    }
  }

  // MARK: - Changes Pill

  private var changesPill: some View {
    let badge: String = {
      if hasDiff, let d = diff, !d.isEmpty {
        let model = DiffModel.parse(unifiedDiff: d)
        let adds = model.files.reduce(0) { $0 + $1.stats.additions }
        let dels = model.files.reduce(0) { $0 + $1.stats.deletions }
        return "+\(adds) −\(dels)"
      }
      if hasComments {
        return "\(openCommentCount) comment\(openCommentCount == 1 ? "" : "s")"
      }
      return "Changes"
    }()

    return Button {
      showChangesPopover.toggle()
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "doc.badge.plus")
          .font(.system(size: TypeScale.micro, weight: .semibold))
        Text(badge)
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
        if hasComments, openCommentCount > 0 {
          Text("· \(openCommentCount) open")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.statusQuestion)
        }
      }
      .foregroundStyle(Color.accent)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(Color.accent.opacity(OpacityTier.subtle), in: Capsule())
    }
    .buttonStyle(.plain)
    .help("File changes")
    .popover(isPresented: $showChangesPopover, arrowEdge: .bottom) {
      ChangesPopoverContent(
        sessionId: sessionId,
        diff: diff,
        reviewComments: reviewComments,
        selectedCommentIds: $selectedCommentIds,
        onOpenReview: {
          showChangesPopover = false
          withAnimation(Motion.gentle) {
            layoutConfig = .split
          }
        },
        onNavigateToComment: { comment in
          showChangesPopover = false
          onNavigateToComment?(comment)
        },
        onSendReview: onSendReview
      )
      .frame(width: 340, height: min(400, 500))
    }
  }

  // MARK: - Context Pill

  private var contextPill: some View {
    let usage = obs.tokenUsage
    let kind = obs.tokenUsageSnapshotKind
    let fill: Double = {
      guard let u = usage, u.contextWindow > 0 else { return 0 }
      let input = effectiveContextInput(u, kind)
      return min(Double(input) / Double(u.contextWindow) * 100, 100)
    }()

    return Button {
      showContextPopover.toggle()
    } label: {
      HStack(spacing: Spacing.xs) {
        // Mini fill indicator
        ZStack {
          Circle()
            .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
            .frame(width: 10, height: 10)
          Circle()
            .trim(from: 0, to: fill / 100)
            .stroke(fillColor(for: fill), lineWidth: 2)
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(-90))
        }
        Text(String(format: "%.0f%%", fill))
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
      }
      .foregroundStyle(fillColor(for: fill))
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(fillColor(for: fill).opacity(OpacityTier.subtle), in: Capsule())
    }
    .buttonStyle(.plain)
    .help("Context usage")
    .popover(isPresented: $showContextPopover, arrowEdge: .bottom) {
      ContextPopoverContent(sessionId: sessionId)
        .frame(width: 320, height: 360)
    }
  }

  // MARK: - Helpers

  private func effectiveContextInput(_ usage: ServerTokenUsage, _ snapshotKind: ServerTokenUsageSnapshotKind) -> UInt64 {
    SessionObservable.effectiveInput(
      input: usage.inputTokens,
      cached: usage.cachedTokens,
      snapshotKind: snapshotKind,
      provider: obs.provider
    )
  }

  private func fillColor(for percent: Double) -> Color {
    if percent >= 90 { return Color(red: 1.0, green: 0.4, blue: 0.4) }
    if percent >= 70 { return Color(red: 1.0, green: 0.7, blue: 0.3) }
    return Color.accent
  }
}

// MARK: - Plan Popover

private struct PlanPopoverContent: View {
  let steps: [Session.PlanStep]

  private var completed: Int {
    steps.filter(\.isCompleted).count
  }

  private var progress: Double {
    guard !steps.isEmpty else { return 0 }
    return Double(completed) / Double(steps.count)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack {
        Text("Plan")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(.primary)
        Spacer()
        Text("\(completed)/\(steps.count) steps")
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
        CircularProgressView(progress: progress)
          .frame(width: 14, height: 14)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Divider()

      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
            PlanStepRow(
              step: step,
              index: index + 1,
              isLast: index == steps.count - 1
            )
          }
        }
        .padding(.vertical, Spacing.xs)
      }
    }
    .background(Color.backgroundSecondary)
  }
}

// MARK: - Changes Popover

private struct ChangesPopoverContent: View {
  let sessionId: String
  let diff: String?
  let reviewComments: [ServerReviewComment]
  @Binding var selectedCommentIds: Set<String>
  var onOpenReview: (() -> Void)?
  var onNavigateToComment: ((ServerReviewComment) -> Void)?
  var onSendReview: (() -> Void)?

  private var openCommentCount: Int {
    reviewComments.filter { $0.status == .open }.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack {
        Text("Changes")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(.primary)
        Spacer()
        if let onOpenReview {
          Button {
            onOpenReview()
          } label: {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: TypeScale.micro, weight: .medium))
              Text("Open Review")
                .font(.system(size: TypeScale.caption, weight: .medium))
            }
            .foregroundStyle(Color.accent)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Divider()

      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          // Diff file list
          if let d = diff, !d.isEmpty {
            let model = DiffModel.parse(unifiedDiff: d)
            let totalAdds = model.files.reduce(0) { $0 + $1.stats.additions }
            let totalDels = model.files.reduce(0) { $0 + $1.stats.deletions }

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

            ForEach(model.files, id: \.id) { file in
              HStack(spacing: Spacing.sm_) {
                Circle()
                  .fill(changeColor(file.changeType))
                  .frame(width: 5, height: 5)
                Text(file.newPath)
                  .font(.system(size: TypeScale.micro, design: .monospaced))
                  .foregroundStyle(.primary.opacity(0.8))
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer()
              }
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.gap)
            }
          }

          // Comments section
          if !reviewComments.isEmpty {
            Divider()
              .padding(.vertical, Spacing.xs)

            HStack {
              Text("Comments")
                .font(.system(size: TypeScale.meta, weight: .semibold))
                .foregroundStyle(.secondary)
              if openCommentCount > 0 {
                Text("\(openCommentCount) open")
                  .font(.system(size: TypeScale.micro, weight: .medium))
                  .foregroundStyle(Color.statusQuestion)
              }
              Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)

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
        .padding(.vertical, Spacing.xs)
      }
    }
    .background(Color.backgroundSecondary)
  }

  private func changeColor(_ type: FileChangeType) -> Color {
    switch type {
      case .added: Color(red: 0.4, green: 0.95, blue: 0.5)
      case .deleted: Color(red: 1.0, green: 0.5, blue: 0.5)
      case .renamed: Color.accent
      case .modified: Color.accent
    }
  }
}

// MARK: - Context Popover

private struct ContextPopoverContent: View {
  let sessionId: String
  @Environment(SessionStore.self) private var serverState

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }


  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack {
        Text("Context")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(.primary)
        Spacer()
        if let usage = obs.tokenUsage, usage.contextWindow > 0 {
          let kind = obs.tokenUsageSnapshotKind
          let fill = contextFillPercent(usage: usage, snapshotKind: kind)
          Text(String(format: "%.0f%%", fill))
            .font(.system(size: TypeScale.body, weight: .bold, design: .monospaced))
            .foregroundStyle(fillColor(for: fill))
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Divider()

      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          // Fill bar + stats
          if let usage = obs.tokenUsage, usage.contextWindow > 0 {
            let kind = obs.tokenUsageSnapshotKind
            let fill = contextFillPercent(usage: usage, snapshotKind: kind)

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
            .padding(.top, Spacing.sm)

            HStack(spacing: Spacing.md) {
              tokenStat("In", value: effectiveContextInputTokens(usage: usage, snapshotKind: kind))
              tokenStat("Out", value: usage.outputTokens)
              if usage.cachedTokens > 0 {
                tokenStat("Cache", value: usage.cachedTokens)
              }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
          }

          // Turn count + prompt/tool stats
          let turnCount = obs.turnDiffs.filter { $0.tokenUsage != nil }.count
          if turnCount > 0 {
            HStack(spacing: Spacing.md) {
              statLabel("Turns", value: "\(turnCount)")
              if obs.promptCount > 0 {
                statLabel("Prompts", value: "\(obs.promptCount)")
              }
              if obs.toolCount > 0 {
                statLabel("Tools", value: "\(obs.toolCount)")
              }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)
          }

          // Per-turn timeline
          let diffs = obs.turnDiffs.filter { $0.tokenUsage != nil }
          if !diffs.isEmpty {
            Divider()

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
      }
    }
    .background(Color.backgroundSecondary)
  }

  // MARK: - Helpers

  private func statLabel(_ label: String, value: String) -> some View {
    VStack(spacing: Spacing.xxs) {
      Text(value)
        .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
      Text(label)
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
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

  private func fillColor(for percent: Double) -> Color {
    if percent >= 90 { return Color(red: 1.0, green: 0.4, blue: 0.4) }
    if percent >= 70 { return Color(red: 1.0, green: 0.7, blue: 0.3) }
    return Color.accent
  }

  private func effectiveContextInputTokens(
    usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) -> UInt64 {
    SessionObservable.effectiveInput(
      input: usage.inputTokens,
      cached: usage.cachedTokens,
      snapshotKind: snapshotKind,
      provider: obs.provider
    )
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

  private func formatK(_ tokens: Int) -> String {
    if tokens >= 1_000 {
      let k = Double(tokens) / 1_000.0
      return k >= 100 ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
    return "\(tokens)"
  }
}

// MARK: - Plan Step Row (extracted from sidebar)

private struct PlanStepRow: View {
  let step: Session.PlanStep
  let index: Int
  let isLast: Bool

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.md_) {
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

      default:
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

// MARK: - Spinning Animation

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
