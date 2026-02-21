//
//  HeaderView.swift
//  OrbitDock
//
//  Compact header bar for session detail view
//

import SwiftUI

struct HeaderView: View {
  let session: Session
  let currentTool: String?
  let onTogglePanel: () -> Void
  let onOpenSwitcher: () -> Void
  let onFocusTerminal: () -> Void
  let onGoToDashboard: () -> Void
  var onEndSession: (() -> Void)?
  var showTurnSidebar: Binding<Bool>?
  var hasSidebarContent: Bool = false
  var layoutConfig: Binding<LayoutConfiguration>?

  @State private var isHoveringPath = false
  @State private var isHoveringProject = false
  @AppStorage("preferredEditor") private var preferredEditor: String = ""
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var statusColor: Color {
    switch session.workStatus {
      case .working: .statusWorking
      case .waiting: .statusWaiting
      case .permission: .statusPermission
      case .unknown: .statusWorking.opacity(0.6)
    }
  }

  private var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }

  var body: some View {
    Group {
      if isCompactLayout {
        compactHeader
      } else {
        regularHeader
      }
    }
    .background(Color.backgroundSecondary)
  }

  // MARK: - Layouts

  private var regularHeader: some View {
    // Single-row identity bar
    HStack(spacing: Spacing.sm) {
      // Nav buttons
      HStack(spacing: 2) {
        navButton(icon: "sidebar.left", action: onTogglePanel, help: "Toggle projects panel (⌘1)")
        navButton(icon: "square.grid.2x2", action: onGoToDashboard, help: "Go to dashboard (⌘0)")
      }

      // Status dot
      SessionStatusDot(session: session, size: 8)

      // Session title dropdown
      Button(action: onOpenSwitcher) {
        HStack(spacing: Spacing.xs) {
          Text(agentName)
            .font(.system(size: TypeScale.title, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Image(systemName: "chevron.down")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(isHoveringProject ? Color.surfaceHover : Color.clear)
        )
      }
      .buttonStyle(.plain)
      .onHover { isHoveringProject = $0 }
      .contextMenu {
        debugContextMenu
      }

      // Model badge
      UnifiedModelBadge(model: session.model, provider: session.provider, size: .compact)

      // Capabilities
      ForEach(SessionCapability.capabilities(for: session)) { cap in
        CapabilityBadge(label: cap.label, icon: cap.icon, color: cap.color)
      }

      if session.isActive {
        StatusPillCompact(workStatus: session.workStatus, currentTool: currentTool)
      }

      // Separator before context
      Color.panelBorder.frame(width: 1, height: 16)

      // Git branch (inline)
      if let branch = session.branch, !branch.isEmpty {
        HStack(spacing: 4) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: TypeScale.caption, weight: .semibold))
          Text(branch)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(Color.gitBranch)
      }

      // Project path (inline)
      Button {
        openInEditor(session.projectPath)
      } label: {
        Text(shortenPath(session.projectPath))
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(isHoveringPath ? .secondary : .quaternary)
          .lineLimit(1)
      }
      .buttonStyle(.plain)
      .onHover { isHoveringPath = $0 }
      .help("Open in editor")
      .contextMenu {
        Button("Open in Editor") { openInEditor(session.projectPath) }
        Button("Reveal in Finder") {
          _ = Platform.services.revealInFileBrowser(session.projectPath)
        }
        Divider()
        Menu("Set Editor") {
          Button("Use $EDITOR") { preferredEditor = "" }
          Divider()
          Button("Emacs") { preferredEditor = "emacs" }
          Button("VS Code") { preferredEditor = "code" }
          Button("Cursor") { preferredEditor = "cursor" }
          Button("Zed") { preferredEditor = "zed" }
          Button("Sublime Text") { preferredEditor = "subl" }
          Button("Vim") { preferredEditor = "vim" }
          Button("Neovim") { preferredEditor = "nvim" }
        }
      }

      Spacer()

      // Duration (tertiary, right side)
      Text(session.formattedDuration)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(.quaternary)

      // Layout toggle
      if let layoutBinding = layoutConfig {
        layoutToggle(layoutBinding)
      }

      // Separator before action buttons
      Color.panelBorder.frame(width: 1, height: 16)

      // Action buttons
      HStack(spacing: 2) {
        navButton(icon: "magnifyingglass", action: onOpenSwitcher, help: "Search sessions (⌘K)", style: .tertiary)

        navButton(
          icon: session.isActive ? "arrow.up.forward.app" : "terminal",
          action: onFocusTerminal,
          help: session.isActive ? "Focus terminal" : "Resume in terminal"
        )

        if let sidebarBinding = showTurnSidebar {
          Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              sidebarBinding.wrappedValue.toggle()
            }
          } label: {
            Image(systemName: "sidebar.right")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(sidebarBinding.wrappedValue ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.tertiary))
              .frame(width: 26, height: 26)
              .background(
                sidebarBinding.wrappedValue ? Color.accent.opacity(OpacityTier.light) : Color.surfaceHover,
                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              )
          }
          .buttonStyle(.plain)
          .help("Toggle sidebar (⌥⌘R)")
        }

        if session.isDirect, session.isActive, let onEnd = onEndSession {
          navButton(icon: "stop.circle", action: onEnd, help: "End session", style: .danger)
        }
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  private var compactHeader: some View {
    VStack(spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        navButton(icon: "sidebar.left", action: onTogglePanel, help: "Toggle projects panel (⌘1)")

        Button(action: onOpenSwitcher) {
          HStack(spacing: Spacing.xs) {
            SessionStatusDot(session: session, size: 8)

            Text(agentName)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)

            Image(systemName: "chevron.down")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          .padding(.vertical, Spacing.xs)
          .padding(.horizontal, Spacing.sm)
          .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .fill(isHoveringProject ? Color.surfaceHover : Color.clear)
          )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringProject = $0 }
        .contextMenu {
          debugContextMenu
        }
        .layoutPriority(1)

        Spacer(minLength: 0)

        navButton(icon: "magnifyingglass", action: onOpenSwitcher, help: "Search sessions (⌘K)", style: .tertiary)

        compactOverflowMenu
      }
      .padding(.horizontal, Spacing.md)

      ScrollView(.horizontal) {
        HStack(spacing: Spacing.sm) {
          UnifiedModelBadge(model: session.model, provider: session.provider, size: .compact)

          if session.isActive {
            StatusPillCompact(workStatus: session.workStatus, currentTool: currentTool)
          }

          if let branch = session.branch, !branch.isEmpty {
            HStack(spacing: 4) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: TypeScale.caption, weight: .semibold))
              Text(compactBranchLabel(branch))
                .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(Color.gitBranch)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 4)
            .background(Color.backgroundTertiary, in: Capsule())
          }

          Button {
            openInEditor(session.projectPath)
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "folder")
                .font(.system(size: TypeScale.caption, weight: .semibold))
              Text(compactProjectLabel)
                .font(.system(size: TypeScale.caption, design: .monospaced))
                .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 4)
            .background(Color.backgroundTertiary, in: Capsule())
          }
          .buttonStyle(.plain)
          .help("Open in editor")
        }
        .padding(.horizontal, Spacing.md)
      }
      .scrollIndicators(.hidden)
    }
    .padding(.vertical, Spacing.sm)
  }

  private var compactOverflowMenu: some View {
    Menu {
      Button {
        onGoToDashboard()
      } label: {
        Label("Dashboard", systemImage: "square.grid.2x2")
      }

      Button {
        onFocusTerminal()
      } label: {
        Label(
          session.isActive ? "Focus Terminal" : "Resume in Terminal",
          systemImage: session.isActive ?
            "arrow.up.forward.app" : "terminal"
        )
      }

      if let sidebarBinding = showTurnSidebar {
        Button {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            sidebarBinding.wrappedValue.toggle()
          }
        } label: {
          Label(sidebarBinding.wrappedValue ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.right")
        }
      }

      if let layoutBinding = layoutConfig {
        Section("Layout") {
          ForEach(LayoutConfiguration.allCases, id: \.self) { config in
            Button {
              withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                layoutBinding.wrappedValue = config
              }
            } label: {
              Label(config.label, systemImage: config.icon)
            }
          }
        }
      }

      if session.isDirect, session.isActive, let onEnd = onEndSession {
        Button(role: .destructive) {
          onEnd()
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.tertiary)
        .frame(width: 26, height: 26)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
    .help("More")
  }

  // MARK: - Nav Button Helper

  private enum NavButtonStyle {
    case secondary, tertiary, danger
  }

  private func navButton(
    icon: String,
    action: @escaping () -> Void,
    help: String,
    style: NavButtonStyle = .secondary
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(style == .danger ? AnyShapeStyle(Color.statusPermission) : style == .tertiary ?
          AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        .frame(width: 26, height: 26)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(help)
  }

  // MARK: - Layout Toggle

  private func layoutToggle(_ binding: Binding<LayoutConfiguration>) -> some View {
    HStack(spacing: 2) {
      ForEach(LayoutConfiguration.allCases, id: \.self) { config in
        let isSelected = binding.wrappedValue == config

        Button {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            // Clicking the active button toggles back to conversation-only
            binding.wrappedValue = isSelected ? .conversationOnly : config
          }
        } label: {
          Image(systemName: config.icon)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isSelected ? Color.accent : .secondary)
            .frame(width: 26, height: 22)
            .background(
              isSelected ? Color.accent.opacity(OpacityTier.light) : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(config.label)
      }
    }
    .padding(Spacing.xxs)
    .background(
      Color.backgroundTertiary.opacity(0.5),
      in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
    )
  }

  // MARK: - Debug Context Menu

  @ViewBuilder
  private var debugContextMenu: some View {
    Button("Copy Session ID") {
      copyToClipboard(session.id)
    }

    if let threadId = session.codexThreadId {
      Button("Copy Thread ID") {
        copyToClipboard(threadId)
      }
    }

    Button("Copy Project Path") {
      copyToClipboard(session.projectPath)
    }

    Divider()

    if let mode = session.codexIntegrationMode {
      Text("Integration: \(String(describing: mode))")
    }
    if let mode = session.claudeIntegrationMode {
      Text("Integration: \(String(describing: mode))")
    }
    Text("Provider: \(session.provider.rawValue)")

    Divider()

    Button("Open Server Log") {
      _ = Platform.services.openURL(URL(fileURLWithPath: NSString("~/.orbitdock/logs/server.log").expandingTildeInPath))
    }

    if session.provider == .codex {
      Button("Open Codex Log") {
        _ = Platform.services
          .openURL(URL(fileURLWithPath: NSString("~/.orbitdock/logs/codex.log").expandingTildeInPath))
      }
    }

    Button("Open Database") {
      _ = Platform.services.openURL(URL(fileURLWithPath: NSString("~/.orbitdock/orbitdock.db").expandingTildeInPath))
    }
  }

  private func copyToClipboard(_ text: String) {
    Platform.services.copyToClipboard(text)
  }

  // MARK: - Helpers

  private var agentName: String {
    session.displayName
  }

  private var compactProjectLabel: String {
    if let name = session.projectName, !name.isEmpty {
      return name
    }
    let components = session.projectPath.split(separator: "/")
    return components.last.map(String.init) ?? session.projectPath
  }

  private func compactBranchLabel(_ branch: String) -> String {
    let maxLength = 14
    guard branch.count > maxLength else { return branch }
    return String(branch.prefix(maxLength - 1)) + "…"
  }

  private func shortenPath(_ path: String) -> String {
    let components = path.components(separatedBy: "/")
    if components.count > 4 {
      return "~/.../" + components.suffix(2).joined(separator: "/")
    }
    return path.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~")
  }

  private func openInEditor(_ path: String) {
    // If no editor configured, fall back to Finder
    guard !preferredEditor.isEmpty else {
      _ = Platform.services.revealInFileBrowser(path)
      return
    }

    #if !os(macOS)
      _ = Platform.services.openURL(URL(fileURLWithPath: path))
      return
    #else
      // Map common editor commands to app names for `open -a`
      let appNames: [String: String] = [
        "emacs": "Emacs",
        "code": "Visual Studio Code",
        "cursor": "Cursor",
        "zed": "Zed",
        "subl": "Sublime Text",
      ]

      // Try opening as a macOS app first (works best for GUI editors)
      if let appName = appNames[preferredEditor] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName, path]
        if (try? process.run()) != nil {
          return
        }
      }

      // Fall back to running the command directly (for terminal editors or custom paths)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [preferredEditor, path]
      process.currentDirectoryURL = URL(fileURLWithPath: path)
      try? process.run()
    #endif
  }
}

