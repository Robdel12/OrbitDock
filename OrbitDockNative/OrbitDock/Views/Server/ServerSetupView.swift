//
//  ServerSetupView.swift
//  OrbitDock
//
//  First-launch onboarding — "Establishing Connection to Mission Control"
//  orbital beacon hero moment with terminal-styled connection form.
//  Works on both macOS and iOS as a pure server-connected client.
//

import SwiftUI

// MARK: - Beacon Phase

enum BeaconPhase {
  case idle, connecting, connected, failed
}

struct ServerSetupView: View {
  @Environment(OrbitDockAppRuntime.self) private var appRuntime
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  @State private var host: String = ServerSetupViewPlanner.defaultHost()
  @State private var authToken: String = ""
  @State private var isConnecting = false
  @State private var connectionError: String?
  @State private var beaconPhase: BeaconPhase = .idle

  private let endpointSettings: ServerEndpointSettingsClient

  init(endpointSettings: ServerEndpointSettingsClient? = nil) {
    self.endpointSettings = endpointSettings ?? .live()
  }

  private var canConnect: Bool {
    ServerSetupViewPlanner.canConnect(host: host, authToken: authToken)
  }

  // MARK: - Derived Beacon Phase

  private var derivedBeaconPhase: BeaconPhase {
    if connectionError != nil { return .failed }
    if isConnecting {
      // Check if any endpoint has reached .connected
      let hasConnected = runtimeRegistry.connectionStatusByEndpointId.values.contains(where: {
        if case .connected = $0 { return true }
        return false
      })
      return hasConnected ? .connected : .connecting
    }
    return .idle
  }

  // MARK: - Edge Bar Color

  private var edgeBarColor: Color {
    switch beaconPhase {
      case .idle: Color.accent
      case .connecting: Color.accent
      case .connected: Color.feedbackPositive
      case .failed: Color.statusPermission
    }
  }

  // MARK: - Body

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        Spacer(minLength: Spacing.xxl)

        orbitalBeacon

        titleSection

        connectionForm
          .frame(maxWidth: 420)

        serverHelpSection
          .frame(maxWidth: 420)

        demoModeButton

