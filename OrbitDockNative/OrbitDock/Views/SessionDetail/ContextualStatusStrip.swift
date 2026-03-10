//
//  ContextualStatusStrip.swift
//  OrbitDock
//

import SwiftUI

enum ContextualStatusStripPresentation {
  static func fillColor(for percent: Double) -> Color {
    if percent >= 90 { return Color(red: 1.0, green: 0.4, blue: 0.4) }
    if percent >= 70 { return Color(red: 1.0, green: 0.7, blue: 0.3) }
    return Color.accent
  }

  static func changeColor(_ type: FileChangeType) -> Color {
    switch type {
      case .added: Color(red: 0.4, green: 0.95, blue: 0.5)
      case .deleted: Color(red: 1.0, green: 0.5, blue: 0.5)
      case .renamed, .modified: Color.accent
    }
  }
}

struct ContextualStatusStrip: View {
  let sessionId: String
  @Binding var layoutConfig: LayoutConfiguration
  @Binding var selectedCommentIds: Set<String>
  var onNavigateToComment: ((ServerReviewComment) -> Void)?
  var onSendReview: (() -> Void)?

  @Environment(SessionStore.self) private var serverState

  @State private var showPlanPopover = false
  @State private var showChangesPopover = false
  @State private var showContextPopover = false

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  private var stripState: SessionDetailStatusStripState {
    SessionDetailStatusStripPlanner.state(
      steps: obs.getPlanSteps(),
      diff: obs.diff,
      reviewComments: obs.reviewComments,
      tokenUsage: obs.tokenUsage,
      snapshotKind: obs.tokenUsageSnapshotKind,
      provider: obs.provider
    )
  }

  var body: some View {
    HStack(spacing: Spacing.xs) {
      if let plan = stripState.plan {
        planPill(plan)
      }

      if let changes = stripState.changes {
        changesPill(changes)
      }

      if let context = stripState.context {
        contextPill(context)
      }
    }
    .animation(Motion.gentle, value: stripState)
  }

  private func planPill(_ state: SessionDetailPlanPillState) -> some View {
    let steps = obs.getPlanSteps() ?? []

    return Button {
      showPlanPopover.toggle()
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "list.bullet.clipboard")
          .font(.system(size: TypeScale.micro, weight: .semibold))
        Text(state.badgeText)
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
      }
      .foregroundStyle(state.isComplete ? Color.feedbackPositive : Color.accent)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        (state.isComplete ? Color.feedbackPositive : Color.accent).opacity(OpacityTier.subtle),
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

  private func changesPill(_ state: SessionDetailChangesPillState) -> some View {
    Button {
      showChangesPopover.toggle()
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "doc.badge.plus")
          .font(.system(size: TypeScale.micro, weight: .semibold))
        Text(state.badgeText)
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
        if state.openCommentCount > 0 {
          Text("· \(state.openCommentCount) open")
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
        diff: obs.diff,
        reviewComments: obs.reviewComments,
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

  private func contextPill(_ state: SessionDetailContextPillState) -> some View {
    Button {
      showContextPopover.toggle()
    } label: {
      HStack(spacing: Spacing.xs) {
        ZStack {
          Circle()
            .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
            .frame(width: 10, height: 10)
          Circle()
            .trim(from: 0, to: state.fillPercent / 100)
            .stroke(ContextualStatusStripPresentation.fillColor(for: state.fillPercent), lineWidth: 2)
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(-90))
        }
        Text(String(format: "%.0f%%", state.fillPercent))
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
      }
      .foregroundStyle(ContextualStatusStripPresentation.fillColor(for: state.fillPercent))
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        ContextualStatusStripPresentation.fillColor(for: state.fillPercent).opacity(OpacityTier.subtle),
        in: Capsule()
      )
    }
    .buttonStyle(.plain)
    .help("Context usage")
    .popover(isPresented: $showContextPopover, arrowEdge: .bottom) {
      ContextPopoverContent(sessionId: sessionId)
        .frame(width: 320, height: 360)
    }
  }
}
