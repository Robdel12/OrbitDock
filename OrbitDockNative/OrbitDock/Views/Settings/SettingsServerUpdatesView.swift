import SwiftUI

struct ServerUpdatesSettingsView: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @State private var model = ServerUpdatesSettingsModel()

  private var orderedRuntimes: [ServerRuntime] {
    runtimeRegistry.runtimes.sorted { lhs, rhs in
      lhs.endpoint.name.localizedCaseInsensitiveCompare(rhs.endpoint.name) == .orderedAscending
    }
  }

  private var runtimesIdentity: String {
    orderedRuntimes
      .map { "\($0.id.uuidString):\($0.endpoint.name):\($0.endpoint.isEnabled)" }
      .joined(separator: "|")
  }

  private var runtimeConnectionIdentity: String {
    orderedRuntimes
      .map { runtime in
        let status = runtimeRegistry.displayConnectionStatus(for: runtime.id)
        return "\(runtime.id.uuidString):\(connectionStatusIdentity(status))"
      }
      .joined(separator: "|")
  }

  var body: some View {
    SettingsSection(title: "SERVER UPDATES", icon: "arrow.triangle.2.circlepath") {
      if orderedRuntimes.isEmpty {
        Text("Add a server endpoint to manage update channels and install new OrbitDock server releases.")
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
      } else {
        VStack(spacing: Spacing.md) {
          ForEach(orderedRuntimes, id: \.id) { runtime in
            endpointCard(runtime)
          }
        }
      }
    }
    .task(id: runtimesIdentity) {
      await model.reload(for: orderedRuntimes)
    }
    .task(id: runtimeConnectionIdentity) {
      await model.handleConnectionChanges(for: orderedRuntimes)
    }
  }

  private func endpointCard(_ runtime: ServerRuntime) -> some View {
    let state = model.state(for: runtime.id)
    let channelSelection = Binding<ServerUpdateChannelOption>(
      get: {
        ServerUpdateChannelOption(rawValue: state.selectedChannel) ?? .stable
      },
      set: { newValue in
        Task {
          await model.setChannel(newValue, for: runtime)
        }
      }
    )

    return VStack(alignment: .leading, spacing: Spacing.md) {
      ViewThatFits(in: .horizontal) {
        endpointHeaderRow(runtime: runtime, state: state)
        endpointHeaderStacked(runtime: runtime, state: state)
      }

      ViewThatFits(in: .horizontal) {
        controlsRow(runtime: runtime, state: state, channelSelection: channelSelection)
        VStack(alignment: .leading, spacing: Spacing.md) {
          channelControl(selection: channelSelection, state: state)
          checkButton(runtime: runtime, state: state)
          upgradeButton(runtime: runtime, state: state)
        }
      }

      if let status = state.updateStatus {
        HStack(spacing: Spacing.sm) {
          Text("Checked")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Text(checkedAtLabel(status.checkedAt))
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)

          Spacer()

          if let releaseURL = releaseURL(for: status) {
            Link("Release Notes", destination: releaseURL)
              .font(.system(size: TypeScale.meta, weight: .semibold))
              .foregroundStyle(Color.accent)
          }
        }
      }

      if let infoMessage = state.infoMessage {
        messageBanner(
          infoMessage,
          color: Color.feedbackPositive,
          icon: "info.circle.fill"
        )
      }

      if let errorMessage = state.errorMessage {
        messageBanner(
          errorMessage,
          color: Color.statusPermission,
          icon: "exclamationmark.triangle.fill"
        )
      }
    }
    .padding(Spacing.lg)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.panelBorder, lineWidth: 1)
    )
  }

  @ViewBuilder
  private func endpointHeaderRow(
    runtime: ServerRuntime,
    state: ServerUpdatesSettingsModel.EndpointState
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
      Circle()
        .fill(supportColor(for: state.support))
        .frame(width: 8, height: 8)

      Text(runtime.endpoint.name)
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)
        .truncationMode(.tail)

      Text(versionLabel(for: state))
        .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)

      Spacer()

      updateStateBadge(for: state)
    }
  }

  @ViewBuilder
  private func endpointHeaderStacked(
    runtime: ServerRuntime,
    state: ServerUpdatesSettingsModel.EndpointState
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
        Circle()
          .fill(supportColor(for: state.support))
          .frame(width: 8, height: 8)

        Text(runtime.endpoint.name)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(2)

        Text(versionLabel(for: state))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
      }

      updateStateBadge(for: state)
    }
  }

  @ViewBuilder
  private func updateStateBadge(for state: ServerUpdatesSettingsModel.EndpointState) -> some View {
    if state.isUpgradeInFlight {
      inFlightBadge()
    } else if let status = state.updateStatus {
      updateBadge(status)
    }
  }

  private func supportColor(for support: ServerUpdatesSettingsModel.SupportState) -> Color {
    switch support {
      case .idle, .loading:
        Color.statusQuestion
      case .supported:
        Color.feedbackPositive
      case .disconnected, .failed:
        Color.statusPermission
    }
  }

  private func versionLabel(for state: ServerUpdatesSettingsModel.EndpointState) -> String {
    if let version = state.currentVersion, !version.isEmpty {
      return "v\(version)"
    }
    return "version unknown"
  }

  private func canUpgrade(_ state: ServerUpdatesSettingsModel.EndpointState) -> Bool {
    guard state.support == .supported else { return false }
    guard let status = state.updateStatus else { return false }
    return status.updateAvailable && status.latestVersion != nil
  }

  private func upgradeButtonTitle(for state: ServerUpdatesSettingsModel.EndpointState) -> String {
    if state.isStartingUpgrade {
      return "Starting..."
    }
    switch state.upgradePhase {
      case .waitingForRestart:
        return "Restarting..."
      case .verifying:
        return "Verifying..."
      case .idle:
        break
    }

    guard state.support == .supported else {
      return "Upgrade Unavailable"
    }
    guard let status = state.updateStatus else {
      return "Check First"
    }
    guard status.updateAvailable else {
      return "Up To Date"
    }
    if let latestVersion = status.latestVersion {
      return "Upgrade to \(latestVersion)"
    }
    return "Upgrade"
  }

  @ViewBuilder
  private func controlsRow(
    runtime: ServerRuntime,
    state: ServerUpdatesSettingsModel.EndpointState,
    channelSelection: Binding<ServerUpdateChannelOption>
  ) -> some View {
    HStack(spacing: Spacing.md) {
      channelControl(selection: channelSelection, state: state)
      Spacer()
      checkButton(runtime: runtime, state: state)
      upgradeButton(runtime: runtime, state: state)
    }
  }

  @ViewBuilder
  private func channelControl(
    selection: Binding<ServerUpdateChannelOption>,
    state: ServerUpdatesSettingsModel.EndpointState
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text("Channel")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
      Picker("Update Channel", selection: selection) {
        ForEach(ServerUpdateChannelOption.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.menu)
      .disabled(state.support != .supported || state.isChangingChannel || state.isUpgradeInFlight)
    }
  }

  @ViewBuilder
  private func checkButton(
    runtime: ServerRuntime,
    state: ServerUpdatesSettingsModel.EndpointState
  ) -> some View {
    Button {
      Task {
        await model.refresh(runtime, forceCheck: true)
      }
    } label: {
      HStack(spacing: Spacing.sm_) {
        if state.isChecking {
          ProgressView()
            .controlSize(.small)
        }
        Text("Check Now")
          .lineLimit(1)
      }
    }
    .buttonStyle(.bordered)
    .disabled(state.support == .loading || state.isChangingChannel || state.isUpgradeInFlight)
  }

  @ViewBuilder
  private func upgradeButton(
    runtime: ServerRuntime,
    state: ServerUpdatesSettingsModel.EndpointState
  ) -> some View {
    Button {
      Task {
        await model.startUpgrade(for: runtime)
      }
    } label: {
      HStack(spacing: Spacing.sm_) {
        if state.isStartingUpgrade || state.upgradePhase != .idle {
          ProgressView()
            .controlSize(.small)
        }
        Text(upgradeButtonTitle(for: state))
          .lineLimit(1)
      }
    }
    .buttonStyle(.borderedProminent)
    .tint(Color.accent)
    .disabled(!canUpgrade(state) || state.isChecking || state.isChangingChannel || state.isUpgradeInFlight)
  }

  @ViewBuilder
  private func updateBadge(_ status: ServerUpdateStatus) -> some View {
    let color = status.updateAvailable ? Color.statusQuestion : Color.feedbackPositive
    let icon = status.updateAvailable ? "arrow.up.circle.fill" : "checkmark.circle.fill"
    let label = status.updateAvailable
      ? "Update Available"
      : "Up To Date"

    HStack(spacing: Spacing.gap) {
      Image(systemName: icon)
        .font(.system(size: IconScale.sm, weight: .semibold))
      Text(label)
        .font(.system(size: TypeScale.mini, weight: .semibold))
    }
    .foregroundStyle(color)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.gap)
    .background(color.opacity(OpacityTier.light), in: Capsule())
  }

  @ViewBuilder
  private func inFlightBadge() -> some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
        .font(.system(size: IconScale.sm, weight: .semibold))
      Text("Restarting")
        .font(.system(size: TypeScale.mini, weight: .semibold))
    }
    .foregroundStyle(Color.statusQuestion)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.gap)
    .background(Color.statusQuestion.opacity(OpacityTier.light), in: Capsule())
  }

  @ViewBuilder
  private func messageBanner(
    _ text: String,
    color: Color,
    icon: String
  ) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.lg))
        .foregroundStyle(color)

      Text(text)
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(Spacing.md)
    .background(color.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(color.opacity(OpacityTier.subtle), lineWidth: 1)
    )
  }

  private func checkedAtLabel(_ rawValue: String?) -> String {
    relativeServerUpdateCheckedAtLabel(rawValue)
  }

  private func releaseURL(for status: ServerUpdateStatus) -> URL? {
    guard let rawValue = status.releaseURL else { return nil }
    return URL(string: rawValue)
  }
}
