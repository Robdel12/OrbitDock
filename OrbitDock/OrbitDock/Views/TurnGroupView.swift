//
//  TurnGroupView.swift
//  OrbitDock
//
//  Turn-grouped rendering for focused chat mode.
//  Groups messages by turn and collapses older tool calls.
//

import SwiftUI

// MARK: - Turn Group View

struct TurnGroupView: View {
  let turn: TurnSummary
  let turnIndex: Int
  let provider: Provider
  let model: String?
  let sessionId: String?
  let onNavigateToReviewFile: ((String, Int) -> Void)?

  @Environment(ServerAppState.self) private var serverState
  @State private var isMiddleCollapsed: Bool = true
  @State private var cachedSplit: CachedSplit?
  @State private var cachedMetadata: [String: TurnMeta] = [:]

  /// How many trailing tool messages to show when collapsed
  private let visibleToolTail = 2
  /// Minimum tool count to trigger collapsing
  private let collapseThreshold = 2

  private var isActive: Bool {
    turn.status == .active
  }

  // MARK: - Message Splitting

  private struct SplitMessages {
    let leading: [TranscriptMessage] // user prompt, thinking before first tool
    let tools: [TranscriptMessage] // work-zone messages between first/last tool
    let trailing: [TranscriptMessage] // assistant response after last tool
    let toolCount: Int // actual tool messages (not interleaved non-tools)

    var hasTools: Bool {
      !tools.isEmpty
    }
  }

  private struct CollapsedToolSlice {
    let visibleMessages: [TranscriptMessage]
    let hiddenMessages: [TranscriptMessage]

    var hiddenCount: Int {
      hiddenMessages.count
    }
  }

  /// Only tool activity is eligible for roll-up.
  /// Assistant and user-facing messages remain visible in the timeline.
  private func isRollupEligible(_ message: TranscriptMessage) -> Bool {
    message.isTool
  }

  /// Assistant/thinking messages break collapse continuity when they sit between tools.
  /// Collapse can happen inside a run, but never across this boundary.
  private func isAgentRollupBoundary(_ message: TranscriptMessage) -> Bool {
    message.isAssistant || message.isThinking
  }

  /// Build contiguous runs of roll-up-eligible tools.
  /// Agent narrative messages split runs, preserving readable chronology.
  private func rollupEligibleRuns(in toolZoneMessages: [TranscriptMessage]) -> [[Int]] {
    var runs: [[Int]] = []
    var currentRun: [Int] = []

    for (index, message) in toolZoneMessages.enumerated() {
      if isAgentRollupBoundary(message) {
        if !currentRun.isEmpty {
          runs.append(currentRun)
          currentRun = []
        }
        continue
      }
      if isRollupEligible(message) {
        currentRun.append(index)
      }
    }

    if !currentRun.isEmpty {
      runs.append(currentRun)
    }

    return runs
  }

  /// Decide exactly which tool rows should be hidden in collapsed mode.
  /// Each run keeps its own trailing tools visible.
  private func hiddenRollupIndices(in toolZoneMessages: [TranscriptMessage]) -> Set<Int> {
    let runs = rollupEligibleRuns(in: toolZoneMessages)
    var hidden: Set<Int> = []

    for run in runs where run.count >= collapseThreshold {
      // Keep at least one tool visible from each collapsed run so chronology stays clear.
      let visibleTailCount = min(visibleToolTail, max(1, run.count - 1))
      let visibleTailIndices = Set(run.suffix(visibleTailCount))
      for index in run where !visibleTailIndices.contains(index) {
        hidden.insert(index)
      }
    }

    return hidden
  }

  private func collapseSlice(for toolZoneMessages: [TranscriptMessage], canCollapse: Bool) -> CollapsedToolSlice {
    let hiddenIndices = hiddenRollupIndices(in: toolZoneMessages)
    guard canCollapse, !hiddenIndices.isEmpty else {
      return CollapsedToolSlice(visibleMessages: toolZoneMessages, hiddenMessages: [])
    }

    var visibleMessages: [TranscriptMessage] = []
    var hiddenMessages: [TranscriptMessage] = []

    visibleMessages.reserveCapacity(toolZoneMessages.count)

    for (index, message) in toolZoneMessages.enumerated() {
      if hiddenIndices.contains(index) {
        hiddenMessages.append(message)
      } else {
        visibleMessages.append(message)
      }
    }

    return CollapsedToolSlice(visibleMessages: visibleMessages, hiddenMessages: hiddenMessages)
  }

