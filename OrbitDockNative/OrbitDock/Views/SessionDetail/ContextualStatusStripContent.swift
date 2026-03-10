import SwiftUI

struct PlanPopoverContent: View {
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

struct ChangesPopoverContent: View {
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

  private var diffSummary: SessionDetailDiffSummaryState? {
    SessionDetailDiffPlanner.changeSummary(diff)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Changes")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(.primary)
        Spacer()
        if let onOpenReview {
          Button(action: onOpenReview) {
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
          if let diff, !diff.isEmpty {
            let model = DiffModel.parse(unifiedDiff: diff)

            HStack {
              Text("\(diffSummary?.fileCount ?? 0) file\((diffSummary?.fileCount ?? 0) == 1 ? "" : "s") changed")
                .font(.system(size: TypeScale.meta, weight: .medium))
                .foregroundStyle(.secondary)
              Spacer()
              HStack(spacing: Spacing.xs) {
                Text("+\(diffSummary?.totalAdditions ?? 0)")
                  .foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.5))
                Text("−\(diffSummary?.totalDeletions ?? 0)")
                  .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5))
              }
              .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            ForEach(model.files, id: \.id) { file in
              HStack(spacing: Spacing.sm_) {
                Circle()
                  .fill(ContextualStatusStripPresentation.changeColor(file.changeType))
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
}

struct ContextPopoverContent: View {
  let sessionId: String
  @Environment(SessionStore.self) private var serverState

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Context")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(.primary)
        Spacer()
        if let usage = obs.tokenUsage, usage.contextWindow > 0 {
          let fill = contextFillPercent(usage: usage, snapshotKind: obs.tokenUsageSnapshotKind)
          Text(String(format: "%.0f%%", fill))
            .font(.system(size: TypeScale.body, weight: .bold, design: .monospaced))
            .foregroundStyle(ContextualStatusStripPresentation.fillColor(for: fill))
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Divider()

      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          if let usage = obs.tokenUsage, usage.contextWindow > 0 {
            let fill = contextFillPercent(usage: usage, snapshotKind: obs.tokenUsageSnapshotKind)

            GeometryReader { geo in
              ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                  .fill(Color.surfaceBorder.opacity(0.3))
                RoundedRectangle(cornerRadius: 3)
                  .fill(ContextualStatusStripPresentation.fillColor(for: fill))
                  .frame(width: geo.size.width * min(fill / 100, 1.0))
              }
            }
            .frame(height: 6)
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.sm)

            HStack(spacing: Spacing.md) {
              tokenStat("In", value: effectiveContextInputTokens(usage: usage, snapshotKind: obs.tokenUsageSnapshotKind))
              tokenStat("Out", value: usage.outputTokens)
              if usage.cachedTokens > 0 {
                tokenStat("Cache", value: usage.cachedTokens)
              }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
          }

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
                let deltaIn = max(Int(currentInput) - Int(prevInput), 0)

                HStack(alignment: .center, spacing: Spacing.sm) {
                  Text("#\(index + 1)")
                    .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)

                  Circle()
                    .fill(ContextualStatusStripPresentation.fillColor(for: fill))
                    .frame(width: 6, height: 6)

                  Text("+\(deltaIn)")
                    .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                  if usage.outputTokens > 0 {
                    Text("→ \(usage.outputTokens)")
                      .font(.system(size: TypeScale.micro, design: .monospaced))
                      .foregroundStyle(.secondary)
                  }

                  Spacer()

                  Text(String(format: "%.0f%%", fill))
                    .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                    .foregroundStyle(ContextualStatusStripPresentation.fillColor(for: fill))
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
              }
            }
          }
        }
        .padding(.vertical, Spacing.xs)
      }
    }
    .background(Color.backgroundSecondary)
  }

  private func contextFillPercent(
    usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) -> Double {
    guard usage.contextWindow > 0 else { return 0 }
    let input = effectiveContextInputTokens(usage: usage, snapshotKind: snapshotKind)
    return min(Double(input) / Double(usage.contextWindow) * 100, 100)
  }

  private func effectiveContextInputTokens(
    usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) -> UInt64 {
    UInt64(
      SessionTokenUsageSemantics.effectiveContextInputTokens(
        inputTokens: Int(usage.inputTokens),
        cachedTokens: Int(usage.cachedTokens),
        snapshotKind: snapshotKind,
        provider: obs.provider
      )
    )
  }

  private func tokenStat(_ label: String, value: UInt64) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(formatK(Int(value)))
        .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
        .foregroundStyle(.primary)
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  private func statLabel(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(value)
        .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
        .foregroundStyle(.primary)
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  private func formatK(_ tokens: Int) -> String {
    if tokens >= 1_000 {
      let thousands = Double(tokens) / 1_000.0
      return thousands >= 100 ? "\(Int(thousands))k" : String(format: "%.1fk", thousands)
    }
    return "\(tokens)"
  }
}

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