        Spacer(minLength: Spacing.xxl)
      }
      .padding(.horizontal, Spacing.xl)
      .frame(maxWidth: .infinity)
    }
    .background(Color.backgroundPrimary)
    .onChange(of: isConnecting) { updateBeaconPhase() }
    .onChange(of: connectionError) { updateBeaconPhase() }
    .onChange(of: runtimeRegistry.connectionStatusByEndpointId) { updateBeaconPhase() }
  }

  private func updateBeaconPhase() {
    let newPhase = derivedBeaconPhase
    if newPhase != beaconPhase {
      withAnimation(newPhase == .connected ? Motion.bouncy : Motion.standard) {
        beaconPhase = newPhase
      }
    }
  }

  // MARK: - Orbital Beacon

  private var orbitalBeacon: some View {
    ZStack {
      // Outer ring — 120pt stroke
      Circle()
        .stroke(Color.accent.opacity(beaconRingOpacity(tier: .outer)), lineWidth: 1.5)
        .frame(width: 120, height: 120)
        .scaleEffect(beaconPhase == .connected ? 1.08 : 1.0)

      // Middle ring — 88pt stroke
      Circle()
        .stroke(Color.accent.opacity(beaconRingOpacity(tier: .middle)), lineWidth: 1.5)
        .frame(width: 88, height: 88)
        .scaleEffect(beaconPhase == .connected ? 1.05 : 1.0)

      // Inner circle — 56pt fill
      Circle()
        .fill(Color.accent.opacity(beaconRingOpacity(tier: .inner)))
        .frame(width: 56, height: 56)
        .themeShadow(
          beaconPhase == .connected
            ? Shadow.glow(color: .feedbackPositive, intensity: 0.6)
            : ShadowToken(color: .clear, radius: 0, x: 0, y: 0)
        )

      // Center icon
      Image(systemName: beaconIconName)
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(beaconIconColor)
        .contentTransition(.symbolEffect(.replace))
    }
    .opacity(beaconPulseOpacity)
    .animation(
      beaconPhase == .connecting
        ? .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
        : .default,
      value: beaconPhase
    )
  }

  private enum RingTier { case outer, middle, inner }

  private func beaconRingOpacity(tier: RingTier) -> Double {
    switch beaconPhase {
      case .idle:
        switch tier {
          case .outer: OpacityTier.tint
          case .middle: OpacityTier.subtle
          case .inner: OpacityTier.subtle
        }
      case .connecting:
        switch tier {
          case .outer: OpacityTier.light
          case .middle: OpacityTier.medium
          case .inner: OpacityTier.medium
        }
      case .connected:
        switch tier {
          case .outer: OpacityTier.strong
          case .middle: OpacityTier.vivid
          case .inner: OpacityTier.strong
        }
      case .failed:
        switch tier {
          case .outer: OpacityTier.light
          case .middle: OpacityTier.subtle
          case .inner: OpacityTier.subtle
        }
    }
  }

  private var beaconIconName: String {
    switch beaconPhase {
      case .idle, .connecting: "antenna.radiowaves.left.and.right"
      case .connected: "checkmark"
      case .failed: "xmark"
    }
  }

  private var beaconIconColor: Color {
    switch beaconPhase {
      case .idle: Color.accent.opacity(0.5)
      case .connecting: Color.accent
      case .connected: Color.feedbackPositive
      case .failed: Color.statusPermission
    }
  }

  private var beaconPulseOpacity: Double {
    switch beaconPhase {
      case .idle: 1.0
      case .connecting: 0.7 // will animate to 1.0 via repeatForever
      case .connected: 1.0
      case .failed: 1.0
    }
  }

  // MARK: - Title Section

  private var titleSection: some View {
    VStack(spacing: Spacing.md) {
      Text("Welcome to OrbitDock")
        .font(.system(size: TypeScale.headline, weight: .bold))
        .foregroundStyle(Color.textPrimary)

      Text("Your AI coding sessions, organized and observable. Connect to your server to get started.")
        .font(.system(size: TypeScale.subhead))
        .foregroundStyle(Color.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)
    }
  }

  // MARK: - Terminal-styled Connection Form

  private var connectionForm: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Host field
      terminalField(icon: "globe", placeholder: "10.0.0.5:4000 or https://host.example") {
        TextField("10.0.0.5:4000 or https://host.example", text: $host)
          .textFieldStyle(.plain)
          .font(.system(size: TypeScale.body, design: .monospaced))
        #if os(iOS)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        #endif
          .autocorrectionDisabled()
          .foregroundStyle(Color.textPrimary)
      }

      accentDivider

      // Auth token field
      terminalField(icon: "key.fill", placeholder: "Paste auth token") {
        SecureField("Paste auth token", text: $authToken)
          .textFieldStyle(.plain)
          .font(.system(size: TypeScale.body, design: .monospaced))
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
          .autocorrectionDisabled()
          .foregroundStyle(Color.textPrimary)
      }

      // Helper text
      Text("Paste the auth token generated by your OrbitDock server or CLI.")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.md)
        .padding(.top, -Spacing.xs)

      accentDivider

      // Connect button
      Button {
        connect()
      } label: {
        HStack(spacing: Spacing.sm) {
          if isConnecting {
            ProgressView()
              .controlSize(.small)
          }
          Text("Establish Connection")
            .font(.system(size: TypeScale.body, weight: .semibold))
        }
        .foregroundStyle(canConnect ? Color.textPrimary : Color.textQuaternary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
      }
      .buttonStyle(.plain)
      .disabled(!canConnect || isConnecting)

      // Error banner
      if let connectionError {
        errorBanner(connectionError)
      }
    }
    .background(
      Color.backgroundSecondary,
      in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.panelBorder, lineWidth: 1)
    )
    .overlay(alignment: .leading) {
      UnevenRoundedRectangle(
        topLeadingRadius: Radius.lg,
        bottomLeadingRadius: Radius.lg,
        bottomTrailingRadius: 0,
        topTrailingRadius: 0
      )
      .fill(edgeBarColor)
      .frame(width: EdgeBar.width)
      .themeShadow(
        (beaconPhase == .connecting || beaconPhase == .connected)
          ? Shadow.glow(color: edgeBarColor, intensity: 0.6)
          : ShadowToken(color: .clear, radius: 0, x: 0, y: 0)
      )
    }
  }

  // MARK: - Terminal Field

  private func terminalField(
    icon: String,
    placeholder: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: icon)
        .font(.system(size: IconScale.lg))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 20)

      content()
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  // MARK: - Accent Divider

  private var accentDivider: some View {
    Rectangle()
      .fill(Color.accent.opacity(OpacityTier.light))
      .frame(height: 1)
  }

  // MARK: - Server Help

  private var serverHelpSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Need a server?")
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      Text(
        "Install OrbitDock on your Mac or Linux machine, then connect using its IP address. Review the script before running — it's open source."
      )
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textSecondary)

      codePill(
        "curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash"
      )
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Demo Mode

  private var demoModeButton: some View {
    Button {
      appRuntime.enterDemoMode()
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "play.circle")
          .font(.system(size: TypeScale.body))
        Text("Try demo mode")
          .font(.system(size: TypeScale.body))
      }
      .foregroundStyle(Color.accent)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Shared Components

  private func errorBanner(_ message: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11))
        .foregroundStyle(Color.statusPermission)
      Text(message)
        .foregroundStyle(Color.statusPermission)
        .font(.system(size: TypeScale.caption, weight: .medium))
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.statusPermission.opacity(OpacityTier.light),
      in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
    )
    .padding(.horizontal, Spacing.md)
    .padding(.bottom, Spacing.md)
  }

  // MARK: - Code Pill

  private func codePill(_ text: String) -> some View {
    Text(text)
      .font(.system(size: TypeScale.caption, design: .monospaced))
      .foregroundStyle(Color.accent)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        Color.accent.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
      )
      .textSelection(.enabled)
  }

  // MARK: - Actions

  private func connect() {
    connectionError = nil
    isConnecting = true

    let result = ServerSetupViewPlanner.buildEndpoint(
      host: host,
      authToken: authToken,
      existingEndpoints: endpointSettings.endpoints(),
      defaultPort: endpointSettings.defaultPort,
      buildURL: endpointSettings.buildURL
    )

    switch result {
      case let .success(endpoints):
        endpointSettings.saveEndpoints(endpoints)
        runtimeRegistry.configureFromSettings(startEnabled: true)
        // Auto-transition happens via AppWindowPlanner once connectedRuntimeCount > 0.
        // If connection fails, the runtime status will show the error.

      case let .failure(error):
        connectionError = error.message
        isConnecting = false
    }
  }

}

#Preview {
  let preview = PreviewRuntime(scenario: .serverSetup)
  preview.inject(ServerSetupView())
    .frame(width: 600, height: 600)
    .preferredColorScheme(.dark)
}