  private func rollupEligibleCount(in toolZoneMessages: [TranscriptMessage]) -> Int {
    rollupEligibleRuns(in: toolZoneMessages).reduce(0) { currentMax, run in
      max(currentMax, run.count)
    }
  }

  private struct CachedSplit {
    let split: SplitMessages
    let canCollapse: Bool
    let rollupEligibleCount: Int
    let collapsed: CollapsedToolSlice
  }

  /// Single-pass split of turn messages into leading/tools/trailing.
  private func computeSplit() -> CachedSplit {
    var leading: [TranscriptMessage] = []
    var tools: [TranscriptMessage] = []
    var trailing: [TranscriptMessage] = []
    var foundFirstTool = false
    var lastToolIndex = -1
    var toolMsgCount = 0

    for (i, msg) in turn.messages.enumerated() {
      if msg.isTool { lastToolIndex = i; toolMsgCount += 1 }
    }

    for (i, msg) in turn.messages.enumerated() {
      if msg.isTool {
        foundFirstTool = true
        tools.append(msg)
      } else if !foundFirstTool {
        leading.append(msg)
      } else if i > lastToolIndex {
        trailing.append(msg)
      } else {
        tools.append(msg)
      }
    }

    let split = SplitMessages(
      leading: leading, tools: tools, trailing: trailing, toolCount: toolMsgCount
    )
    let eligibleCount = rollupEligibleCount(in: tools)
    let canCollapse = eligibleCount >= collapseThreshold
    let collapsed = collapseSlice(for: tools, canCollapse: canCollapse)

    return CachedSplit(split: split, canCollapse: canCollapse, rollupEligibleCount: eligibleCount, collapsed: collapsed)
  }

  // MARK: - Body

  var body: some View {
    let computed = cachedSplit ?? computeSplit()
    let split = computed.split
    let canCollapse = computed.canCollapse
    let collapsedTools = computed.collapsed
    let metadata = cachedMetadata.isEmpty ? computeTurnMetadata(turn.messages) : cachedMetadata

    VStack(alignment: .leading, spacing: ConversationLayout.turnVerticalSpacing) {
      // Turn separator (skip first turn)
      if turnIndex > 0 {
        TurnDivider()
      }

      // Leading messages (user prompt, etc.)
      ForEach(split.leading) { message in
        messageEntry(
          message: message,
          meta: metadata[message.id]
        )
      }

      // Tool zone — contained in a visually distinct panel
      if split.hasTools {
        HStack(alignment: .top, spacing: 0) {
          Rectangle()
            .fill(Color.accent.opacity(OpacityTier.medium))
            .frame(width: EdgeBar.width)

          VStack(alignment: .leading, spacing: 0) {
            // Collapsed state: compressed bar + visible tail
            if canCollapse, isMiddleCollapsed {
              if collapsedTools.hiddenCount > 0 {
                CompressedToolBar(
                  hiddenMessages: collapsedTools.hiddenMessages,
                  count: collapsedTools.hiddenCount,
                  totalToolCount: split.toolCount
                ) {
                  withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isMiddleCollapsed = false
                  }
                }
              }

              // Show non-agent interleaves + trailing agent tail (constant-height-ish while active)
              ForEach(collapsedTools.visibleMessages) { message in
                messageEntry(
                  message: message,
                  meta: metadata[message.id]
                )
              }
            } else {
              // Show all tool messages
              ForEach(split.tools) { message in
                messageEntry(
                  message: message,
                  meta: metadata[message.id]
                )
              }

              // Collapse affordance when expanded
              if canCollapse, collapsedTools.hiddenCount > 0 {
                CollapseAffordance(count: collapsedTools.hiddenCount) {
                  withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isMiddleCollapsed = true
                  }
                }
              }
            }
          }
          .padding(.vertical, ConversationLayout.toolZoneInnerVerticalInset)
          .padding(.horizontal, ConversationLayout.toolZoneInnerHorizontalInset)
        }
        .background(
          Color.backgroundTertiary.opacity(0.5),
          in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        )
        .frame(maxWidth: ConversationLayout.assistantRailMaxWidth, alignment: .leading)
        .padding(.horizontal, ConversationLayout.laneHorizontalInset)
        .padding(.top, ConversationLayout.toolZoneOuterVerticalInset)
        .padding(
          .bottom,
          split.trailing.isEmpty
            ? ConversationLayout.toolZoneOuterVerticalInset
            : 8
        )
      }

