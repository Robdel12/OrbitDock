//
//  McpServersTab.swift
//  OrbitDock
//
//  MCP server list with status indicators and expandable tool details.
//  Shown as a tab in CodexTurnSidebar.
//

import SwiftUI

struct McpServersTab: View {
  let sessionId: String

  @Environment(ServerAppState.self) private var serverState
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

    // From tools (extract server from mcp__<server>__<tool> keys)
    for key in tools.keys {
      if let server = extractServerName(from: key) {
        names.insert(server)
      }
    }

    return names.map { name in
      ServerEntry(
        name: name,
        status: serverStatus(for: name),
        tools: toolsForServer(name),
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
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer()

        Button {
          serverState.refreshMcpServers(sessionId: sessionId)
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Refresh MCP servers")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      // Server list
      ScrollView(.vertical, showsIndicators: true) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(serverEntries) { entry in
            serverRow(entry)
          }
        }
        .padding(.vertical, 4)
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
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          if isExpanded {
            expandedServers.remove(entry.name)
          } else {
            expandedServers.insert(entry.name)
          }
        }
      } label: {
        HStack(spacing: 8) {
          // Status indicator
          statusDot(entry.status)

          // Server icon + name
          Image(systemName: MCPCard.serverIcon(entry.name))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MCPCard.serverColor(entry.name))

          Text(entry.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MCPCard.serverColor(entry.name))
            .lineLimit(1)

          // Auth badge
          if let auth = entry.authStatus, auth != .unsupported {
            Text(authLabel(auth))
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.white.opacity(0.9))
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(authColor(auth).opacity(0.7), in: Capsule())
          }

          Spacer()

          // Tool count
          if !entry.tools.isEmpty {
            Text("\(entry.tools.count) tool\(entry.tools.count == 1 ? "" : "s")")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.tertiary)
          }

          // Expand chevron (only if has tools)
          if !entry.tools.isEmpty {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.tertiary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Error message for failed servers
      if let error = entry.error {
        Text(error)
          .font(.system(size: 10))
          .foregroundStyle(Color.statusPermission)
          .padding(.horizontal, 12)
          .padding(.leading, 28)
          .padding(.bottom, 6)
      }

      // Expanded tool list
      if isExpanded, !entry.tools.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(entry.tools, id: \.name) { tool in
            toolRow(tool, color: MCPCard.serverColor(entry.name))
          }
        }
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      if entry.id != serverEntries.last?.id {
        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.3))
          .padding(.horizontal, 12)
      }
    }
  }

  // MARK: - Tool Row

  private func toolRow(_ tool: ServerMcpTool, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(tool.name)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(color.opacity(0.9))
        .lineLimit(1)

      if let desc = tool.description, !desc.isEmpty {
        Text(desc)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }

  // MARK: - Status Dot

  @ViewBuilder
  private func statusDot(_ status: ServerEntryStatus) -> some View {
    switch status {
      case .ready:
        Circle()
          .fill(Color.statusReady)
          .frame(width: 8, height: 8)

      case .starting:
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

  private func serverStatus(for name: String) -> ServerEntryStatus {
    if let state = startupState {
      if let status = state.serverStatuses[name] {
        switch status {
          case .ready: return .ready
          case .starting: return .starting
          case .failed: return .failed
          case .cancelled: return .cancelled
        }
      }
      if state.readyServers.contains(name) { return .ready }
      if state.failedServers.contains(where: { $0.server == name }) { return .failed }
      if state.cancelledServers.contains(name) { return .cancelled }
    }
    // If we have tools but no startup state, assume ready
    if !toolsForServer(name).isEmpty { return .ready }
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
      case .bearerToken: Color.statusReady
      case .oauth: Color.accent
    }
  }
}

// MARK: - Models

private enum ServerEntryStatus: Int, Comparable {
  case ready = 0
  case starting = 1
  case failed = 2
  case cancelled = 3

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

private struct ServerEntry: Identifiable {
  let name: String
  let status: ServerEntryStatus
  let tools: [ServerMcpTool]
  let authStatus: ServerMcpAuthStatus?
  let error: String?

  var id: String { name }

  var sortOrder: Int { status.rawValue }
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
