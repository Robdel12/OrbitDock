//
//  HeaderView.swift
//  OrbitDock
//
//  Compact header bar for session detail view
//

import SwiftUI

struct HeaderView: View {
  let session: Session
  let usageStats: TranscriptUsageStats
  let currentTool: String?
  let onTogglePanel: () -> Void
  let onOpenSwitcher: () -> Void
  let onFocusTerminal: () -> Void
  let onGoToDashboard: () -> Void

  @State private var isHoveringPath = false
  @State private var isHoveringProject = false
  @AppStorage("preferredEditor") private var preferredEditor: String = ""

  private var statusColor: Color {
    switch session.workStatus {
      case .working: .statusWorking
      case .waiting: .statusWaiting
      case .permission: .statusPermission
      case .unknown: .statusWorking.opacity(0.6)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Main row - Session identity + stats
      HStack(spacing: 10) {
        // Nav buttons
        HStack(spacing: 4) {
          Button(action: onTogglePanel) {
            Image(systemName: "sidebar.left")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.secondary)
              .frame(width: 28, height: 28)
              .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .help("Toggle projects panel (⌘1)")

          Button(action: onGoToDashboard) {
            Image(systemName: "square.grid.2x2")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)
              .frame(width: 28, height: 28)
              .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .help("Go to dashboard (⌘0)")
        }

        // Status dot - "Orbit indicator"
        ZStack {
          if session.isActive, session.workStatus == .working {
            Circle()
              .fill(statusColor.opacity(0.15))
              .frame(width: 24, height: 24)
              .blur(radius: 4)
            Circle()
              .stroke(statusColor.opacity(0.5), lineWidth: 1.5)
              .frame(width: 20, height: 20)
          }
          Circle()
            .fill(session.isActive ? statusColor : Color.statusIdle)
            .frame(width: 10, height: 10)
            .shadow(color: session.isActive ? statusColor.opacity(0.6) : .clear, radius: 4)
        }

        // Session title (primary focus)
        Button(action: onOpenSwitcher) {
          HStack(spacing: 6) {
            Text(agentName)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)

            Image(systemName: "chevron.down")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          .padding(.vertical, 4)
          .padding(.horizontal, 8)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(isHoveringProject ? Color.surfaceHover : Color.clear)
          )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringProject = $0 }

        // Provider + Model badge
        ModelBadgeCompact(model: session.model, provider: session.provider)

        // Status pill (only when active)
        if session.isActive {
          StatusPillCompact(workStatus: session.workStatus, currentTool: currentTool)
        }

        Spacer()

        // Stats row (compact)
        HStack(spacing: 14) {
          // Show usage for this session's provider only
          ProviderUsageCompact(
            provider: session.provider,
            windows: UsageServiceRegistry.shared.windows(for: session.provider),
            isLoading: UsageServiceRegistry.shared.isLoading(for: session.provider),
            error: UsageServiceRegistry.shared.error(for: session.provider),
            isStale: UsageServiceRegistry.shared.isStale(for: session.provider)
          )

          Divider()
            .frame(height: 12)
            .opacity(0.3)

          ContextGaugeCompact(stats: usageStats)

          if usageStats.estimatedCostUSD > 0 {
            Text(usageStats.formattedCost)
              .font(.system(size: 12, weight: .semibold, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
          }

          Text(session.formattedDuration)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
        }

        // Quick actions
        HStack(spacing: 4) {
          Button(action: onOpenSwitcher) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.tertiary)
              .frame(width: 28, height: 28)
              .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .help("Search sessions (⌘K)")

          Button(action: onFocusTerminal) {
            Image(systemName: session.isActive ? "arrow.up.forward.app" : "terminal")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)
              .frame(width: 28, height: 28)
              .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .help(session.isActive ? "Focus terminal" : "Resume in terminal")
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      // Context row - Breadcrumb with project context
      HStack(spacing: 8) {
        // Git branch
        if let branch = session.branch, !branch.isEmpty {
          HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
              .font(.system(size: 10, weight: .semibold))
            Text(branch)
              .font(.system(size: 11, weight: .medium))
          }
          .foregroundStyle(Color.gitBranch)
        }

        // Separator
        Text("•")
          .font(.system(size: 8))
          .foregroundStyle(.quaternary)

        // Project/Path
        Button {
          openInEditor(session.projectPath)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "folder")
              .font(.system(size: 10, weight: .medium))
            Text(shortenPath(session.projectPath))
              .font(.system(size: 10, design: .monospaced))
          }
          .foregroundStyle(isHoveringPath ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringPath = $0 }
        .help("Open in editor")
        .contextMenu {
          Button("Open in Editor") {
            openInEditor(session.projectPath)
          }
          Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
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
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 10)
    }
    .background(Color.backgroundSecondary)
  }

  // MARK: - Helpers

  private var agentName: String {
    session.displayName
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
      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
      return
    }

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
  }
}

// MARK: - Compact Components

struct ModelBadgeCompact: View {
  let model: String?
  let provider: Provider

  private var displayModel: String {
    guard let model = model?.lowercased(), !model.isEmpty else { return provider.displayName }
    // Claude models
    if model.contains("opus") { return "Opus" }
    if model.contains("sonnet") { return "Sonnet" }
    if model.contains("haiku") { return "Haiku" }
    // OpenAI/Codex - normalize: "gpt-5.2-codex" -> "GPT-5.2"
    if model.hasPrefix("gpt-") {
      let version = model.dropFirst(4).split(separator: "-").first ?? ""
      return "GPT-\(version)"
    }
    if model == "openai" { return "OpenAI" }
    return String(model.prefix(8))
  }

  private var modelColor: Color {
    guard let model = model?.lowercased() else { return provider.accentColor }
    // Claude-specific model colors
    if model.contains("opus") { return .modelOpus }
    if model.contains("sonnet") { return .modelSonnet }
    if model.contains("haiku") { return .modelHaiku }
    // For other providers, use their accent color
    return provider.accentColor
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: provider.icon)
        .font(.system(size: 9, weight: .bold))
      Text(displayModel)
        .font(.system(size: 10, weight: .semibold))
    }
    .foregroundStyle(modelColor)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(modelColor.opacity(0.12), in: Capsule())
  }
}

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
      HStack(spacing: 4) {
        if workStatus == .working {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: icon)
            .font(.system(size: 8, weight: .bold))
        }
        Text(label)
          .font(.system(size: 10, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
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
      usageStats: {
        var stats = TranscriptUsageStats()
        stats.inputTokens = 100_000
        stats.outputTokens = 50_000
        stats.contextUsed = 150_000
        stats.model = "opus"
        return stats
      }(),
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
