//
//  TaskCard.swift
//  OrbitDock
//
//  Enhanced agent/subagent task card with nested tool calls.
//  Tools are loaded from the server via GetSubagentTools.
//

import SwiftUI

struct TaskCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool
  var sessionId: String?

  @Environment(ServerAppState.self) private var serverState

  // Subagent state
  @State private var matchedSubagentId: String?
  @State private var hasLoadedSubagent = false
  @State private var showSubagentTools = false
  @State private var pollTask: Task<Void, Never>?

  private var description: String {
    message.taskDescription ?? ""
  }

  private var prompt: String {
    message.taskPrompt ?? ""
  }

  private var output: String {
    message.toolOutput ?? ""
  }

  private var isComplete: Bool {
    !message.isInProgress && !output.isEmpty
  }

  private var agentType: String {
    (message.toolInput?["subagent_type"] as? String) ?? "general"
  }

  private var agentInfo: AgentTypeInfo {
    AgentTypeInfo.from(agentType)
  }

  private var subagentTools: [ServerSubagentTool] {
    guard let sid = sessionId, let subId = matchedSubagentId else { return [] }
    return serverState.session(sid).subagentTools[subId] ?? []
  }

  var body: some View {
    ToolCardContainer(
      color: agentInfo.color,
      isExpanded: $isExpanded,
      hasContent: !prompt.isEmpty || !output.isEmpty || !subagentTools.isEmpty
    ) {
      header
    } content: {
      expandedContent
    }
    .onChange(of: isExpanded) { _, expanded in
      if expanded, !hasLoadedSubagent {
        matchAndLoadSubagent()
      }
    }
    .onChange(of: isComplete) { _, complete in
      if complete {
        stopPolling()
      }
    }
    .onDisappear {
      stopPolling()
    }
  }

  // MARK: - Match Subagent & Load Tools

  private func matchAndLoadSubagent() {
    guard let sid = sessionId else {
      hasLoadedSubagent = true
      return
    }

    let obs = serverState.session(sid)
    let subagents = obs.subagents

    // Match by agent type and timestamp proximity (within 5 seconds)
    let taskTime = message.timestamp.timeIntervalSince1970
    let matched = subagents.first { sub in
      // Parse subagent started_at (Unix seconds or ISO 8601 with Z suffix)
      let startedStr = sub.startedAt
      let stripped = startedStr.hasSuffix("Z") ? String(startedStr.dropLast()) : startedStr
      guard let startedSecs = TimeInterval(stripped) else { return false }
      return abs(startedSecs - taskTime) < 5.0
    }

    if let matched {
      matchedSubagentId = matched.id
      hasLoadedSubagent = true
      requestTools()

      // Poll for live updates if task is still in progress
      if !isComplete {
        startPolling()
      }
    } else {
      hasLoadedSubagent = true
    }
  }

  private func requestTools() {
    guard let sid = sessionId, let subId = matchedSubagentId else { return }
    serverState.getSubagentTools(sessionId: sid, subagentId: subId)
  }

  // MARK: - Polling for Live Updates

  private func startPolling() {
    stopPolling()
    pollTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { break }
        await MainActor.run {
          requestTools()
        }
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.md) {
      // Agent icon with status ring
      ZStack {
        Circle()
          .fill(agentInfo.color.opacity(0.15))
          .frame(width: 32, height: 32)

        Image(systemName: agentInfo.icon)
          .font(.system(size: TypeScale.subhead, weight: .semibold))
          .foregroundStyle(agentInfo.color)

        // Status ring
        if message.isInProgress {
          Circle()
            .strokeBorder(agentInfo.color.opacity(0.5), lineWidth: 2)
            .frame(width: 32, height: 32)
        } else if isComplete {
          Circle()
            .strokeBorder(Color(red: 0.4, green: 0.9, blue: 0.5), lineWidth: 2)
            .frame(width: 32, height: 32)
        }
      }

      VStack(alignment: .leading, spacing: Spacing.gap) {
        HStack(spacing: Spacing.sm) {
          // Agent type badge
          HStack(spacing: Spacing.xs) {
            Text(agentInfo.label)
              .font(.system(size: TypeScale.meta, weight: .bold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.gap)
          .background(agentInfo.color, in: RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous))

          // Status
          if message.isInProgress {
            HStack(spacing: Spacing.xs) {
              ProgressView()
                .controlSize(.mini)
              Text("Running...")
                .font(.system(size: TypeScale.micro, weight: .medium))
            }
            .foregroundStyle(agentInfo.color)
          } else if isComplete {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: TypeScale.meta))
                .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
              Text("Complete")
                .font(.system(size: TypeScale.micro, weight: .medium))
                .foregroundStyle(.secondary)
            }
          }
        }

        // Description
        if !description.isEmpty {
          Text(description)
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(.primary.opacity(0.9))
            .lineLimit(1)
        }

        // Result preview in header when complete
        if isComplete, !isExpanded {
          Text(output.prefix(100).replacingOccurrences(of: "\n", with: " "))
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: Spacing.xs) {
        if !message.isInProgress {
          ToolCardDuration(duration: message.formattedDuration)
        }

        ToolCardExpandButton(isExpanded: $isExpanded)
      }
    }
  }

  // MARK: - Expanded Content

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Result first (most important when complete)
      if isComplete {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "text.bubble.fill")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
            Text("AGENT RESULT")
              .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
              .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5).opacity(0.8))
              .tracking(0.5)
          }

          ScrollView {
            MarkdownRepresentable(content: output)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 300)
        }
        .padding(Spacing.lg_)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.15, green: 0.25, blue: 0.18).opacity(0.5))
      }

      // Subagent tools section
      if !subagentTools.isEmpty {
        subagentToolsSection
      } else if !hasLoadedSubagent, isExpanded {
        // Loading indicator
        HStack(spacing: Spacing.sm) {
          ProgressView()
            .controlSize(.small)
          Text("Loading agent activity...")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
      }

      // Prompt section (collapsed by default if we have tools)
      if !prompt.isEmpty {
        promptSection
      }
    }
  }

  // MARK: - Subagent Tools Section

  private var subagentToolsSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with toggle
      Button {
        withAnimation(Motion.standard) {
          showSubagentTools.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "chevron.right")
            .font(.system(size: TypeScale.mini, weight: .bold))
            .rotationEffect(.degrees(showSubagentTools ? 90 : 0))
            .foregroundStyle(agentInfo.color)

          Image(systemName: "rectangle.stack.fill")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(agentInfo.color.opacity(0.7))

          Text("AGENT ACTIVITY")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(agentInfo.color.opacity(0.8))
            .tracking(0.5)

          Text("(\(subagentTools.count) tools)")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .background(agentInfo.color.opacity(0.08))

      // Nested tool list
      if showSubagentTools {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          ForEach(Array(subagentTools.prefix(20).enumerated()), id: \.element.id) { _, tool in
            SubagentToolRow(tool: tool, color: agentInfo.color)
          }

          if subagentTools.count > 20 {
            Text("... +\(subagentTools.count - 20) more tools")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm_)
          }
        }
        .padding(.vertical, Spacing.xs)
        .background(Color.backgroundTertiary.opacity(0.2))
      }
    }
  }

  // MARK: - Prompt Section

  private var promptSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "text.quote")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(agentInfo.color.opacity(0.7))
        Text("PROMPT")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textQuaternary)
          .tracking(0.5)
      }

      ScrollView {
        Text(prompt)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(.primary.opacity(0.7))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 150)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundTertiary.opacity(0.3))
  }
}

