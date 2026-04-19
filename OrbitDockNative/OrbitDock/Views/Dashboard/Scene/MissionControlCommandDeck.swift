import SwiftUI

struct MissionControlCommandDeck: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let groups: [ConversationProjectGroup]
  let hasMultipleEndpoints: Bool
  @Binding var projectFilter: String?
  let selectedIndex: Int

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var selectedConversationID: String? {
    let conversations = groups.flatMap(\.sortedConversations)
    guard selectedIndex >= 0, selectedIndex < conversations.count else { return nil }
    return conversations[selectedIndex].id
  }

  var body: some View {
    if groups.isEmpty {
      emptyState
    } else {
      conversationFeed
    }
  }

  private var conversationFeed: some View {
    VStack(alignment: .leading, spacing: Spacing.xxl) {
      ForEach(groups) { group in
        ConversationProjectSection(
          group: group,
          showEndpointName: hasMultipleEndpoints,
          selectedConversationID: selectedConversationID,
          projectFilter: $projectFilter,
          layoutMode: layoutMode
        )
      }
    }
  }

  private var emptyState: some View {
    let emptyState = emptyStateCopy

    return VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(emptyState.title)
        .font(.system(size: TypeScale.large, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Text(emptyState.message)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
            .stroke(Color.surfaceBorder, lineWidth: 1)
        )
    )
  }

  private var emptyStateCopy: (title: String, message: String) {
    let statuses = runtimeRegistry.runtimes
      .filter(\.endpoint.isEnabled)
      .map { runtimeRegistry.displayConnectionStatus(for: $0.endpoint.id) }

    if let message = statuses.compactMap(\.failureMessage).first(where: \.isCompatibilityGuidance) {
      return (
        "Server upgrade required",
        "\(message) Open Server Settings to reconnect to a newer OrbitDock server."
      )
    }

    if statuses.contains(where: \.isConnectingLike) {
      return (
        "Connecting to server",
        "OrbitDock is waiting for the dashboard snapshot before showing sessions."
      )
    }

    if statuses.contains(where: \.isUnavailable) {
      return (
        "Server unavailable",
        "OrbitDock couldn't load session data from the configured server. Check Server Settings, then try reconnecting."
      )
    }

    return (
      "All clear",
      "No active conversations in this view. Start a session or adjust your filters."
    )
  }

}

private extension ConnectionStatus {
  var failureMessage: String? {
    guard case let .failed(message) = self else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var isConnectingLike: Bool {
    switch self {
      case .connecting:
        true
      default:
        false
    }
  }

  var isUnavailable: Bool {
    switch self {
      case .disconnected, .failed:
        true
      case .connecting, .connected:
        false
    }
  }
}

private extension String {
  var isCompatibilityGuidance: Bool {
    let normalized = lowercased()
    return normalized.contains("compatible")
      || normalized.contains("compatibility")
      || normalized.contains("upgrade")
      || normalized.contains("too old")
  }
}
