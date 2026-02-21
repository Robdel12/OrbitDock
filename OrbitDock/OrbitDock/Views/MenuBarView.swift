//
//  MenuBarView.swift
//  OrbitDock
//

import SwiftUI

#if os(macOS)

  struct MenuBarView: View {
    @Environment(ServerAppState.self) private var serverState
    @Environment(\.colorScheme) private var colorScheme

    var activeSessions: [Session] {
      serverState.sessions.filter(\.isActive)
    }

    var recentSessions: [Session] {
      serverState.sessions.filter { !$0.isActive }.prefix(5).map { $0 }
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        // Header
        HStack {
          HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
              .font(.system(size: 12, weight: .semibold))
            Text("OrbitDock")
              .font(.system(size: 13, weight: .semibold))
          }
          .foregroundStyle(headerTitleColor)

          Spacer()

          if !activeSessions.isEmpty {
            HStack(spacing: 4) {
              Circle()
                .fill(Color.statusWorking)
                .frame(width: 6, height: 6)
              Text("\(activeSessions.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.statusWorking)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.statusWorking.opacity(colorScheme == .dark ? 0.16 : 0.12), in: Capsule())
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)

        // Provider Usage
        VStack(spacing: 6) {
          ForEach(UsageServiceRegistry.shared.allProviders) { provider in
            ProviderMenuBarSection(
              provider: provider,
              windows: UsageServiceRegistry.shared.windows(for: provider),
              isLoading: UsageServiceRegistry.shared.isLoading(for: provider),
              error: UsageServiceRegistry.shared.error(for: provider)
            )
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)

        menuDivider

        // Content
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if !activeSessions.isEmpty {
              sectionHeader("Active")

              ForEach(activeSessions) { session in
                MenuBarSessionRow(session: session, isActive: true)
              }
            }

            if !recentSessions.isEmpty {
              if !activeSessions.isEmpty {
                menuDivider
                  .padding(.vertical, 8)
              }

              sectionHeader("Recent")

              ForEach(recentSessions) { session in
                MenuBarSessionRow(session: session, isActive: false)
              }
            }

            if serverState.sessions.isEmpty {
              emptyView
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
        }
        .frame(minHeight: 150, maxHeight: 320)
        .layoutPriority(1)

        menuDivider

        // Footer
        HStack {
          Button {
            if let window = NSApplication.shared.windows.first(where: {
              $0.title.contains("OrbitDock") || $0.contentView is NSHostingView<ContentView>
            }) {
              NSApplication.shared.activate(ignoringOtherApps: true)
              window.makeKeyAndOrderFront(nil)
            } else {
              NSApplication.shared.activate(ignoringOtherApps: true)
            }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "macwindow")
                .font(.system(size: 11))
              Text("Open Window")
                .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(secondaryTextColor)
          }
          .buttonStyle(.plain)

          Spacer()

          Button {
            serverState.refreshSessionsList()
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(tertiaryTextColor)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .frame(width: 332)
      .background(colorScheme == .dark ? Color.backgroundPrimary : Color(nsColor: .windowBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(tertiaryTextColor)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private var emptyView: some View {
      VStack(spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.08))
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.12), lineWidth: 1)
          Image(systemName: "terminal")
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(tertiaryTextColor)
        }
        .frame(width: 52, height: 42)

        Text("No sessions")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(secondaryTextColor)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 32)
    }

    private var menuDivider: some View {
      Rectangle()
        .fill(dividerColor)
        .frame(height: 1)
    }

    private var headerTitleColor: Color {
      colorScheme == .dark ? Color.white.opacity(0.9) : .primary
    }

    private var secondaryTextColor: Color {
      colorScheme == .dark ? Color.white.opacity(0.72) : .primary.opacity(0.78)
    }

    private var tertiaryTextColor: Color {
      colorScheme == .dark ? Color.white.opacity(0.5) : .primary.opacity(0.62)
    }

    private var dividerColor: Color {
      colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.1)
    }
  }

  struct MenuBarSessionRow: View {
    let session: Session
    let isActive: Bool
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var displayStatus: SessionDisplayStatus {
      SessionDisplayStatus.from(session)
    }

    var body: some View {
      HStack(spacing: 10) {
        // Status dot - using unified component
        SessionStatusDot(status: displayStatus, size: 6)
          .frame(width: 14)

        VStack(alignment: .leading, spacing: 2) {
          Text(session.displayName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)

          HStack(spacing: 6) {
            if let branch = session.branch, !branch.isEmpty {
              HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch")
                  .font(.system(size: 8))
                Text(branch)
                  .font(.system(size: 10, design: .monospaced))
              }
              .foregroundStyle(branchColor)
              .lineLimit(1)
            }

            Text(session.formattedDuration)
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(durationColor)
          }
        }

        Spacer(minLength: 4)

        UnifiedModelBadge(model: session.model, provider: session.provider)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        isHovering ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.09) : Color.clear,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .onHover { isHovering = $0 }
    }

    private var branchColor: Color {
      colorScheme == .dark ? Color.white.opacity(0.64) : .primary.opacity(0.75)
    }

    private var durationColor: Color {
      colorScheme == .dark ? Color.white.opacity(0.46) : .primary.opacity(0.58)
    }
  }

  #Preview {
    MenuBarView()
      .environment(ServerAppState())
  }

#else

  struct MenuBarView: View {
    var body: some View {
      EmptyView()
    }
  }

#endif
