//
//  CommandStrip.swift
//  OrbitDock
//
//  Slim single-line header replacing the old dashboardHeader.
//  Panel toggle + title + status counts + usage bars + new session buttons + search.
//

import SwiftUI

struct CommandStrip: View {
  let sessions: [Session]
  let isInitialLoading: Bool
  let isRefreshingCachedSessions: Bool
  let onOpenPanel: () -> Void
  let onOpenQuickSwitcher: () -> Void
  let onNewClaude: () -> Void
  let onNewCodex: () -> Void

  private let registry = UsageServiceRegistry.shared

  private var workingCount: Int {
    sessions.filter { SessionDisplayStatus.from($0) == .working }.count
  }

  private var attentionCount: Int {
    sessions.filter { SessionDisplayStatus.from($0).needsAttention }.count
  }

  private var readyCount: Int {
    sessions.filter { $0.isActive && SessionDisplayStatus.from($0) == .reply }.count
  }

  var body: some View {
    HStack(spacing: 10) {
      // Left: panel toggle + title
      Button(action: onOpenPanel) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .frame(width: 28, height: 28)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .buttonStyle(.plain)
      .help("Toggle panel (⌘1)")

      Text("OrbitDock")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)

      // Sync indicator
      if isInitialLoading || isRefreshingCachedSessions {
        HStack(spacing: 4) {
          ProgressView()
            .controlSize(.mini)
          Text("Syncing")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.textTertiary)
        }
      }

      // Center: status counts
      if !sessions.isEmpty {
        HStack(spacing: 8) {
          if workingCount > 0 {
            statusDot(count: workingCount, color: .statusWorking, icon: "bolt.fill")
          }
          if attentionCount > 0 {
            statusDot(count: attentionCount, color: .statusPermission, icon: "exclamationmark.circle.fill")
          }
          if readyCount > 0 {
            statusDot(count: readyCount, color: .statusReply, icon: "bubble.left.fill")
          }
        }
      }

      Spacer()

      // Right: usage bars (compact inline)
      HStack(spacing: 12) {
        ForEach(registry.activeProviders) { provider in
          ProviderUsageCompact(
            provider: provider,
            windows: registry.windows(for: provider),
            isLoading: registry.isLoading(for: provider),
            error: registry.error(for: provider),
            isStale: registry.isStale(for: provider)
          )
        }
      }

      // Separator
      if !registry.activeProviders.isEmpty {
        Color.panelBorder.frame(width: 1, height: 16)
      }

      // New session buttons
      Button(action: onNewClaude) {
        HStack(spacing: 5) {
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
          Text("Claude")
            .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .foregroundStyle(Color.accent)
      }
      .buttonStyle(.plain)
      .help("Create new Claude session")

      Button(action: onNewCodex) {
        HStack(spacing: 5) {
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
          Text("Codex")
            .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.providerCodex.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .foregroundStyle(Color.providerCodex)
      }
      .buttonStyle(.plain)
      .help("Create new Codex session")

      // Search
      Button(action: onOpenQuickSwitcher) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .frame(width: 28, height: 28)
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .buttonStyle(.plain)
      .help("Search sessions (⌘K)")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color.backgroundSecondary)
  }

  // MARK: - Status Dot

  private func statusDot(count: Int, color: Color, icon: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(color)
      Text("\(count)")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(color.opacity(0.9))
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 0) {
    CommandStrip(
      sessions: [
        Session(id: "1", projectPath: "/p", status: .active, workStatus: .working),
        Session(
          id: "2",
          projectPath: "/p",
          status: .active,
          workStatus: .permission,
          attentionReason: .awaitingPermission
        ),
        Session(id: "3", projectPath: "/p", status: .active, workStatus: .waiting, attentionReason: .awaitingReply),
      ],
      isInitialLoading: false,
      isRefreshingCachedSessions: false,
      onOpenPanel: {},
      onOpenQuickSwitcher: {},
      onNewClaude: {},
      onNewCodex: {}
    )

    Divider().foregroundStyle(Color.panelBorder)

    Color.backgroundPrimary
      .frame(height: 200)
  }
  .frame(width: 900)
}
