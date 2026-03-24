//
//  SettingsView.swift
//  OrbitDock
//
//  Settings/Preferences window - Cosmic Harbor theme
//

import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
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
        "Updates, editor, and local dictation"
      case .integrations:
        "Claude hooks and Codex account"
      case .missionControl:
        "API keys, provider defaults"
      case .servers:
        "Endpoints, runtime, and connection"
      case .notifications:
        "Alerts, sounds, and previews"
      case .diagnostics:
        "Logs, database, and support paths"
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

  #if os(macOS)
    let appUpdater: AppUpdater?
  #endif
  private let showsCloseButton: Bool
  @State private var selectedPane: SettingsPane = .workspace

  #if os(macOS)
    init(appUpdater: AppUpdater? = nil, showsCloseButton: Bool = false) {
      self.appUpdater = appUpdater
      self.showsCloseButton = showsCloseButton
    }
  #else
    init(showsCloseButton: Bool = false) {
      self.showsCloseButton = showsCloseButton
    }
  #endif

  private var endpointHealthSummary: SettingsEndpointHealthSummary {
    let endpointCount = runtimeRegistry.runtimes.count
    let enabledEndpointCount = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled).count
    let connectedEndpointCount = runtimeRegistry.runtimes.filter { runtime in
      let status = runtimeRegistry.displayConnectionStatus(for: runtime.endpoint.id)
      if case .connected = status {
        return true
      }
      return false
    }.count

    return SettingsEndpointHealthSummary.make(
      endpointCount: endpointCount,
      enabledEndpointCount: enabledEndpointCount,
      connectedEndpointCount: connectedEndpointCount
    )
  }

  private var endpointHealthColor: Color {
    switch endpointHealthSummary.tone {
      case .positive:
        Color.feedbackPositive
      case .mixed:
        Color.statusQuestion
      case .warning:
        Color.statusPermission
    }
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
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.md_) {
        Text("Preferences")
          .font(.system(size: TypeScale.chatHeading2, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textPrimary)
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
      .padding(.horizontal, Spacing.section)
      .padding(.top, Spacing.lg)
      .padding(.bottom, Spacing.md)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Spacing.sm) {
          ForEach(SettingsPane.allCases) { pane in
            Button {
              selectedPane = pane
            } label: {
              HStack(spacing: Spacing.sm_) {
                Image(systemName: pane.icon)
                  .font(.system(size: TypeScale.micro, weight: .semibold))
                Text(pane.title)
                  .font(.system(size: TypeScale.meta, weight: .semibold))
              }
              .foregroundStyle(selectedPane == pane ? Color.accent : Color.textSecondary)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm)
              .background(
                Capsule(style: .continuous)
                  .fill(selectedPane == pane ? Color.surfaceSelected : Color.backgroundTertiary.opacity(0.8))
              )
              .overlay(
                Capsule(style: .continuous)
                  .strokeBorder(selectedPane == pane ? Color.surfaceBorder : Color.clear, lineWidth: 1)
              )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, Spacing.section)
      }
      .padding(.bottom, Spacing.md)

      Divider()
        .foregroundStyle(Color.panelBorder)

      Group {
        switch selectedPane {
          case .workspace:
            #if os(macOS)
              GeneralSettingsView(appUpdater: appUpdater ?? nil)
            #else
              GeneralSettingsView()
            #endif
          case .integrations:
            SetupSettingsView()
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
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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

      Group {
        switch selectedPane {
          case .workspace:
            #if os(macOS)
              GeneralSettingsView(appUpdater: appUpdater ?? nil)
            #else
              GeneralSettingsView()
            #endif
          case .integrations:
            SetupSettingsView()
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
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

// MARK: - Preview

#if os(macOS)
  #Preview {
    let preview = PreviewRuntime(scenario: .settings)
    preview.inject(SettingsView(appUpdater: AppUpdater()))
      .preferredColorScheme(.dark)
  }
#else
  #Preview {
    let preview = PreviewRuntime(scenario: .settings)
    preview.inject(SettingsView())
      .preferredColorScheme(.dark)
  }
#endif
