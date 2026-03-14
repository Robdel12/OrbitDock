//
//  McpServersTab.swift
//  OrbitDock
//
//  MCP server list with status indicators and expandable tool details.
//  Shown as a tab in CodexTurnSidebar.
//

import SwiftUI

struct McpCapabilityNotice: Equatable {
  enum Style: Equatable {
    case informational
    case success
    case caution
  }

  let title: String
  let message: String
  let badge: String
  let iconName: String
  let style: Style
}

struct CodexCapabilityNoticeCard: View {
  let notice: McpCapabilityNotice

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      ZStack {
        Circle()
          .fill(noticeTint.opacity(0.16))
          .frame(width: 28, height: 28)

        Image(systemName: notice.iconName)
          .font(.system(size: TypeScale.meta, weight: .semibold))
          .foregroundStyle(noticeTint)
      }

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.xs) {
          Text(notice.title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(notice.badge)
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(noticeTint)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(noticeTint.opacity(0.14), in: Capsule())
        }

        Text(notice.message)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.72))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(noticeTint.opacity(0.18), lineWidth: 1)
    )
  }

  private var noticeTint: Color {
    switch notice.style {
      case .informational:
        return .accent
      case .success:
        return .feedbackPositive
      case .caution:
        return .feedbackCaution
    }
  }
}

enum McpServersTabPlanner {
  static func capabilityNotice(
    provider: Provider,
    codexAccountStatus: ServerCodexAccountStatus?
  ) -> McpCapabilityNotice? {
    guard provider == .codex else { return nil }

    switch codexAccountStatus?.account {
      case .apiKey?:
        return McpCapabilityNotice(
          title: "API Key Session",
          message: "Some Codex app-backed MCP servers only show up with ChatGPT sign-in. If a capability feels missing, check your Codex account mode first.",
          badge: "API Key",
          iconName: "key.fill",
          style: .caution
        )
      case .chatgpt?:
        return McpCapabilityNotice(
          title: "ChatGPT Connected",
          message: "This session is using your ChatGPT-linked Codex account, so app-backed MCP availability should match what Codex can access.",
          badge: "ChatGPT",
          iconName: "sparkles",
          style: .success
        )
      case .none:
        guard codexAccountStatus?.requiresOpenaiAuth == true else { return nil }
        return McpCapabilityNotice(
          title: "ChatGPT Sign-In Needed",
          message: "Sign in with ChatGPT to unlock Codex-managed apps and MCP servers in OrbitDock.",
          badge: "Not Connected",
          iconName: "person.crop.circle.badge.exclamationmark",
          style: .informational
        )
    }
  }
}

struct McpServersTab: View {
  let sessionId: String

  @Environment(SessionStore.self) private var serverState
  @State private var expandedServers: Set<String> = []

  private var startupState: McpStartupState? {
    serverState.session(sessionId).mcpStartupState
  }

  private var tools: [String: ServerMcpTool] {
    serverState.session(sessionId).mcpTools
  }

  private var authStatuses: [String: ServerMcpAuthStatus] {
    serverState.session(sessionId).mcpAuthStatuses
  }

  private var resources: [String: [ServerMcpResource]] {
    serverState.session(sessionId).mcpResources
  }

  private var resourceTemplates: [String: [ServerMcpResourceTemplate]] {
    serverState.session(sessionId).mcpResourceTemplates
  }

  private var provider: Provider {
    serverState.session(sessionId).provider
  }

  private var capabilityNotice: McpCapabilityNotice? {
    McpServersTabPlanner.capabilityNotice(
      provider: provider,
      codexAccountStatus: serverState.codexAccountStatus
    )
  }

  /// All known server names from startup state + tools
  private var serverEntries: [ServerEntry] {
    var names = Set<String>()

    // From startup state
    if let state = startupState {
      names.formUnion(state.serverStatuses.keys)
      names.formUnion(state.readyServers)
      names.formUnion(state.failedServers.map(\.server))
      names.formUnion(state.cancelledServers)
    }

    // From tools/resources/templates (extract server from mcp__<server>__<tool> keys)
    for key in tools.keys {
      if let server = extractServerName(from: key) {
        names.insert(server)
      }
    }
    names.formUnion(resources.keys)
    names.formUnion(resourceTemplates.keys)

    return names.map { name in
      ServerEntry(
        name: name,
        status: serverStatus(for: name),
        tools: toolsForServer(name),
        resources: resourcesForServer(name),
        resourceTemplates: resourceTemplatesForServer(name),
        authStatus: authStatuses[name],
        error: errorForServer(name)
      )
    }
    .sorted { lhs, rhs in
      lhs.sortOrder < rhs.sortOrder
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("\(serverEntries.count) server\(serverEntries.count == 1 ? "" : "s")")
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer()

        Button {
          Task { try? await serverState.refreshMcpServers(sessionId) }
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .help("Refresh MCP servers")
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      if let capabilityNotice {
        CodexCapabilityNoticeCard(notice: capabilityNotice)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)

        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.3))
      }

