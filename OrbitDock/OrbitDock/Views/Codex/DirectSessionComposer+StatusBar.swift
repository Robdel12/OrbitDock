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
        AutonomyPill(sessionId: sessionId, size: .statusBar)
        CodexModePill(sessionId: sessionId, size: .statusBar)
      } else if obs.isDirectClaude {
        ClaudePermissionPill(sessionId: sessionId, size: .statusBar)
      }

      if isSessionWorking {
        workingSteerLabel
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
          AutonomyPill(sessionId: sessionId, size: .statusBar)
          CodexModePill(sessionId: sessionId, size: .statusBar)
        } else if obs.isDirectClaude {
          ClaudePermissionPill(sessionId: sessionId, size: .statusBar)
        }

        if isSessionWorking {
          workingSteerLabel
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
          runtimeRegistry.reconnect(endpointId: serverState.endpointId)
        }
        .buttonStyle(GhostButtonStyle(color: .accent, size: .compact))
      }
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

  var workingSteerLabel: some View {
    HStack(spacing: Spacing.xs) {
      Circle()
        .fill(Color.composerSteer)
        .frame(width: 6, height: 6)
      Text("Working - Steering enabled")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.composerSteer)
        .lineLimit(1)
    }
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.gap)
    .background(
      Color.composerSteer.opacity(OpacityTier.light),
      in: Capsule()
    )
    .help("Model is currently working. You can keep steering with full composer tools.")
  }
}
