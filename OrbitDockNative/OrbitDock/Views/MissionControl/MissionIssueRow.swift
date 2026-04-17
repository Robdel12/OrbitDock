import SwiftUI

enum MissionIssueRowStyle {
  case compact // Used in overview — single line, no context menu
  case full // Used in issues tab — multi-row with context menu
}

struct MissionIssueRow: View {
  let issue: MissionIssueItem
  let missionId: String
  let endpointId: UUID
  let missionsClient: MissionsClient?
  var style: MissionIssueRowStyle = .full
  var isCompact: Bool = false
  var accentColor: Color = .accent
  var onNavigateToSession: ((String) -> Void)?
  var onRefresh: (() async -> Void)?
  var onTransitionIssue: ((String, OrchestrationState, String?) async -> Void)?

  @Environment(AppRouter.self) private var router
  @State private var actionError: String?

  var body: some View {
    Group {
      switch style {
        case .compact:
          compactBody
        case .full:
          fullBody
      }
    }
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  // MARK: - Compact Layout

  private var compactBody: some View {
    HStack(spacing: Spacing.sm) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(accentColor)
        .frame(width: EdgeBar.width)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.sm_) {
          Text(issue.identifier)
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(accentColor)

          if let prLabel = issue.prLabel {
            prBadge(prLabel)
          }

          Text(issue.title)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)

          Spacer()

          if issue.attempt > 1 {
            Text("attempt #\(issue.attempt)")
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.feedbackCaution)
          }

          Text(issue.provider.capitalized)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          Text(issue.orchestrationState.displayLabel)
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(accentColor)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(
              accentColor.opacity(OpacityTier.subtle),
              in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            )