      // Server list
      ScrollView(.vertical, showsIndicators: true) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(serverEntries) { entry in
            serverRow(entry)
          }
        }
        .padding(.vertical, Spacing.xs)
      }
    }
    .background(Color.backgroundPrimary)
  }

  // MARK: - Server Row

  @ViewBuilder
  private func serverRow(_ entry: ServerEntry) -> some View {
    let isExpanded = expandedServers.contains(entry.name)

    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(Motion.standard) {
          if isExpanded {
            expandedServers.remove(entry.name)
          } else {
            expandedServers.insert(entry.name)
          }
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          // Status indicator
          statusDot(entry.status)

          // Server icon + name
          Image(systemName: ToolCardStyle.mcpServerIcon(entry.name))
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(ToolCardStyle.mcpServerColor(entry.name))

          Text(entry.name)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(ToolCardStyle.mcpServerColor(entry.name))
            .lineLimit(1)

          // Auth badge
          if let auth = entry.authStatus, auth != .unsupported {
            Text(authLabel(auth))
              .font(.system(size: TypeScale.mini, weight: .bold))
              .foregroundStyle(.white.opacity(0.9))
              .padding(.horizontal, 5)
              .padding(.vertical, Spacing.xxs)
              .background(authColor(auth).opacity(0.7), in: Capsule())
          }

          Spacer()

          // Tool count
          let capabilities = capabilitySummary(for: entry)
          if !capabilities.isEmpty {
            Text(capabilities)
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textTertiary)
          }

          if entry.hasExpandedContent {
            Image(systemName: "chevron.right")
              .font(.system(size: TypeScale.mini, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Error message for failed servers
      if let error = entry.error {
        Text(error)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.statusPermission)
          .padding(.horizontal, Spacing.md)
          .padding(.leading, 28)
          .padding(.bottom, Spacing.sm_)
      }

      // Expanded tool list
      if isExpanded, entry.hasExpandedContent {
        VStack(alignment: .leading, spacing: 0) {
          if !entry.tools.isEmpty {
            capabilitySectionTitle("Tools", count: entry.tools.count)
            ForEach(entry.tools, id: \.name) { tool in
              toolRow(tool, color: ToolCardStyle.mcpServerColor(entry.name))
            }
          }

          if !entry.resources.isEmpty {
            capabilitySectionTitle("Resources", count: entry.resources.count)
            ForEach(entry.resources, id: \.uri) { resource in
              resourceRow(resource, color: ToolCardStyle.mcpServerColor(entry.name))
            }
          }

          if !entry.resourceTemplates.isEmpty {
            capabilitySectionTitle("Templates", count: entry.resourceTemplates.count)
            ForEach(entry.resourceTemplates, id: \.uriTemplate) { resourceTemplate in
              resourceTemplateRow(resourceTemplate, color: ToolCardStyle.mcpServerColor(entry.name))
            }
          }
        }
        .padding(.leading, 28)
        .padding(.trailing, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      if entry.id != serverEntries.last?.id {
        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.3))
          .padding(.horizontal, Spacing.md)
      }
    }
  }

  // MARK: - Tool Row

  private func toolRow(_ tool: ServerMcpTool, color: Color) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(tool.name)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(color.opacity(0.9))
        .lineLimit(1)

      if let desc = tool.description, !desc.isEmpty {
        Text(desc)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, Spacing.xs)
  }

  private func resourceRow(_ resource: ServerMcpResource, color: Color) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(resource.name)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(color.opacity(0.9))
        .lineLimit(1)

      Text(resource.uri)
        .font(.system(size: TypeScale.micro, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)

      if let desc = resource.description, !desc.isEmpty {
        Text(desc)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, Spacing.xs)
  }

  private func resourceTemplateRow(_ resourceTemplate: ServerMcpResourceTemplate, color: Color) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(resourceTemplate.name)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(color.opacity(0.9))
        .lineLimit(1)

      Text(resourceTemplate.uriTemplate)
        .font(.system(size: TypeScale.micro, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)

      if let desc = resourceTemplate.description, !desc.isEmpty {
        Text(desc)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, Spacing.xs)
  }

  private func capabilitySectionTitle(_ title: String, count: Int) -> some View {
    HStack(spacing: Spacing.xs) {
      Text(title.uppercased())
        .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textTertiary)
        .tracking(0.5)

      Text("\(count)")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textQuaternary)

      Spacer(minLength: 0)
    }
    .padding(.top, Spacing.sm)
    .padding(.bottom, Spacing.xxs)
  }

  // MARK: - Status Dot

  @ViewBuilder
  private func statusDot(_ status: ServerEntryStatus) -> some View {
    switch status {
      case .ready:
        Circle()
          .fill(Color.feedbackPositive)
          .frame(width: 8, height: 8)

      case .starting, .connecting:
        ZStack {
          Circle()
            .stroke(Color.accent.opacity(0.3), lineWidth: 1.5)
          Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.accent, lineWidth: 1.5)
            .rotationEffect(.degrees(-90))
        }
        .frame(width: 8, height: 8)
        .modifier(SpinningDotModifier())

      case .needsAuth:
        Image(systemName: "lock.fill")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.statusQuestion)

      case .failed:
        Circle()
          .fill(Color.statusPermission)
          .frame(width: 8, height: 8)

      case .cancelled:
        Circle()
          .fill(Color.secondary.opacity(0.4))
          .frame(width: 8, height: 8)
    }
  }

  // MARK: - Helpers

  private func extractServerName(from toolKey: String) -> String? {
    // Keys can be "mcp__<server>__<tool>" or "<server>__<tool>" or just server-scoped
    // The mcpTools dict is keyed by fully qualified name
    let parts = toolKey.split(separator: "__")
    if parts.count >= 2, parts[0] == "mcp" {
      return String(parts[1])
    } else if parts.count >= 2 {
      return String(parts[0])
    }
    // Try using the tool's name to extract server from parent key structure
    return nil
  }

  private func toolsForServer(_ server: String) -> [ServerMcpTool] {
    tools.compactMap { key, tool in
      if let name = extractServerName(from: key), name == server {
        return tool
      }
      return nil
    }
    .sorted { $0.name < $1.name }
  }

  private func resourcesForServer(_ server: String) -> [ServerMcpResource] {
    (resources[server] ?? []).sorted { $0.name < $1.name }
  }

  private func resourceTemplatesForServer(_ server: String) -> [ServerMcpResourceTemplate] {
    (resourceTemplates[server] ?? []).sorted { $0.name < $1.name }
  }

  private func capabilitySummary(for entry: ServerEntry) -> String {
    [
      entry.tools.isEmpty ? nil : "\(entry.tools.count) tool\(entry.tools.count == 1 ? "" : "s")",
      entry.resources.isEmpty ? nil : "\(entry.resources.count) resource\(entry.resources.count == 1 ? "" : "s")",
      entry.resourceTemplates.isEmpty ? nil : "\(entry.resourceTemplates.count) template\(entry.resourceTemplates.count == 1 ? "" : "s")",
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }

  private func serverStatus(for name: String) -> ServerEntryStatus {
    if let state = startupState {
      if let status = state.serverStatuses[name] {
        switch status {
          case .ready: return .ready
          case .starting: return .starting
          case .connecting: return .connecting
          case .needsAuth: return .needsAuth
          case .failed: return .failed
          case .cancelled: return .cancelled
        }
      }
      if state.readyServers.contains(name) { return .ready }
      if state.failedServers.contains(where: { $0.server == name }) { return .failed }
      if state.cancelledServers.contains(name) { return .cancelled }
    }
    // If we have tools but no startup state, assume ready
    if !toolsForServer(name).isEmpty || !resourcesForServer(name).isEmpty || !resourceTemplatesForServer(name).isEmpty {
      return .ready
    }
    return .starting
  }

  private func errorForServer(_ name: String) -> String? {
    if let state = startupState {
      if case let .failed(error) = state.serverStatuses[name] {
        return error
      }
      if let failure = state.failedServers.first(where: { $0.server == name }) {
        return failure.error
      }
    }
    return nil
  }

  private func authLabel(_ status: ServerMcpAuthStatus) -> String {
    switch status {
      case .unsupported: "N/A"
      case .notLoggedIn: "No Auth"
      case .bearerToken: "Token"
      case .oauth: "OAuth"
    }
  }

  private func authColor(_ status: ServerMcpAuthStatus) -> Color {
    switch status {
      case .unsupported: .secondary
      case .notLoggedIn: Color.statusPermission
      case .bearerToken: Color.feedbackPositive
      case .oauth: Color.accent
    }
  }

}

// MARK: - Models

private enum ServerEntryStatus: Int, Comparable {
  case ready = 0
  case starting = 1
  case connecting = 2
  case needsAuth = 3
  case failed = 4
  case cancelled = 5

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

private struct ServerEntry: Identifiable {
  let name: String
  let status: ServerEntryStatus
  let tools: [ServerMcpTool]
  let resources: [ServerMcpResource]
  let resourceTemplates: [ServerMcpResourceTemplate]
  let authStatus: ServerMcpAuthStatus?
  let error: String?

  var id: String {
    name
  }

  var sortOrder: Int {
    status.rawValue
  }

  var hasExpandedContent: Bool {
    !tools.isEmpty || !resources.isEmpty || !resourceTemplates.isEmpty
  }
}

// MARK: - Spinning Dot Animation

private struct SpinningDotModifier: ViewModifier {
  @State private var isSpinning = false

  func body(content: Content) -> some View {
    content
      .rotationEffect(.degrees(isSpinning ? 360 : 0))
      .onAppear {
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
          isSpinning = true
        }
      }
  }
}