// MARK: - Subagent Tool Row

private struct SubagentToolRow: View {
  let tool: ServerSubagentTool
  let color: Color

  private var toolColor: Color {
    ToolCardStyle.color(for: tool.toolName)
  }

  private var toolIcon: String {
    ToolCardStyle.icon(for: tool.toolName)
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Indent indicator
      Rectangle()
        .fill(color.opacity(0.3))
        .frame(width: 2)
        .padding(.leading, Spacing.sm)

      // Tool icon
      Image(systemName: toolIcon)
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(toolColor)
        .frame(width: 14)

      // Tool name
      Text(tool.toolName)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(toolColor)

      // Summary
      Text(tool.summary)
        .font(.system(size: TypeScale.micro, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Spacer()

      // Status
      if tool.isInProgress {
        ProgressView()
          .controlSize(.mini)
      } else {
        Image(systemName: "checkmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5).opacity(0.7))
      }
    }
    .padding(.vertical, Spacing.xs)
    .padding(.trailing, Spacing.md)
  }
}

// MARK: - Agent Type Info

private struct AgentTypeInfo {
  let icon: String
  let label: String
  let color: Color

  static func from(_ type: String) -> AgentTypeInfo {
    switch type.lowercased() {
      case "explore":
        AgentTypeInfo(
          icon: "binoculars.fill",
          label: "Explore",
          color: Color(red: 0.4, green: 0.7, blue: 0.95) // Light blue
        )
      case "plan":
        AgentTypeInfo(
          icon: "map.fill",
          label: "Plan",
          color: Color(red: 0.6, green: 0.5, blue: 0.9) // Purple
        )
      case "bash":
        AgentTypeInfo(
          icon: "terminal.fill",
          label: "Bash",
          color: Color(red: 0.35, green: 0.8, blue: 0.5) // Green
        )
      case "general-purpose":
        AgentTypeInfo(
          icon: "cpu.fill",
          label: "General",
          color: Color(red: 0.45, green: 0.45, blue: 0.95) // Indigo
        )
      case "claude-code-guide":
        AgentTypeInfo(
          icon: "book.fill",
          label: "Guide",
          color: Color(red: 0.9, green: 0.6, blue: 0.3) // Orange
        )
      case "linear-project-manager":
        AgentTypeInfo(
          icon: "list.bullet.rectangle.fill",
          label: "Linear",
          color: Color(red: 0.35, green: 0.5, blue: 0.95) // Linear blue
        )
      default:
        AgentTypeInfo(
          icon: "person.2.fill",
          label: type.isEmpty ? "Agent" : type.capitalized,
          color: Color(red: 0.5, green: 0.5, blue: 0.6) // Gray
        )
    }
  }
}
