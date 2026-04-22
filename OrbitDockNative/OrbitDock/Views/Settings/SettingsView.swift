//
//  SettingsView.swift
//  OrbitDock
//
//  Settings/Preferences window - Cosmic Harbor theme
//

import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
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
  @Environment(OrbitDockAppRuntime.self) private var appRuntime
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AppRouter.self) private var router
  @State private var selectedPane: SettingsPane

  init(initialPane: SettingsPane = .workspace) {
    _selectedPane = State(initialValue: initialPane)
  }

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

  var body: some View {
    Group {
      #if os(macOS)
        splitLayout
      #else
        compactLayout
      #endif
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.backgroundPrimary)
    .animation(Motion.standard, value: selectedPane)
    .onChange(of: appRuntime.requestedSettingsPane) { _, newPane in
      if selectedPane != newPane {
        selectedPane = newPane
      }
    }
  }

  private var splitLayout: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
    } detail: {
      detailPane
    }
    .navigationSplitViewStyle(.prominentDetail)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      sidebarHeader
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.md)

      ScrollView {
        VStack(spacing: Spacing.xs) {
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
        .padding(.horizontal, Spacing.md)
      }

      Spacer(minLength: Spacing.md)

      endpointHealthCard
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.lg)
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(Color.backgroundSecondary)
  }

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("OrbitDock")
        .font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.accent)
      Text("Preferences")
        .font(.system(size: TypeScale.headline, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textPrimary)
    }
  }

  private var endpointHealthCard: some View {
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

  #if os(iOS)
    private var compactLayout: some View {
      NavigationStack {
        List {
          ForEach(SettingsPane.allCases) { pane in
            NavigationLink(value: pane) {
              Label {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text(pane.title)
                    .font(.system(size: TypeScale.body, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                  Text(pane.subtitle)
                    .font(.system(size: TypeScale.meta))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                }
              } icon: {
                Image(systemName: pane.icon)
                  .font(.system(size: TypeScale.body, weight: .semibold))
                  .foregroundStyle(Color.accent)
              }
            }
            .listRowBackground(Color.backgroundSecondary)
          }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              router.goBack(source: .unspecified)
            }
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.accent)
          }
        }
        .navigationDestination(for: SettingsPane.self) { pane in
          compactDetailView(for: pane)
        }
      }
    }

    @ViewBuilder
    private func compactDetailView(for pane: SettingsPane) -> some View {
      settingsContent(for: pane)
      .navigationTitle(pane.title)
      .navigationBarTitleDisplayMode(.inline)
      .background(Color.backgroundPrimary)
    }
  #endif

  private var detailPane: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
        Text(selectedPane.title)
          .font(.system(size: TypeScale.headline, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textPrimary)
        Text(selectedPane.subtitle)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
        Spacer()
        Button("Done") {
          router.goBack(source: .unspecified)
        }
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.accent)
        .buttonStyle(.plain)
      }
      .padding(.horizontal, Spacing.section)
      .padding(.vertical, Spacing.md)

      Divider()
        .foregroundStyle(Color.panelBorder)

      settingsContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var settingsContent: some View {
    settingsContent(for: selectedPane)
  }

  @ViewBuilder
  private func settingsContent(for pane: SettingsPane) -> some View {
    switch pane {
      case .workspace:
        GeneralSettingsView()
      case .integrations:
        SetupSettingsView(endpointStore: runtimeRegistry.activeEndpointStore)
      case .missionControl:
        MissionControlDefaultsView()
      case .servers:
        ServersSettingsView()
      case .notifications:
        NotificationSettingsView()
      case .diagnostics:
        DiagnosticsSettingsView()
    }
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