      // Trailing messages (assistant response)
      ForEach(split.trailing) { message in
        messageEntry(
          message: message,
          meta: metadata[message.id]
        )
      }

      // Per-turn token footer (completed turns only)
      if !isActive, let usage = turn.tokenUsage, usage.contextWindow > 0 {
        TurnTokenFooter(usage: usage, delta: turn.tokenDelta)
      }
    }
    .onChange(of: isActive) { wasActive, nowActive in
      // Auto-collapse when turn completes
      if wasActive, !nowActive, turn.messages.lazy.filter(\.isTool).count >= collapseThreshold {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          isMiddleCollapsed = true
        }
      }
    }
    .onChange(of: turn.messages.count) { _, _ in
      cachedSplit = computeSplit()
      cachedMetadata = computeTurnMetadata(turn.messages)
      // Keep active turns stable as tools stream in.
      guard isActive else { return }
      if let cached = cachedSplit, cached.rollupEligibleCount >= collapseThreshold, !isMiddleCollapsed {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          isMiddleCollapsed = true
        }
      }
    }
    .onChange(of: turn.messages.map(\.id)) { _, _ in
      cachedMetadata = computeTurnMetadata(turn.messages)
    }
    .onAppear {
      cachedSplit = computeSplit()
      cachedMetadata = computeTurnMetadata(turn.messages)
      // Completed turns start collapsed. Active turns collapse once tool activity gets dense.
      let eligibleCount = cachedSplit?.rollupEligibleCount ?? 0
      isMiddleCollapsed = !isActive || eligibleCount >= collapseThreshold
    }
  }

  // MARK: - Message Entry

  @ViewBuilder
  private func messageEntry(message: TranscriptMessage, meta: TurnMeta?) -> some View {
    let turnsAfter = meta?.turnsAfter
    let nthUser = meta?.nthUserMessage

    WorkStreamEntry(
      message: message,
      provider: provider,
      model: model,
      sessionId: sessionId,
      rollbackTurns: turnsAfter,
      nthUserMessage: nthUser,
      onRollback: turnsAfter != nil ? {
        if let sid = sessionId, let turns = turnsAfter {
          serverState.rollbackTurns(sessionId: sid, numTurns: UInt32(turns))
        }
      } : nil,
      onFork: nthUser != nil ? {
        if let sid = sessionId, let nth = nthUser {
          serverState.forkSession(sessionId: sid, nthUserMessage: UInt32(nth))
        }
      } : nil,
      onNavigateToReviewFile: onNavigateToReviewFile
    )
  }

  // MARK: - Turn Metadata

  private struct TurnMeta {
    let turnsAfter: Int?
    let nthUserMessage: Int?
  }

  private func computeTurnMetadata(_ msgs: [TranscriptMessage]) -> [String: TurnMeta] {
    var result: [String: TurnMeta] = [:]
    result.reserveCapacity(msgs.count)

    var userCount = 0
    var userIndices: [Int] = []
    for (i, msg) in msgs.enumerated() {
      if msg.isUser {
        result[msg.id] = TurnMeta(turnsAfter: 0, nthUserMessage: userCount)
        userCount += 1
        userIndices.append(i)
      } else {
        result[msg.id] = TurnMeta(turnsAfter: nil, nthUserMessage: nil)
      }
    }

    for (rank, msgIndex) in userIndices.enumerated() {
      let userMsgsAfter = userIndices.count - rank - 1
      let turnsAfter: Int
      if userMsgsAfter > 0 {
        turnsAfter = userMsgsAfter
      } else {
        let hasResponseAfter = msgs[(msgIndex + 1)...].contains { !$0.isUser }
        turnsAfter = hasResponseAfter ? 1 : 0
      }

      let existing = result[msgs[msgIndex].id]
      result[msgs[msgIndex].id] = TurnMeta(
        turnsAfter: turnsAfter > 0 ? turnsAfter : nil,
        nthUserMessage: existing?.nthUserMessage
      )
    }

    return result
  }
}

