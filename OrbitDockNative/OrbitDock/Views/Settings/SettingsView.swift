//
//  SettingsView.swift
//  OrbitDock
//
//  Settings/Preferences window - Cosmic Harbor theme
//

import SwiftUI

private enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
  case workspace
  case integrations
  case missionControl
  case servers
  case notifications
  case diagnostics

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .workspace:
        "Workspace"
      case .integrations:
        "Integrations"
      case .missionControl:
        "Mission Control"
      case .servers:
        "Servers"
      case .notifications:
        "Notifications"
      case .diagnostics:
        "Diagnostics"
    }
  }

  var subtitle: String {
    switch self {
      case .workspace:
        "Dictation and workspace preferences"
      case .integrations:
        "Codex account and provider access"
      case .missionControl:
        "API keys, provider defaults"
      case .servers:
        "Endpoints and connection state"
      case .notifications:
        "Alerts, sounds, and previews"
      case .diagnostics:
        "Server-owned diagnostics guidance"
    }
  }

  var icon: String {
    switch self {
      case .workspace:
        "slider.horizontal.3"
      case .integrations:
        "puzzlepiece.extension"
      case .missionControl:
        "antenna.radiowaves.left.and.right"
      case .servers:
        "server.rack"
      case .notifications:
        "bell.badge"
      case .diagnostics:
        "stethoscope"
    }
  }
}

