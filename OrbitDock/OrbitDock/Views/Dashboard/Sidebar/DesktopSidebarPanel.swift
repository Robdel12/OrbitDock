//
//  DesktopSidebarPanel.swift
//  OrbitDock
//
//  Desktop-only left sidebar for the activity stream.
//  Compact agent list + project filter chips.
//

import SwiftUI

struct DesktopSidebarPanel: View {
  let sessions: [Session]
  let width: CGFloat
  @Binding var projectFilter: String?
  let onSelectSession: (Session) -> Void

  private var activeSessions: [Session] {
    sessions.filter(\.showsInMissionControl)
      .sorted { lhs, rhs in
        let lhsDate = lhs.startedAt ?? lhs.lastActivityAt ?? .distantPast
        let rhsDate = rhs.startedAt ?? rhs.lastActivityAt ?? .distantPast
        if lhsDate != rhsDate {
          return lhsDate > rhsDate
        }

        let lhsName = lhs.displayName.localizedLowercase
        let rhsName = rhs.displayName.localizedLowercase
        if lhsName != rhsName {
          return lhsName < rhsName
        }

        return lhs.id < rhs.id
      }
  }

  /// Group projects by their grouping path (repo root) to collapse worktrees
  private var projectNames: [(path: String, name: String, count: Int)] {
    let active = sessions.filter(\.showsInMissionControl)
    let grouped = Dictionary(grouping: active) { $0.groupingPath }
    return grouped.map { path, sessions in
      let name = sessions.first?.projectName
        ?? path.components(separatedBy: "/").last
        ?? "Unknown"
      return (path: path, name: name, count: sessions.count)
    }
    .sorted { lhs, rhs in
      let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
      if comparison != .orderedSame {
        return comparison == .orderedAscending
      }
      return lhs.path < rhs.path
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      agentList

      sectionDivider

      projectFilterSection

      sectionDivider

      SidebarUsageSection()
    }
    .frame(width: width)
    .background(Color.backgroundSecondary.opacity(0.2))
  }