// MARK: - Turn Divider

/// Visual separator between turns — creates breathing room and hierarchy.
private struct TurnDivider: View {
  var body: some View {
    VStack(spacing: 0) {
      Spacer().frame(height: 8)
      Rectangle()
        .fill(Color.surfaceBorder.opacity(0.28))
        .frame(height: 1)
        .padding(.horizontal, ConversationLayout.laneHorizontalInset)
      Spacer().frame(height: 8)
    }
  }
}

// MARK: - Tool Glyph Resolution

/// Resolves a TranscriptMessage's tool name to its glyph icon and accent color.
private struct ToolGlyph {
  let icon: String
  let color: Color

  static func resolve(from message: TranscriptMessage) -> ToolGlyph {
    guard let name = message.toolName else {
      return ToolGlyph(icon: "gearshape", color: .secondary)
    }
    let lowercased = name.lowercased()
    if name.hasPrefix("mcp__") {
      return ToolGlyph(icon: "puzzlepiece.extension", color: .toolMcp)
    }
    switch lowercased {
      case "bash": return ToolGlyph(icon: "terminal", color: .toolBash)
      case "read": return ToolGlyph(icon: "doc.plaintext", color: .toolRead)
      case "edit", "write", "notebookedit": return ToolGlyph(icon: "pencil.line", color: .toolWrite)
      case "glob", "grep": return ToolGlyph(icon: "magnifyingglass", color: .toolSearch)
      case "task": return ToolGlyph(icon: "bolt.fill", color: .toolTask)
      case "webfetch", "websearch": return ToolGlyph(icon: "globe", color: .toolWeb)
      case "skill": return ToolGlyph(icon: "wand.and.stars", color: .toolSkill)
      case "enterplanmode", "exitplanmode": return ToolGlyph(icon: "map", color: .toolPlan)
      case "taskcreate", "taskupdate", "tasklist", "taskget":
        return ToolGlyph(icon: "checklist", color: .toolTodo)
      case "askuserquestion": return ToolGlyph(icon: "questionmark.bubble", color: .toolQuestion)
      default: return ToolGlyph(icon: "gearshape", color: .secondary)
    }
  }
}

// MARK: - Tool Breakdown Entry (iOS local — uses ToolGlyph)

private struct CompressedToolEntry: Identifiable {
  let id: String // tool name
  let glyph: ToolGlyph
  let count: Int
}

// MARK: - Compressed Tool Bar (Collapsed State)

/// Full-width bar showing tool breakdown and overlapping glyphs.
/// Uses horizontal space to communicate what happened during the collapsed section.
private struct CompressedToolBar: View {
  let hiddenMessages: [TranscriptMessage]
  let count: Int
  let totalToolCount: Int
  let action: () -> Void

  @State private var isHovering = false

  /// Tool breakdown: grouped by name, sorted by frequency
  private var breakdown: [CompressedToolEntry] {
    var counts: [(name: String, glyph: ToolGlyph, count: Int)] = []
    var countMap: [String: Int] = [:]
    var glyphMap: [String: ToolGlyph] = [:]

    for msg in hiddenMessages where msg.isTool {
      let name = msg.toolName ?? "tool"
      countMap[name, default: 0] += 1
      if glyphMap[name] == nil {
        glyphMap[name] = ToolGlyph.resolve(from: msg)
      }
    }

    for (name, count) in countMap.sorted(by: { $0.value > $1.value }) {
      counts.append((name, glyphMap[name]!, count))
    }

    return counts.map { CompressedToolEntry(id: $0.name, glyph: $0.glyph, count: $0.count) }
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 0) {
        // Left: action count badge
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isHovering ? Color.accent : Color.textSecondary)
            .rotationEffect(.degrees(isHovering ? 90 : 0))

          Text("\(count)")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(isHovering ? Color.textPrimary : Color.textPrimary)