          Text(issue.trackerState)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)

          if issue.orchestrationState != .queued {
            Button {
              Task { await retryIssueCompact() }
            } label: {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
            .help(issue.orchestrationState == .failed ? "Retry" : "Restart")
          }

          if issue.sessionId != nil {
            Image(systemName: "arrow.right.circle")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(Color.accent)
          }
        }

        if let error = issue.error, !error.isEmpty {
          Text(error)
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(Color.feedbackNegative.opacity(0.8))
            .lineLimit(2)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .frame(minHeight: 36)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      if let sessionId = issue.sessionId {
        if let onNavigateToSession {
          onNavigateToSession(sessionId)
        } else {
          navigateToSession()
        }
      } else if let url = issue.url, let link = URL(string: url) {
        #if os(macOS)
          NSWorkspace.shared.open(link)
        #endif
      }
    }
  }

  // MARK: - Full Layout

  private var fullBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      if isCompact {
        compactFullLayout
      } else {
        desktopFullLayout
      }

      if let error = issue.error {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: IconScale.xs))
            .foregroundStyle(Color.feedbackNegative)
          Text(error)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.feedbackNegative)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, isCompact ? 0 : 20 + Spacing.md)
        .padding(.top, Spacing.xs)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .contentShape(Rectangle())
    .contextMenu {
      if issue.sessionId != nil {
        Button {
          navigateToSession()
        } label: {
          Label("Go to Session", systemImage: "arrow.right.circle")
        }
      }

      if let url = issue.url, let openURL = URL(string: url) {
        Button {
          #if os(macOS)
            NSWorkspace.shared.open(openURL)
          #else
            UIApplication.shared.open(openURL)
          #endif
        } label: {
          Label(url.contains("github.com") ? "Open in GitHub" : "Open in Linear", systemImage: "arrow.up.right.square")
        }
      }

      if let prUrl = issue.prUrl, let openURL = URL(string: prUrl) {
        Button {
          #if os(macOS)
            NSWorkspace.shared.open(openURL)
          #else
            UIApplication.shared.open(openURL)
          #endif
        } label: {
          Label("Open Pull Request", systemImage: "arrow.triangle.pull")
        }
      }

      if !issue.allowedTransitions.isEmpty {
        Divider()
        ForEach(issue.allowedTransitions, id: \.self) { target in
          Button {
            Task { await onTransitionIssue?(issue.issueId, target, nil) }
          } label: {
            Label(target.transitionLabel, systemImage: target.transitionIcon)
          }
        }
      }
    }
  }

  // MARK: - Compact Full Layout

  private var compactFullLayout: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      // Row 1: identifier + state badge + actions
      HStack(spacing: Spacing.sm_) {
        stateIcon
          .frame(width: 16)

        Text(issue.identifier)
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)

        if let prLabel = issue.prLabel {
          prBadge(prLabel)
        }

        Text(issue.orchestrationState.displayLabel)
          .font(.system(size: TypeScale.micro, weight: .bold))
          .foregroundStyle(issue.orchestrationState.color)

        Text(issue.trackerState)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)

        Spacer()

        if issue.sessionId != nil {
          Button {
            navigateToSession()
          } label: {
            Image(systemName: "arrow.right.circle")
              .font(.system(size: 14))
              .foregroundStyle(Color.accent)
          }
          .buttonStyle(.plain)
        }

        if let onTransitionIssue {
          IssueTransitionMenu(issue: issue) { target, reason in
            await onTransitionIssue(issue.issueId, target, reason)
          }
        }
      }

      // Row 2: title (full width to wrap properly)
      Text(issue.title)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textPrimary)
        .fixedSize(horizontal: false, vertical: true)

      // Row 3: metadata & activity
      if issue.attempt > 1 || issue.lastActivity != nil || issue.activitySummary != nil {
        HStack(spacing: Spacing.sm) {
          if issue.attempt > 1 {
            Text("Attempt \(issue.attempt)")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.feedbackCaution)
          }

          if let activity = issue.lastActivity {
            Text(activity)
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
          }

          if let summary = issue.activitySummary {
            Text(summary)
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
      }
    }
  }

  // MARK: - Desktop Full Layout

  private var desktopFullLayout: some View {
    HStack(spacing: Spacing.md) {
      stateIcon
        .frame(width: 20)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.sm_) {
          Text(issue.identifier)
            .font(.system(size: TypeScale.caption, weight: .bold))
            .foregroundStyle(Color.textTertiary)

          if let prLabel = issue.prLabel {
            prBadge(prLabel)
          }

          Text(issue.title)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textPrimary)
        }

        HStack(spacing: Spacing.sm) {
          Text(issue.orchestrationState.displayLabel)
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(issue.orchestrationState.color)

          Text(issue.trackerState)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)

          if issue.attempt > 1 {
            Text("Attempt \(issue.attempt)")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.feedbackCaution)
          }

          if let activity = issue.lastActivity {
            Text(activity)
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
          }

          if let summary = issue.activitySummary {
            Text(summary)
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
      }

      Spacer()

      if issue.sessionId != nil {
        Button {
          navigateToSession()
        } label: {
          Image(systemName: "arrow.right.circle")
            .font(.system(size: 14))
            .foregroundStyle(Color.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Go to session")
      }

      #if os(macOS)
        if let error = issue.error {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(Color.feedbackNegative)
            .help(error)
        }
      #endif

      if let onTransitionIssue {
        IssueTransitionMenu(issue: issue) { target, reason in
          await onTransitionIssue(issue.issueId, target, reason)
        }
      }
    }
  }

  @ViewBuilder
  private var stateIcon: some View {
    switch issue.orchestrationState {
      case .queued:
        Image(systemName: "clock")
          .foregroundStyle(Color.textTertiary)
      case .claimed:
        Image(systemName: "arrow.right.circle")
          .foregroundStyle(Color.statusWorking)
      case .running:
        Image(systemName: "play.circle.fill")
          .foregroundStyle(Color.statusWorking)
      case .retryQueued:
        Image(systemName: "arrow.clockwise.circle")
          .foregroundStyle(Color.feedbackCaution)
      case .completed:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Color.feedbackPositive)
      case .failed:
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(Color.feedbackNegative)
      case .blocked:
        Image(systemName: "hand.raised.circle.fill")
          .foregroundStyle(Color.feedbackWarning)
    }
  }

  private func prBadge(_ label: String) -> some View {
    Button {
      if let prUrl = issue.prUrl, let url = URL(string: prUrl) {
        #if os(macOS)
          NSWorkspace.shared.open(url)
        #else
          UIApplication.shared.open(url)
        #endif
      }
    } label: {
      HStack(spacing: 2) {
        Image(systemName: "arrow.triangle.pull")
          .font(.system(size: 9, weight: .medium))
        Text(label)
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
      }
      .foregroundStyle(Color.accent)
    }
    .buttonStyle(.plain)
    .help("Open pull request")
  }

  // MARK: - Actions

  private func navigateToSession() {
    guard let sessionId = issue.sessionId else { return }
    let ref = SessionRef(endpointId: endpointId, sessionId: sessionId)
    router.selectSession(ref, source: .external)
  }

  private func retryIssue() async {
    guard let missionsClient else { return }
    do {
      _ = try await missionsClient.retryIssue(missionId: missionId, issueId: issue.issueId)
      await onRefresh?()
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func retryIssueCompact() async {
    guard let missionsClient else { return }
    do {
      _ = try await missionsClient.retryIssue(missionId: missionId, issueId: issue.issueId)
      await onRefresh?()
    } catch {
      actionError = error.localizedDescription
    }
  }

}
