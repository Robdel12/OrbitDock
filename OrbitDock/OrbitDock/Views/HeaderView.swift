//
//  HeaderView.swift
//  OrbitDock
//
//  Compact header bar for session detail view
//

import SwiftUI

struct HeaderView: View {
  @Environment(AppRouter.self) private var router

  let sessionId: String
  let endpointId: UUID
  let onFocusTerminal: () -> Void
  var onEndSession: (() -> Void)?
  var showTurnSidebar: Binding<Bool>?
  var hasSidebarContent: Bool = false
  var layoutConfig: Binding<LayoutConfiguration>?
  var chatViewMode: Binding<ChatViewMode>?

  @Environment(ServerAppState.self) private var serverState
  @State private var isHoveringBack = false
  @State private var isHoveringProject = false
  @AppStorage("preferredEditor") private var preferredEditor: String = ""
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  private var statusColor: Color {
    switch obs.workStatus {
      case .working: .statusWorking
      case .waiting: .statusReply
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
    HStack(spacing: Spacing.md) {
      // Back button
      backButton

      // Status dot
      SessionStatusDot(status: obs.displayStatus, size: 10)

      // Session title dropdown
      sessionTitleDropdown

      // Model badge
      UnifiedModelBadge(model: obs.model, provider: obs.provider, size: .compact)

      Spacer()

      // Conversation mode toggle
      if let chatModeBinding = chatViewMode {
        ConversationViewModeToggle(chatViewMode: chatModeBinding)
      }

      // Layout toggle (direct sessions only)
      if let layoutBinding = layoutConfig {
        layoutToggle(layoutBinding)
      }

      // Action buttons
      HStack(spacing: Spacing.xxs) {
        navButton(icon: "magnifyingglass", action: { router.openQuickSwitcher() }, help: "Search sessions (⌘K)")
        overflowMenu
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Back Button

  private var backButton: some View {
    Button(action: { router.goToDashboard() }) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "chevron.left")
          .font(.system(size: TypeScale.caption, weight: .semibold))
        Text("Dashboard")
          .font(.system(size: TypeScale.body, weight: .medium))
      }
      .foregroundStyle(isHoveringBack ? Color.textPrimary : Color.textSecondary)
      .padding(.vertical, Spacing.xs)
      .padding(.horizontal, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(isHoveringBack ? Color.surfaceHover : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHoveringBack = $0 }
    .help("Go to dashboard (⌘0)")
  }

  // MARK: - Session Title Dropdown

  private var sessionTitleDropdown: some View {
    Button(action: { router.openQuickSwitcher() }) {
      HStack(spacing: Spacing.xs) {
        Text(agentName)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        Image(systemName: "chevron.down")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
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
      if obs.endpointName != nil {
        Text("Endpoint: \(obs.endpointName ?? "")")
      }
      ForEach(SessionCapability.capabilities(for: obs)) { cap in
        if let icon = cap.icon {
          Label(cap.label, systemImage: icon)
        } else {
          Text(cap.label)
        }
      }
      Divider()
      debugContextMenu
    }
  }

  // MARK: - Overflow Menu

  private var overflowMenu: some View {
    Menu {
      if Platform.services.capabilities.canFocusTerminal {
        Button {
          onFocusTerminal()
        } label: {
          Label(
            obs.isActive ? "Focus Terminal" : "Resume in Terminal",
            systemImage: obs.isActive ? "arrow.up.forward.app" : "terminal"
          )
        }
      }

      if let sidebarBinding = showTurnSidebar {
        Button {
          withAnimation(Motion.standard) {
            sidebarBinding.wrappedValue.toggle()
          }
        } label: {
          Label(
            sidebarBinding.wrappedValue ? "Hide Sidebar" : "Show Sidebar",
            systemImage: "sidebar.right"
          )
        }
      }

      Divider()

      debugContextMenu

      if obs.isDirect, obs.isActive, let onEnd = onEndSession {
        Divider()
        Button(role: .destructive) {
          onEnd()
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 26, height: 26)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
    .help("More options")
  }

  private var compactHeader: some View {
    VStack(spacing: Spacing.sm) {
      compactPrimaryRow

      compactControlRow
    }
    .padding(.vertical, Spacing.sm)
  }

  private var compactPrimaryRow: some View {
    HStack(spacing: Spacing.xs) {
      Button(action: { router.goToDashboard() }) {
        Image(systemName: "chevron.left")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
          .frame(width: 26, height: 26)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
      }
      .buttonStyle(.plain)
      .help("Dashboard (⌘0)")

      Button(action: { router.openQuickSwitcher() }) {
        HStack(spacing: Spacing.xs) {
          SessionStatusDot(status: obs.displayStatus, size: 10)

          Text(agentName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Image(systemName: "chevron.down")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
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

      navButton(icon: "magnifyingglass", action: { router.openQuickSwitcher() }, help: "Search sessions (⌘K)")

      compactOverflowMenu
    }
    .padding(.horizontal, Spacing.md)
  }

  private var compactControlRow: some View {
    HStack(spacing: Spacing.sm) {
      compactStatusSummaryBadge
        .layoutPriority(1)

      Spacer(minLength: 0)

      if hasCompactModeControls {
        compactModeControls
      }
    }
    .padding(.horizontal, Spacing.md)
  }

  private var compactStatusSummaryBadge: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: compactStatusIcon)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(statusColor)

      Text(compactStatusLabel)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Rectangle()
        .fill(Color.surfaceBorder)
        .frame(width: 1, height: 11)

      Text(compactModelSummary)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.58))
    )
    .themeShadow(Shadow.md)
  }

  private var compactModeControls: some View {
    HStack(spacing: Spacing.xs) {
      if let layoutBinding = layoutConfig {
        compactLayoutToggle(layoutBinding)
      }

      if showsConversationModeToggleInCompact, let chatModeBinding = chatViewMode {
        ConversationViewModeToggle(
          chatViewMode: chatModeBinding,
          showsContainerChrome: false
        )
      }
    }
    .padding(Spacing.xxs)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.58))
    )
    .themeShadow(Shadow.md)
  }

  private func compactLayoutToggle(_ binding: Binding<LayoutConfiguration>) -> some View {
    HStack(spacing: Spacing.xxs) {
      ForEach(LayoutConfiguration.allCases, id: \.self) { config in
        let isSelected = binding.wrappedValue == config
        Button {
          withAnimation(Motion.gentle) {
            binding.wrappedValue = isSelected ? .conversationOnly : config
          }
        } label: {
          Image(systemName: config.icon)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(isSelected ? Color.accent : Color.textSecondary)
            .frame(width: 24, height: 22)
            .background(
              isSelected ? Color.accent.opacity(OpacityTier.light) : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var hasCompactModeControls: Bool {
    layoutConfig != nil || showsConversationModeToggleInCompact
  }

  private var showsConversationModeToggleInCompact: Bool {
    guard chatViewMode != nil else { return false }
    if let layoutMode = layoutConfig?.wrappedValue, layoutMode == .reviewOnly {
      return false
    }
    return true
  }

  private var compactStatusIcon: String {
    switch obs.workStatus {
      case .working: "bolt.fill"
      case .waiting: "clock.fill"
      case .permission: "lock.fill"
      case .unknown: "circle.fill"
    }
  }

  private var compactStatusLabel: String {
    switch obs.workStatus {
      case .working: "Working"
      case .waiting: "Waiting"
      case .permission: "Approval"
      case .unknown: "Active"
    }
  }

  private var compactModelSummary: String {
    let raw = obs.model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let label: String = if let raw, !raw.isEmpty {
      raw
    } else {
      obs.provider.rawValue
    }
    guard label.count > 18 else { return label }
    return String(label.prefix(17)) + "..."
  }

  private var compactOverflowMenu: some View {
    Menu {
      if Platform.services.capabilities.canFocusTerminal {
        Button {
          onFocusTerminal()
        } label: {
          Label(
            obs.isActive ? "Focus Terminal" : "Resume in Terminal",
            systemImage: obs.isActive ? "arrow.up.forward.app" : "terminal"
          )
        }
      }

      if let sidebarBinding = showTurnSidebar {
        Button {
          withAnimation(Motion.standard) {
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
              withAnimation(Motion.gentle) {
                layoutBinding.wrappedValue = config
              }
            } label: {
              Label(config.label, systemImage: config.icon)
            }
          }
        }
      }

      Divider()

      debugContextMenu

      if obs.isDirect, obs.isActive, let onEnd = onEndSession {
        Divider()
        Button(role: .destructive) {
          onEnd()
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 26, height: 26)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
    .help("More")
  }

  // MARK: - Nav Button Helper

  private func navButton(
    icon: String,
    action: @escaping () -> Void,
    help: String
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 26, height: 26)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(help)
  }

  // MARK: - Layout Toggle

  private func layoutToggle(_ binding: Binding<LayoutConfiguration>) -> some View {
    HStack(spacing: Spacing.xxs) {
      ForEach(LayoutConfiguration.allCases, id: \.self) { config in
        let isSelected = binding.wrappedValue == config

        Button {
          withAnimation(Motion.gentle) {
            // Clicking the active button toggles back to conversation-only
            binding.wrappedValue = isSelected ? .conversationOnly : config
          }
        } label: {
          Image(systemName: config.icon)
            .font(.system(size: TypeScale.micro, weight: .medium))
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
      copyToClipboard(sessionId)
    }

    if let threadId = obs.codexThreadId {
      Button("Copy Thread ID") {
        copyToClipboard(threadId)
      }
    }

    Button("Copy Project Path") {
      copyToClipboard(obs.projectPath)
    }

    Divider()

    if let mode = obs.codexIntegrationMode {
      Text("Integration: \(String(describing: mode))")
    }
    if let mode = obs.claudeIntegrationMode {
      Text("Integration: \(String(describing: mode))")
    }
    Text("Provider: \(obs.provider.rawValue)")

    Divider()

    Button("Open Server Log") {
      _ = Platform.services.openURL(URL(fileURLWithPath: NSString("~/.orbitdock/logs/server.log").expandingTildeInPath))
    }

    if obs.provider == .codex {
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
    obs.displayName
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
      case .waiting: .statusReply
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
    if stats.contextPercentage > 0.7 { return .feedbackCaution }
    return .accent
  }

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      // Mini progress bar
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(Color.primary.opacity(0.1))

          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(progressColor)
            .frame(width: geo.size.width * stats.contextPercentage)
        }
      }
      .frame(width: 32, height: 4)

      Text("\(Int(stats.contextPercentage * 100))%")
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(progressColor)
    }
  }
}

struct CodexTokenBadge: View {
  let sessionId: String
  @Environment(ServerAppState.self) private var serverState

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Context fill percentage
      if let window = obs.contextWindow, window > 0 {
        Text("\(contextPercent)%")
          .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
          .foregroundStyle(contextColor)

        Text("of \(formatTokenCount(window))")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textTertiary)
      } else {
        // Fallback if no window info yet
        Text(formatTokenCount(obs.effectiveContextInputTokens))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
        Text("tokens")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textTertiary)
      }

      // Cache savings (compact)
      if cacheSavingsPercent >= 10 {
        HStack(spacing: Spacing.xxs) {
          Image(systemName: "bolt.fill")
            .font(.system(size: 8))
          Text("\(cacheSavingsPercent)%")
            .font(.system(size: TypeScale.micro, design: .monospaced))
        }
        .foregroundStyle(Color.feedbackPositive.opacity(0.85))
      }
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, 5)
    .background(Color.surfaceHover, in: Capsule())
    .help(tokenTooltip)
  }

  /// Context fill: input tokens / context window
  private var contextPercent: Int {
    min(100, Int(obs.contextFillPercent))
  }

  private var contextColor: Color {
    if contextPercent >= 90 { return .statusError }
    if contextPercent >= 70 { return .feedbackCaution }
    return .secondary
  }

  /// Cache savings as percentage of input tokens
  private var cacheSavingsPercent: Int {
    Int(obs.effectiveCacheHitPercent)
  }

  private var tokenTooltip: String {
    var parts: [String] = []

    if let input = obs.inputTokens {
      parts.append("Input: \(formatTokenCount(input))")
    }
    if let output = obs.outputTokens {
      parts.append("Output: \(formatTokenCount(output))")
    }
    if let cached = obs.cachedTokens, cached > 0,
       obs.effectiveContextInputTokens > 0
    {
      let percent = Int(obs.effectiveCacheHitPercent)
      parts.append("Cached: \(formatTokenCount(cached)) (\(percent)% savings)")
    }
    if let window = obs.contextWindow {
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
      sessionId: "test-123",
      endpointId: UUID(),
      onFocusTerminal: {}
    )
    .environment(AppRouter())

    Divider().opacity(0.3)

    Color.backgroundPrimary
      .frame(height: 400)
  }
  .frame(width: 900)
  .background(Color.backgroundPrimary)
  .environment(ServerAppState())
}