  private var sectionDivider: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
      .frame(height: 1)
      .padding(.horizontal, Spacing.md)
  }

  // MARK: - Agent List

  private var agentList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.sm_) {
        Text("AGENTS")
          .font(.system(size: TypeScale.micro, weight: .heavy))
          .foregroundStyle(Color.textTertiary)
          .tracking(0.8)

        Text("\(activeSessions.count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textQuaternary)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Color.surfaceHover.opacity(0.5), in: Capsule())

        Spacer()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.top, Spacing.md)
      .padding(.bottom, Spacing.sm)

      ScrollView {
        LazyVStack(spacing: Spacing.gap) {
          ForEach(activeSessions, id: \.scopedID) { session in
            sidebarSessionRow(session)
          }
        }
        .padding(.horizontal, Spacing.sm_)
      }
    }
  }

  private func sidebarSessionRow(_ session: Session) -> some View {
    let status = SessionDisplayStatus.from(session)
    let label = session.displayName

    let recency = DashboardFormatters.recency(for: session.lastActivityAt ?? session.startedAt)

    return Button {
      onSelectSession(session)
    } label: {
      HStack(spacing: Spacing.sm_) {
        UnreadIndicatorDot(isVisible: session.hasUnreadMessages, size: 6)
          .frame(width: 8)

        Text(label)
          .font(.system(size: TypeScale.caption, weight: session.hasUnreadMessages || status.needsAttention ? .semibold : .regular))
          .foregroundStyle(sidebarTitleColor(for: session, status: status))
          .lineLimit(2)
          .truncationMode(.tail)

        Spacer(minLength: 0)

        ViewThatFits(in: .horizontal) {
          if let recency {
            HStack(spacing: Spacing.xs) {
              sidebarStatusLabel(status)
              sidebarRecencyLabel(recency)
            }
          }

          sidebarStatusLabel(status)

          if let recency {
            sidebarRecencyLabel(recency)
          }
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(status.needsAttention ? status.color.opacity(OpacityTier.tint) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func sidebarTitleColor(for session: Session, status: SessionDisplayStatus) -> Color {
    if status.needsAttention {
      return status.color
    }
    if session.hasUnreadMessages {
      return .textPrimary
    }
    return .textSecondary
  }

  private func sidebarStatusLabel(_ status: SessionDisplayStatus) -> some View {
    Text(status.label)
      .font(.system(size: TypeScale.mini, weight: .semibold))
      .foregroundStyle(status.color.opacity(status == .reply ? 0.78 : 1.0))
      .lineLimit(1)
  }

  private func sidebarRecencyLabel(_ recency: String) -> some View {
    Text(recency)
      .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.textQuaternary)
      .frame(minWidth: 20, alignment: .trailing)
  }

  // MARK: - Project Filter

  private var projectFilterSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("PROJECTS")
        .font(.system(size: TypeScale.micro, weight: .heavy))
        .foregroundStyle(Color.textTertiary)
        .tracking(0.8)
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)

      ScrollView {
        LazyVStack(spacing: Spacing.gap) {
          projectFilterRow(name: "All Projects", path: nil, count: sessions.filter(\.showsInMissionControl).count)

          ForEach(projectNames, id: \.path) { project in
            projectFilterRow(name: project.name, path: project.path, count: project.count)
          }
        }
        .padding(.horizontal, Spacing.sm_)
        .padding(.bottom, Spacing.md)
      }
    }
  }

  private func projectFilterRow(name: String, path: String?, count: Int) -> some View {
    let isActive = (projectFilter == nil && path == nil) || projectFilter == path

    return Button {
      projectFilter = (projectFilter == path) ? nil : path
    } label: {
      HStack(spacing: Spacing.sm) {
        Text(name)
          .font(.system(size: TypeScale.caption, weight: isActive ? .semibold : .regular))
          .foregroundStyle(isActive ? Color.accent : Color.textSecondary)
          .lineLimit(1)

        Spacer(minLength: 0)

        Text("\(count)")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textQuaternary)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(
        isActive
          ? Color.accent.opacity(0.10)
          : Color.clear,
        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Sidebar Usage Section

private struct SidebarUsageSection: View {
  @State private var expandedProviderIDs: Set<String> = []
  let registry = UsageServiceRegistry.shared

  private var activeProviders: [(provider: Provider, windows: [RateLimitWindow], isLoading: Bool, error: (any LocalizedError)?)] {
    registry.allProviders.map { provider in
      (
        provider: provider,
        windows: registry.windows(for: provider),
        isLoading: registry.isLoading(for: provider),
        error: registry.error(for: provider)
      )
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("USAGE")
        .font(.system(size: TypeScale.micro, weight: .heavy))
        .foregroundStyle(Color.textTertiary)
        .tracking(0.8)
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)

      VStack(alignment: .leading, spacing: Spacing.md) {
        ForEach(activeProviders, id: \.provider.id) { entry in
          sidebarProviderGauge(
            entry.provider,
            windows: entry.windows,
            isLoading: entry.isLoading,
            error: entry.error
          )
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.bottom, Spacing.md)
    }
  }

  private func sidebarProviderGauge(
    _ provider: Provider,
    windows: [RateLimitWindow],
    isLoading: Bool,
    error: (any LocalizedError)?
  ) -> some View {
    let isExpanded = expandedProviderIDs.contains(provider.id)
    let isInteractive = !windows.isEmpty

    return VStack(alignment: .leading, spacing: Spacing.sm_) {
      Button {
        guard isInteractive else { return }
        withAnimation(Motion.standard) {
          if isExpanded {
            expandedProviderIDs.remove(provider.id)
          } else {
            expandedProviderIDs.insert(provider.id)
          }
        }
      } label: {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: provider.icon)
              .font(.system(size: TypeScale.mini, weight: .bold))
              .foregroundStyle(provider.accentColor)

            Text(provider.displayName)
              .font(.system(size: TypeScale.caption, weight: .bold))
              .foregroundStyle(Color.textSecondary)

            if let plan = registry.planName(for: provider) {
              Text(plan)
                .font(.system(size: TypeScale.mini, weight: .medium))
                .foregroundStyle(Color.textQuaternary)
            }

            Spacer(minLength: 0)

            if isInteractive {
              Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
          }

          if !windows.isEmpty {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: Spacing.xs) {
                ForEach(windows) { window in
                  sidebarSummaryBadge(window, provider: provider)
                }
              }

              Text(sidebarSummaryText(windows))
                .font(.system(size: TypeScale.mini, weight: .medium, design: .rounded))
                .foregroundStyle(Color.textQuaternary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            }
          } else if isLoading {
            HStack(spacing: Spacing.sm) {
              ProgressView().controlSize(.mini)
              Text("Loading...")
                .font(.system(size: TypeScale.micro, weight: .medium))
                .foregroundStyle(Color.textQuaternary)
            }
          } else if let error {
            Text(error.localizedDescription)
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          } else {
            Text("—")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textQuaternary)
          }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.backgroundSecondary.opacity(isExpanded ? 0.56 : 0.34))
        )
        .overlay {
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded && !windows.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(windows) { window in
            sidebarWindowRow(window, provider: provider)
          }
        }
        .padding(.leading, Spacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  private func sidebarSummaryBadge(_ window: RateLimitWindow, provider: Provider) -> some View {
    let usageColor = provider.color(for: window.utilization)

    return HStack(spacing: Spacing.xs) {
      Text(window.label)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(provider.accentColor)

      Text("\(Int(window.utilization))%")
        .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
        .foregroundStyle(usageColor)
    }
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, 3)
    .background(Color.backgroundTertiary.opacity(0.72), in: Capsule())
    .overlay {
      Capsule()
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    }
  }

  private func sidebarSummaryText(_ windows: [RateLimitWindow]) -> String {
    windows.map { "\($0.label) \(Int($0.utilization))%" }
      .joined(separator: "  •  ")
  }

  private func sidebarWindowRow(_ window: RateLimitWindow, provider: Provider) -> some View {
    let usageColor = provider.color(for: window.utilization)
    let projectedColor = DashboardFormatters.projectedColor(window.projectedAtReset)
    let showProjection = window.projectedAtReset > window.utilization + 5
    let paceText = DashboardFormatters.paceLabel(window.paceStatus)
    let resetText = window.resetsInDescription.map { "Resets in \($0)" }

    return VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm_) {
        Text(window.label)
          .font(.system(size: TypeScale.mini, weight: .semibold, design: .rounded))
          .foregroundStyle(provider.accentColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 3)
          .background(provider.accentColor.opacity(0.14), in: Capsule())

        Text("\(Int(window.utilization))%")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
          .foregroundStyle(usageColor)
          .fixedSize()

        Spacer(minLength: Spacing.sm)

        if let paceText {
          HStack(spacing: Spacing.xs) {
            Text(paceText)

            if showProjection {
              Text("+\(Int(window.projectedAtReset.rounded()))%")
                .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            }
          }
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(projectedColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 3)
          .background(projectedColor.opacity(0.14), in: Capsule())
        }
      }

      UsageGaugeBar(
        utilization: window.utilization,
        usageColor: usageColor,
        projectedAtReset: window.projectedAtReset,
        showProjection: showProjection
      )
      .frame(height: 6)

      if let resetText {
        Text(resetText)
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.5))
    )
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    }
    .overlay(alignment: .topTrailing) {
      if window.willExceed {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(Color.statusError)
          .padding(Spacing.xxs)
          .background(Color.backgroundPrimary.opacity(0.92), in: Circle())
          .offset(x: 6, y: -6)
      }
    }
  }

}