// MARK: - Compact Components

struct StatusPillCompact: View {
  let workStatus: Session.WorkStatus
  let currentTool: String?

  private var color: Color {
    switch workStatus {
      case .working: .statusWorking
      case .waiting: .statusWaiting
      case .permission: .statusPermission
      case .unknown: .secondary
    }
  }

  private var icon: String {
    switch workStatus {
      case .working: "bolt.fill"
      case .waiting: "clock"
      case .permission: "lock.fill"
      case .unknown: "circle"
    }
  }

  private var label: String {
    switch workStatus {
      case .working:
        if let tool = currentTool {
          return tool
        }
        return "Working"
      case .waiting: return "Waiting"
      case .permission: return "Permission"
      case .unknown: return ""
    }
  }

  var body: some View {
    if workStatus != .unknown {
      HStack(spacing: Spacing.xs) {
        if workStatus == .working {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: icon)
            .font(.system(size: 8, weight: .bold))
        }
        Text(label)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(color.opacity(OpacityTier.light), in: Capsule())
    }
  }
}

struct ContextGaugeCompact: View {
  let stats: TranscriptUsageStats

  private var progressColor: Color {
    if stats.contextPercentage > 0.9 { return .statusError }
    if stats.contextPercentage > 0.7 { return .statusWaiting }
    return .accent
  }