          Text("actions")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }
        .padding(.trailing, 16)

        // Separator dot
        Circle()
          .fill(Color.surfaceBorder)
          .frame(width: 3, height: 3)
          .padding(.trailing, 16)

        // Center: tool breakdown chips
        toolBreakdownRow
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(isHovering ? Color.backgroundTertiary : Color.backgroundTertiary.opacity(0.7))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .strokeBorder(
            isHovering ? Color.accent.opacity(OpacityTier.light) : Color.surfaceBorder.opacity(0.4),
            lineWidth: 0.5
          )
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
        isHovering = hovering
      }
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.vertical, 3)
  }

  // MARK: - Tool Breakdown Row

  private var toolBreakdownRow: some View {
    Group {
      if breakdown.isEmpty {
        Text("Agent updates")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color.textTertiary)
      } else {
        HStack(spacing: 12) {
          ForEach(breakdown.prefix(6)) { entry in
            HStack(spacing: 5) {
              Image(systemName: entry.glyph.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(entry.glyph.color)

              Text("\(entry.count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.textSecondary)

              Text(displayName(for: entry.id))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
            }
          }
        }
      }
    }
  }

  /// Clean up tool names for display
  private func displayName(for toolName: String) -> String {
    let lowered = toolName.lowercased()
    switch lowered {
      case "bash": return "Bash"
      case "read": return "Read"
      case "edit": return "Edit"
      case "write": return "Write"
      case "glob": return "Glob"
      case "grep": return "Grep"
      case "task": return "Task"
      case "webfetch": return "Fetch"
      case "websearch": return "Search"
      case "skill": return "Skill"
      case "enterplanmode": return "Plan"
      case "exitplanmode": return "Plan"
      case "taskcreate", "taskupdate", "tasklist", "taskget": return "Todo"
      case "askuserquestion": return "Question"
      case "notebookedit": return "Notebook"
      default:
        if toolName.hasPrefix("mcp__") {
          return toolName
            .replacingOccurrences(of: "mcp__", with: "")
            .components(separatedBy: "__").last ?? "MCP"
        }
        return toolName
    }
  }
}

// MARK: - Collapse Affordance (Expanded State)

/// Minimal fold line shown when turn is expanded and can be re-collapsed.
private struct CollapseAffordance: View {
  let count: Int
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        // Left line
        Rectangle()
          .fill(Color.surfaceBorder.opacity(isHovering ? 0.4 : 0.2))
          .frame(height: 0.5)
          .frame(maxWidth: .infinity)

        // Compress indicator
        HStack(spacing: 5) {
          Image(systemName: "arrow.up.and.line.horizontal.and.arrow.down")
            .font(.system(size: 9, weight: .semibold))

          Text("Collapse \(count)")
            .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(isHovering ? Color.accent : Color.textQuaternary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
          Capsule()
            .fill(isHovering ? Color.surfaceHover : Color.clear)
        )

        // Right line
        Rectangle()
          .fill(Color.surfaceBorder.opacity(isHovering ? 0.4 : 0.2))
          .frame(height: 0.5)
          .frame(maxWidth: .infinity)
      }
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: 28)
  }
}

// MARK: - Turn Token Footer

/// Shows context fill and token delta for a completed turn.
private struct TurnTokenFooter: View {
  let usage: ServerTokenUsage
  let delta: Int?

  private var fillPercent: Double {
    usage.contextFillPercent
  }

  private var fillColor: Color {
    if fillPercent >= 90 { return Color(red: 1.0, green: 0.4, blue: 0.4) }
    if fillPercent >= 70 { return Color(red: 1.0, green: 0.7, blue: 0.3) }
    return Color.accent
  }

  var body: some View {
    HStack(spacing: 8) {
      // Mini context fill bar
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.surfaceBorder.opacity(0.3))
          RoundedRectangle(cornerRadius: 2)
            .fill(fillColor)
            .frame(width: geo.size.width * min(fillPercent / 100, 1.0))
        }
      }
      .frame(width: 40, height: 4)

      Text(String(format: "%.0f%%", fillPercent))
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(fillColor)

      // Delta pill
      if let delta, delta > 0 {
        Text("+\(formatK(delta))")
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            Capsule()
              .fill(Color.backgroundTertiary)
          )
      }

      Spacer()
    }
    .padding(.horizontal, ConversationLayout.laneHorizontalInset)
    .padding(.vertical, 4)
  }

  private func formatK(_ tokens: Int) -> String {
    if tokens >= 1_000 {
      let k = Double(tokens) / 1_000.0
      return k >= 100 ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
    return "\(tokens)"
  }
}