struct SettingsView: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(\.dismiss) private var dismiss
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  private let showsCloseButton: Bool
  @State private var selectedPane: SettingsPane = .workspace

  init(showsCloseButton: Bool = false) {
    self.showsCloseButton = showsCloseButton
  }

  private var endpointHealthSummary: SettingsEndpointHealthSummary {
    SettingsEndpointHealthSummary.current(for: runtimeRegistry)
  }

  private var endpointHealthColor: Color {
    endpointHealthSummary.color
  }

  private var usesCompactLayout: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  var body: some View {
    Group {
      if usesCompactLayout {
        compactLayout
      } else {
        splitLayout
      }
    }
    #if os(macOS)
    .frame(width: 900, height: 620)
    #else
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    #endif
    .background(
      ZStack {
        Color.backgroundPrimary
        Rectangle()
          .fill(Color.backgroundSecondary.opacity(0.32))
          .frame(height: 148)
          .frame(maxHeight: .infinity, alignment: .top)
      }
    )
    .animation(Motion.standard, value: selectedPane)
  }

  private var splitLayout: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
        .foregroundStyle(Color.panelBorder)
      detailPane
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("OrbitDock")
          .font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.accent)
        Text("Preferences")
          .font(.system(size: TypeScale.headline, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textPrimary)
      }

      VStack(spacing: Spacing.sm) {
        ForEach(SettingsPane.allCases) { pane in
          SettingsSidebarButton(
            title: pane.title,
            subtitle: pane.subtitle,
            icon: pane.icon,
            isSelected: selectedPane == pane
          ) {
            selectedPane = pane
          }
        }
      }

      Spacer()

      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.sm) {
          Circle()
            .fill(endpointHealthColor)
            .frame(width: 7, height: 7)
          Text("Endpoint Health")
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
        }

        Text(endpointHealthSummary.shortText)
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color.backgroundTertiary.opacity(OpacityTier.vivid),
        in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      )
    }
    .padding(Spacing.section)
    .frame(width: 260)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(Color.backgroundSecondary.opacity(0.8))
  }

  private var compactLayout: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xl) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("OrbitDock")
              .font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.accent)

            Text("Settings")
              .font(.system(size: TypeScale.chatHeading2, weight: .bold, design: .rounded))
              .foregroundStyle(Color.textPrimary)

            Text("Configure OrbitDock for this device and the servers you keep in flight.")
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textSecondary)
          }

          compactHealthSummaryCard

          VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(SettingsPane.allCases) { pane in
              NavigationLink(value: pane) {
                SettingsNavigationCard(
                  title: pane.title,
                  subtitle: pane.subtitle,
                  icon: pane.icon,
                  detail: paneDetailText(for: pane),
                  detailColor: paneDetailColor(for: pane)
                )
              }
              .buttonStyle(.plain)
            }
          }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.xxl)
      }
      .modifier(CompactNavigationChrome(showsCloseButton: showsCloseButton, dismiss: dismiss))
      .navigationDestination(for: SettingsPane.self) { pane in
        compactDetailPane(for: pane)
      }
    }
  }

  private var detailPane: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.md_) {
        Text(selectedPane.title)
          .font(.system(size: TypeScale.chatHeading2, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textPrimary)
        Text(selectedPane.subtitle)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
        Spacer()
        #if os(iOS)
          if showsCloseButton {
            Button("Done") {
              dismiss()
            }
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.accent)
          }
        #endif
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.top, Spacing.section)
      .padding(.bottom, Spacing.lg)

      Divider()
        .foregroundStyle(Color.panelBorder)

      paneContent(for: selectedPane)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func paneContent(for pane: SettingsPane) -> some View {
    switch pane {
      case .workspace:
        GeneralSettingsView()
      case .integrations:
        SetupSettingsView(serverState: runtimeRegistry.activeSessionStore)
      case .missionControl:
        MissionControlDefaultsView()
      case .servers:
        DebugSettingsView()
      case .notifications:
        NotificationSettingsView()
      case .diagnostics:
        DiagnosticsSettingsView()
    }
  }

  private var compactHealthSummaryCard: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Circle()
          .fill(endpointHealthColor)
          .frame(width: 8, height: 8)

        Text("Server Health")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)

        Spacer()

        Text(endpointHealthSummary.shortText)
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
          .foregroundStyle(endpointHealthColor)
      }

      Text("Jump into Servers when you need to reconnect endpoints, change channels, or run an upgrade.")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textTertiary)
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(Color.panelBorder, lineWidth: 1)
    )
  }

  private func paneDetailText(for pane: SettingsPane) -> String? {
    switch pane {
      case .servers:
        endpointHealthSummary.shortText
      default:
        nil
    }
  }

  private func paneDetailColor(for pane: SettingsPane) -> Color {
    switch pane {
      case .servers:
        endpointHealthColor
      default:
        Color.textTertiary
    }
  }

  private func compactDetailPane(for pane: SettingsPane) -> some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(pane.subtitle)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)

        if let detail = paneDetailText(for: pane) {
          HStack(spacing: Spacing.sm_) {
            Circle()
              .fill(paneDetailColor(for: pane))
              .frame(width: 7, height: 7)

            Text(detail)
              .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
              .foregroundStyle(paneDetailColor(for: pane))
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.section)
      .padding(.top, Spacing.md)
      .padding(.bottom, Spacing.lg)
      .background(Color.backgroundSecondary.opacity(0.88))

      Divider()
        .foregroundStyle(Color.panelBorder)

      paneContent(for: pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationTitle(pane.title)
    .modifier(CompactNavigationChrome(showsCloseButton: showsCloseButton, dismiss: dismiss))
  }
}

private struct CompactNavigationChrome: ViewModifier {
  let showsCloseButton: Bool
  let dismiss: DismissAction

  func body(content: Content) -> some View {
    #if os(iOS)
      content
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if showsCloseButton {
            ToolbarItem(placement: .topBarTrailing) {
              Button("Done") {
                dismiss()
              }
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(Color.accent)
            }
          }
        }
    #else
      content
    #endif
  }
}

// MARK: - Preview

#if os(macOS)
  #Preview {
    let preview = PreviewRuntime(scenario: .settings)
    preview.inject(SettingsView())
      .preferredColorScheme(.dark)
  }
#else
  #Preview {
    let preview = PreviewRuntime(scenario: .settings)
    preview.inject(SettingsView())
      .preferredColorScheme(.dark)
  }
#endif