  var body: some View {
    HStack(spacing: 6) {
      // Mini progress bar
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(0.1))

          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(progressColor)
            .frame(width: geo.size.width * stats.contextPercentage)
        }
      }
      .frame(width: 32, height: 4)

      Text("\(Int(stats.contextPercentage * 100))%")
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(progressColor)
    }
  }
}

struct CodexTokenBadge: View {
  let session: Session

  var body: some View {
    HStack(spacing: 8) {
      // Context fill percentage
      if let window = session.contextWindow, window > 0 {
        Text("\(contextPercent)%")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(contextColor)

        Text("of \(formatTokenCount(window))")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      } else {
        // Fallback if no window info yet
        Text(formatTokenCount(session.inputTokens ?? 0))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
        Text("tokens")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }

      // Cache savings (compact)
      if cacheSavingsPercent >= 10 {
        HStack(spacing: 2) {
          Image(systemName: "bolt.fill")
            .font(.system(size: 8))
          Text("\(cacheSavingsPercent)%")
            .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(.green.opacity(0.85))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.surfaceHover, in: Capsule())
    .help(tokenTooltip)
  }

  /// Context fill: input tokens / context window
  private var contextPercent: Int {
    guard let window = session.contextWindow, window > 0,
          let input = session.inputTokens
    else { return 0 }
    return min(100, Int(Double(input) / Double(window) * 100))
  }

  private var contextColor: Color {
    if contextPercent >= 90 { return .statusError }
    if contextPercent >= 70 { return .statusWaiting }
    return .secondary
  }

  /// Cache savings as percentage of input tokens
  private var cacheSavingsPercent: Int {
    guard let cached = session.cachedTokens,
          let input = session.inputTokens,
          input > 0
    else { return 0 }
    return Int(Double(cached) / Double(input) * 100)
  }

  private var tokenTooltip: String {
    var parts: [String] = []

    if let input = session.inputTokens {
      parts.append("Input: \(formatTokenCount(input))")
    }
    if let output = session.outputTokens {
      parts.append("Output: \(formatTokenCount(output))")
    }
    if let cached = session.cachedTokens, cached > 0,
       let input = session.inputTokens, input > 0
    {
      let percent = Int(Double(cached) / Double(input) * 100)
      parts.append("Cached: \(formatTokenCount(cached)) (\(percent)% savings)")
    }
    if let window = session.contextWindow {
      parts.append("Context window: \(formatTokenCount(window))")
    }

    return parts.isEmpty ? "Token usage" : parts.joined(separator: "\n")
  }

  private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
      return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
      return String(format: "%.1fk", Double(count) / 1_000)
    }
    return "\(count)"
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 0) {
    HeaderView(
      session: Session(
        id: "test-123",
        projectPath: "/Users/developer/Developer/vizzly-cli",
        projectName: "vizzly-cli",
        branch: "feat/auth-system",
        model: "claude-opus-4-5-20251101",
        contextLabel: "Auth refactor",
        transcriptPath: nil,
        status: .active,
        workStatus: .working,
        startedAt: Date().addingTimeInterval(-3_600),
        endedAt: nil,
        endReason: nil,
        totalTokens: 50_000,
        totalCostUSD: 1.23,
        lastActivityAt: Date(),
        lastTool: "Edit",
        lastToolAt: Date(),
        promptCount: 45,
        toolCount: 123,
        terminalSessionId: nil,
        terminalApp: nil
      ),
      currentTool: "Edit",
      onTogglePanel: {},
      onOpenSwitcher: {},
      onFocusTerminal: {},
      onGoToDashboard: {}
    )

    Divider().opacity(0.3)

    Color.backgroundPrimary
      .frame(height: 400)
  }
  .frame(width: 900)
  .background(Color.backgroundPrimary)
}
