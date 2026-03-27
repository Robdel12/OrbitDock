//
//  DirectSessionComposer+StatusBar.swift
//  OrbitDock
//
//  Status bar, connection pill, and metadata labels.
//

import SwiftUI

extension DirectSessionComposer {
  // MARK: - Status Bar (informational metadata below composer)

  @ViewBuilder
  var statusBar: some View {
    if isCompactLayout {
      compactStatusBar
    } else {
      desktopStatusBar
    }
  }

  var desktopStatusBar: some View {
    HStack(spacing: Spacing.sm) {
      if !isConnected {
        connectionStatusPill
      }

      if obs.isDirectCodex {
        AutonomyPill(
          currentLevel: obs.autonomy,
          isConfiguredOnServer: obs.autonomyConfiguredOnServer,
          size: .statusBar,
          isActive: permissionPanelExpanded,
          onTapOverride: { withAnimation(Motion.standard) { permissionPanelExpanded.toggle() } }
        )
        codexAutoReviewPill
        CodexModePill(
          currentMode: CodexCollaborationMode.from(
            rawValue: obs.collaborationMode,
            permissionMode: obs.permissionMode
          ),
          size: .statusBar,
          onUpdate: { mode in
            Task {
              try? await viewModel.updateCodexCollaborationMode(mode)
            }
          }
        )
      } else if obs.isDirectClaude {
        ClaudePermissionPill(
          currentMode: obs.permissionMode,
          showBypassOption: obs.allowBypassPermissions,
          size: .statusBar,
          isActive: permissionPanelExpanded,
          onTapOverride: { withAnimation(Motion.standard) { permissionPanelExpanded.toggle() } },
          onUpdate: { mode in
            Task {
              try? await viewModel.updateClaudePermissionMode(mode)
            }
          }
        )
      }

      if obs.hasTokenUsage {
        footerTokenLabel
      }

      footerModelLabel

      if let branch = obs.branch, !branch.isEmpty {
        footerBranchLabel(branch)
      }

      if !obs.projectPath.isEmpty {
        statusBarCwdLabel(obs.projectPath)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Spacing.md_)
    .padding(.top, Spacing.xs)
    .padding(.bottom, Spacing.sm_)
  }

  var compactStatusBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm_) {
        if !isConnected {
          connectionStatusPill
        }

        if obs.isDirectCodex {
          AutonomyPill(
            currentLevel: obs.autonomy,
            isConfiguredOnServer: obs.autonomyConfiguredOnServer,
            size: .statusBar,
            isActive: permissionPanelExpanded,
            onTapOverride: { withAnimation(Motion.standard) { permissionPanelExpanded.toggle() } }
          )
          codexAutoReviewPill
          CodexModePill(
            currentMode: CodexCollaborationMode.from(
              rawValue: obs.collaborationMode,
              permissionMode: obs.permissionMode
            ),
            size: .statusBar,
            onUpdate: { mode in
              Task {
                try? await viewModel.updateCodexCollaborationMode(mode)
              }
            }
          )
        } else if obs.isDirectClaude {
          ClaudePermissionPill(
            currentMode: obs.permissionMode,
            showBypassOption: obs.allowBypassPermissions,
            size: .statusBar,
            isActive: permissionPanelExpanded,
            onTapOverride: { withAnimation(Motion.standard) { permissionPanelExpanded.toggle() } },
            onUpdate: { mode in
              Task {
                try? await viewModel.updateClaudePermissionMode(mode)
              }
            }
          )
        }

        if obs.hasTokenUsage {
          compactFooterTokenChip
        }

        footerModelLabel

        if let branch = obs.branch, !branch.isEmpty {
          footerBranchLabel(branch)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.md_)
    }
    .scrollIndicators(.hidden)
    .padding(.vertical, Spacing.xs)
  }

  var connectionStatusPill: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: connectionPillIcon)
        .font(.system(size: TypeScale.mini, weight: .semibold))
      Text(connectionPillLabel)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundStyle(connectionPillTint)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.gap)
    .background(connectionPillTint.opacity(OpacityTier.light), in: Capsule())
  }

  func connectionNoticeRow(_ message: String) -> some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: connectionPillIcon)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(connectionPillTint)

      Text(message)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(2)

      Spacer(minLength: 0)

      if showReconnectButton {
        Button("Reconnect") {
          runtimeRegistry.reconnect(endpointId: viewModel.endpointId)
        }
        .buttonStyle(GhostButtonStyle(color: .accent, size: .compact))
      }
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.bottom, Spacing.xs)
  }

  func codexScopedModelNoticeRow(_ message: String, isLoading: Bool) -> some View {
    let tint = isLoading ? Color.feedbackCaution : Color.providerCodex

    return HStack(spacing: Spacing.sm_) {
      if isLoading {
        ProgressView()
          .controlSize(.small)
          .tint(tint)
      } else {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(tint)
      }

      Text(message)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(3)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.bottom, Spacing.xs)
  }

  func statusBarCwdLabel(_ cwd: String) -> some View {
    let display = (cwd as NSString).lastPathComponent
    return HStack(spacing: Spacing.xxs) {
      Image(systemName: "folder")
        .font(.system(size: TypeScale.mini, weight: .medium))
      Text(display)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }
    .foregroundStyle(Color.textQuaternary)
    .help(cwd)
  }

  var codexAutoReviewPill: some View {
    Button {
      withAnimation(Motion.standard) { permissionPanelExpanded.toggle() }
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: obs.autonomy.autoReviewStatusIcon)
          .font(.system(size: TypeScale.mini, weight: .semibold))
        Text(obs.autonomy.autoReviewStatusLabel)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundStyle(obs.autonomy.color)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.gap)
      .background(obs.autonomy.color.opacity(OpacityTier.light), in: Capsule())
      .overlay(
        Capsule()
          .strokeBorder(
            permissionPanelExpanded
              ? obs.autonomy.color.opacity(OpacityTier.medium)
              : Color.clear,
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
    .help(obs.autonomy.autoReviewCardSummary)
  }
}
