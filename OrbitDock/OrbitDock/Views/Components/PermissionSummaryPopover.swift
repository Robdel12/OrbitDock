//
//  PermissionSummaryPopover.swift
//  OrbitDock
//
//  Inline permission summary panel that extends above the composer
//  text input, following the same pattern as the pending approval panel.
//  Toggled by tapping the permission pill in the status bar.
//
//  Shows: current mode + what it means, active permission rules
//  (allowed grants by scope, denied commands), with revoke controls.
//

import SwiftUI

// MARK: - Inline Permission Panel

struct PermissionInlinePanel: View {
  let sessionId: String
  @Binding var isExpanded: Bool
  @Environment(ServerAppState.self) private var serverState

  @State private var headerHovering = false

  private var currentSession: Session? {
    serverState.sessions.first(where: { $0.id == sessionId })
  }

  private var sessionApprovals: [ServerApprovalHistoryItem] {
    serverState.session(sessionId).approvalHistory
  }

  /// Deduplicated active grants (session-scoped + always-allow)
  private var activeScopeGrants: [ServerApprovalHistoryItem] {
    var deduped: [ServerApprovalHistoryItem] = []
    var seen = Set<String>()

    for approval in sessionApprovals {
      guard let decision = approval.decision,
            decision == "approved_for_session" || decision == "approved_always"
      else { continue }

      let key = [
        decision,
        approval.toolName ?? "",
        approval.command ?? "",
        approval.filePath ?? "",
      ].joined(separator: "|")

      guard !seen.contains(key) else { continue }
      seen.insert(key)
      deduped.append(approval)
    }

    return deduped
  }

  /// Deduplicated denied commands (denied + abort)
  private var deniedGrants: [ServerApprovalHistoryItem] {
    var deduped: [ServerApprovalHistoryItem] = []
    var seen = Set<String>()

    for approval in sessionApprovals {
      guard let decision = approval.decision,
            decision == "denied" || decision == "abort"
      else { continue }

      let key = [
        approval.toolName ?? "",
        approval.command ?? "",
        approval.filePath ?? "",
      ].joined(separator: "|")

      guard !seen.contains(key) else { continue }
      seen.insert(key)
      deduped.append(approval)
    }

    return deduped
  }

  private var hasAnyRules: Bool {
    !activeScopeGrants.isEmpty || !deniedGrants.isEmpty
  }

  // MARK: - Provider-specific properties

  private var panelColor: Color {
    if let session = currentSession {
      if session.isDirectCodex { return serverState.session(sessionId).autonomy.color }
      if session.isDirectClaude { return serverState.session(sessionId).permissionMode.color }
    }
    return Color.textTertiary
  }

  private var panelTitle: String {
    if let session = currentSession {
      if session.isDirectCodex { return serverState.session(sessionId).autonomy.displayName }
      if session.isDirectClaude { return serverState.session(sessionId).permissionMode.displayName }
    }
    return "Permissions"
  }

  private var panelIcon: String {
    if let session = currentSession {
      if session.isDirectCodex { return serverState.session(sessionId).autonomy.icon }
      if session.isDirectClaude { return serverState.session(sessionId).permissionMode.icon }
    }
    return "shield.lefthalf.filled"
  }

  private var modeDescription: String {
    if let session = currentSession {
      if session.isDirectCodex { return serverState.session(sessionId).autonomy.description }
      if session.isDirectClaude { return serverState.session(sessionId).permissionMode.description }
    }
    return ""
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header (always visible, tappable to expand/collapse)
      Button {
        withAnimation(Motion.standard) {
          isExpanded.toggle()
        }
      } label: {
        inlineHeader
      }
      .buttonStyle(.plain)

      // Expandable content
      if isExpanded {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          // Mode selector + description
          modeSelector

          // Mode description
          Text(modeDescription)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textSecondary)

          // Active rules (allowed + denied)
          if hasAnyRules {
            activeRulesSection
          } else {
            Text("No active permission rules this session")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
          }
        }
        .padding(.horizontal, Spacing.md_)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.sm)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity.animation(Motion.gentle.delay(0.05)))
      }

      // Bottom divider
      Rectangle()
        .fill(panelColor.opacity(OpacityTier.light))
        .frame(height: 0.5)
        .padding(.horizontal, Spacing.sm)
    }
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      serverState.loadApprovalHistory(sessionId: sessionId)
    }
  }

  // MARK: - Header

  private var inlineHeader: some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: panelIcon)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(panelColor)

      Text("Permissions")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      Text("\u{00B7}")
        .foregroundStyle(Color.textQuaternary)

      Text(panelTitle)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(panelColor)

      if hasAnyRules {
        let totalRules = activeScopeGrants.count + deniedGrants.count
        Text("\(totalRules) active")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(panelColor.opacity(OpacityTier.vivid))
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(panelColor.opacity(OpacityTier.light), in: Capsule())
      }

      Spacer(minLength: 0)

      Image(systemName: "chevron.right")
        .font(.system(size: TypeScale.mini, weight: .bold))
        .foregroundStyle(Color.textTertiary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .animation(Motion.snappy, value: isExpanded)
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, Spacing.sm_)
    .background(headerHovering ? Color.surfaceHover : Color.clear)
    .contentShape(Rectangle())
    .platformHover { hovering in
      headerHovering = hovering
    }
  }

  // MARK: - Mode Selector

  @ViewBuilder
  private var modeSelector: some View {
    if let session = currentSession {
      if session.isDirectCodex {
        codexModeSelector
      } else if session.isDirectClaude {
        claudeModeSelector
      }
    }
  }

  private var codexModeSelector: some View {
    let levels = AutonomyLevel.allCases
    let currentLevel = serverState.session(sessionId).autonomy

    return ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        ForEach(levels) { level in
          Button {
            serverState.updateSessionConfig(sessionId: sessionId, autonomy: level)
          } label: {
            HStack(spacing: Spacing.xxs) {
              Image(systemName: level.icon)
                .font(.system(size: TypeScale.micro, weight: .semibold))
              Text(level.displayName)
                .font(.system(size: TypeScale.micro, weight: .semibold))
            }
            .foregroundStyle(level == currentLevel ? level.color : Color.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
              level == currentLevel
                ? level.color.opacity(OpacityTier.light)
                : Color.backgroundTertiary.opacity(OpacityTier.medium),
              in: Capsule()
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  private var claudeModeSelector: some View {
    let modes = ClaudePermissionMode.allCases
    let currentMode = serverState.session(sessionId).permissionMode

    return ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        ForEach(modes) { mode in
          Button {
            serverState.updateClaudePermissionMode(sessionId: sessionId, mode: mode)
          } label: {
            HStack(spacing: Spacing.xxs) {
              Image(systemName: mode.icon)
                .font(.system(size: TypeScale.micro, weight: .semibold))
              Text(mode.displayName)
                .font(.system(size: TypeScale.micro, weight: .semibold))
            }
            .foregroundStyle(mode == currentMode ? mode.color : Color.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
              mode == currentMode
                ? mode.color.opacity(OpacityTier.light)
                : Color.backgroundTertiary.opacity(OpacityTier.medium),
              in: Capsule()
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  // MARK: - Active Rules (Allowed + Denied)

  private var activeRulesSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Allowed rules
      if !activeScopeGrants.isEmpty {
        let sessionGrants = activeScopeGrants.filter { $0.decision == "approved_for_session" }
        let alwaysGrants = activeScopeGrants.filter { $0.decision == "approved_always" }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Allowed")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.feedbackPositive)

          if !sessionGrants.isEmpty {
            ruleGroup(title: "This Session", rules: sessionGrants, color: .feedbackPositive, icon: "checkmark.circle.fill")
          }

          if !alwaysGrants.isEmpty {
            ruleGroup(title: "Always", rules: alwaysGrants, color: .autonomyAutonomous, icon: "checkmark.seal.fill")
          }
        }
      }

      // Denied rules
      if !deniedGrants.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Denied")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.feedbackNegative)

          ruleGroup(title: "This Session", rules: deniedGrants, color: .feedbackNegative, icon: "xmark.circle.fill")
        }
      }
    }
  }

  private func ruleGroup(title: String, rules: [ServerApprovalHistoryItem], color: Color, icon: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title.uppercased())
        .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
        .foregroundStyle(color.opacity(OpacityTier.vivid))
        .padding(.bottom, Spacing.xxs)

      ForEach(rules) { approval in
        HStack(spacing: Spacing.sm) {
          // Colored edge bar
          RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2, height: 14)

          // Tool name
          Text(approval.toolName ?? approval.approvalType.rawValue)
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          // Command or file path
          if let command = approval.command, !command.isEmpty {
            Text(command)
              .font(.system(size: TypeScale.micro, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          } else if let filePath = approval.filePath, !filePath.isEmpty {
            Text(filePath)
              .font(.system(size: TypeScale.micro, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }

          Spacer(minLength: 0)

          // Revoke button
          Button {
            withAnimation(Motion.snappy) {
              serverState.deleteApproval(approvalId: approval.id)
            }
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textQuaternary)
          }
          .buttonStyle(.plain)
          .help("Revoke this rule")
        }
        .padding(.vertical, Spacing.xxs)
      }
    }
  }
}

// MARK: - Shared Helpers

enum ApprovalDecisionHelpers {
  static func label(for decision: String) -> String {
    switch decision {
      case "approved": "approved once"
      case "approved_for_session": "session-scoped"
      case "approved_always": "always allow"
      case "denied": "denied"
      case "abort": "denied & stop"
      default: decision
    }
  }

  static func color(for decision: String?) -> Color {
    switch decision {
      case "approved", "approved_for_session", "approved_always":
        Color.feedbackPositive
      case "denied", "abort":
        Color.feedbackNegative
      default:
        Color.textSecondary
    }
  }

  static func relativeTime(_ timestamp: String) -> String {
    guard let date = parseTimestamp(timestamp) else { return timestamp }
    return date.formatted(.relative(presentation: .named))
  }

  static func parseTimestamp(_ value: String) -> Date? {
    let stripped = value.hasSuffix("Z") ? String(value.dropLast()) : value
    if let seconds = TimeInterval(stripped) {
      return Date(timeIntervalSince1970: seconds)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

// MARK: - Legacy Popover Wrapper (for non-composer contexts)

struct PermissionSummaryPopover: View {
  let sessionId: String
  @State private var expanded = true

  var body: some View {
    ScrollView {
      PermissionInlinePanel(sessionId: sessionId, isExpanded: $expanded)
    }
    .scrollBounceBehavior(.basedOnSize)
    .ifMacOS { $0.frame(width: 360) }
    #if os(iOS)
      .frame(maxWidth: .infinity)
    #endif
    .background(Color.backgroundSecondary)
  }
}
