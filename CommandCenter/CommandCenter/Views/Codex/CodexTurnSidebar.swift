//
//  CodexTurnSidebar.swift
//  OrbitDock
//
//  Combined sidebar for Codex turn state: Plan and Changes.
//  Allows switching between views with animated tabs.
//

import SwiftUI

struct CodexTurnSidebar: View {
  let sessionId: String
  let onClose: () -> Void
  @Binding var selectedTab: Tab
  @Binding var selectedSkills: Set<String>

  @Environment(ServerAppState.self) private var serverState

  enum Tab: String, CaseIterable {
    case plan = "Plan"
    case changes = "Changes"
    case servers = "Servers"
    case skills = "Skills"

    var icon: String {
      switch self {
        case .plan: "list.bullet.clipboard"
        case .changes: "doc.badge.plus"
        case .servers: "puzzlepiece.extension"
        case .skills: "bolt.fill"
      }
    }
  }

  private var plan: [Session.PlanStep]? {
    serverState.getPlanSteps(sessionId: sessionId)
  }

  private var diff: String? {
    serverState.getDiff(sessionId: sessionId)
  }

  private var skills: [ServerSkillMetadata] {
    (serverState.sessionSkills[sessionId] ?? []).filter { $0.enabled }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Tab header
      HStack(spacing: 0) {
        ForEach(Tab.allCases, id: \.self) { tab in
          tabButton(tab)
        }

        Spacer()

        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 24, height: 24)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
      }
      .padding(.leading, 4)
      .padding(.vertical, 6)
      .background(Color.backgroundSecondary)

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Content
      Group {
        switch selectedTab {
          case .plan:
            if let steps = plan, !steps.isEmpty {
              planContent(steps: steps)
            } else {
              emptyState(
                icon: "list.bullet.clipboard",
                title: "No Plan Yet",
                message: "The agent's plan will appear here when working"
              )
            }

          case .changes:
            if let diff, !diff.isEmpty {
              diffContent(diff: diff)
            } else {
              emptyState(
                icon: "doc.badge.plus",
                title: "No Changes Yet",
                message: "File changes will appear here during the turn"
              )
            }

          case .servers:
            if serverState.hasMcpData(sessionId: sessionId) {
              McpServersTab(sessionId: sessionId)
            } else {
              emptyState(
                icon: "puzzlepiece.extension",
                title: "No MCP Servers",
                message: "MCP servers will appear here when configured"
              )
            }

          case .skills:
            if !skills.isEmpty {
              SkillsTab(sessionId: sessionId, selectedSkills: $selectedSkills)
            } else {
              emptyState(
                icon: "bolt.slash",
                title: "No Skills",
                message: "Skills will appear here when available"
              )
            }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.backgroundSecondary)
    .onAppear {
      // Auto-select only when default tab (plan) has no content
      // Respects parent-set tab (e.g. when opened via input bar bolt)
      if selectedTab == .plan, plan == nil || plan!.isEmpty {
        if diff != nil, !diff!.isEmpty {
          selectedTab = .changes
        } else if serverState.hasMcpData(sessionId: sessionId) {
          selectedTab = .servers
        } else if !skills.isEmpty {
          selectedTab = .skills
        }
      }
    }
    .onChange(of: selectedTab) { _, newTab in
      // Auto-fetch MCP tools when switching to servers tab
      if newTab == .servers {
        let hasTools = !(serverState.mcpTools[sessionId]?.isEmpty ?? true)
        if !hasTools {
          serverState.listMcpTools(sessionId: sessionId)
        }
      }
      // Auto-fetch skills when switching to skills tab
      if newTab == .skills {
        if skills.isEmpty {
          serverState.listSkills(sessionId: sessionId)
        }
      }
    }
  }

  @ViewBuilder
  private func tabButton(_ tab: Tab) -> some View {
    let isSelected = selectedTab == tab

    Button {
      withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
        selectedTab = tab
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: tab.icon)
          .font(.system(size: 11, weight: .medium))

        if isSelected {
          Text(tab.rawValue)
            .font(.system(size: 11, weight: .medium))
        }
      }
      .padding(.horizontal, isSelected ? 10 : 8)
      .padding(.vertical, 6)
      .foregroundStyle(isSelected ? Color.accent : .secondary)
      .background(
        isSelected ? Color.accent.opacity(0.15) : Color.clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
    }
    .buttonStyle(.plain)
    .help(tab.rawValue)
  }

  private func planContent(steps: [Session.PlanStep]) -> some View {
    ScrollView(.vertical, showsIndicators: true) {
      VStack(alignment: .leading, spacing: 0) {
        // Progress header
        HStack {
          Text("\(completedCount(steps))/\(steps.count) steps")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

          Spacer()

          CircularProgressView(progress: progress(steps))
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.5))

        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
          PlanStepRow(
            step: step,
            index: index + 1,
            isLast: index == steps.count - 1
          )
        }
      }
      .padding(.vertical, 4)
    }
    .background(Color.backgroundPrimary)
  }

  @ViewBuilder
  private func diffContent(diff: String) -> some View {
    let parsed = parseDiffLines(diff)

    VStack(spacing: 0) {
      // Stats header
      HStack {
        Text("+\(additionCount(parsed))")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.5))

        Text("−\(deletionCount(parsed))")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5))

        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      ScrollView([.vertical, .horizontal], showsIndicators: true) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(parsed) { line in
            DiffLineRow(line: line)
          }
        }
        .padding(.vertical, 4)
      }
    }
    .background(Color.backgroundPrimary)
  }

  private func emptyState(icon: String, title: String, message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(.tertiary)

      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)

      Text(message)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.backgroundPrimary)
  }

  // MARK: - Helpers

  private func completedCount(_ steps: [Session.PlanStep]) -> Int {
    steps.filter(\.isCompleted).count
  }

  private func progress(_ steps: [Session.PlanStep]) -> Double {
    guard !steps.isEmpty else { return 0 }
    return Double(completedCount(steps)) / Double(steps.count)
  }

  private func parseDiffLines(_ diff: String) -> [CodexParsedDiffLine] {
    diff.components(separatedBy: "\n").map { line in
      if line.hasPrefix("+++") || line.hasPrefix("---") {
        CodexParsedDiffLine(text: line, type: .header)
      } else if line.hasPrefix("@@") {
        CodexParsedDiffLine(text: line, type: .hunk)
      } else if line.hasPrefix("+") {
        CodexParsedDiffLine(text: line, type: .addition)
      } else if line.hasPrefix("-") {
        CodexParsedDiffLine(text: line, type: .deletion)
      } else {
        CodexParsedDiffLine(text: line, type: .context)
      }
    }
  }

  private func additionCount(_ lines: [CodexParsedDiffLine]) -> Int {
    lines.filter { $0.type == .addition }.count
  }

  private func deletionCount(_ lines: [CodexParsedDiffLine]) -> Int {
    lines.filter { $0.type == .deletion }.count
  }
}

// MARK: - Plan Step Row

private struct PlanStepRow: View {
  let step: Session.PlanStep
  let index: Int
  let isLast: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Status indicator with connector line
      VStack(spacing: 0) {
        statusIcon
          .frame(width: 20, height: 20)

        if !isLast {
          Rectangle()
            .fill(connectorColor)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
        }
      }

      // Step content
      VStack(alignment: .leading, spacing: 2) {
        Text(step.step)
          .font(.system(size: 12))
          .foregroundStyle(textColor)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)

        Text(statusLabel)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(statusLabelColor)
      }
      .padding(.bottom, isLast ? 0 : 12)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .contentShape(Rectangle())
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step.status)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch step.status {
      case "completed":
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(Color.statusReady)

      case "inProgress":
        ZStack {
          Circle()
            .stroke(Color.accent.opacity(0.3), lineWidth: 2)
          Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.accent, lineWidth: 2)
            .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .modifier(SpinningModifier())

      case "failed":
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(Color.statusPermission)

      default: // pending
        Circle()
          .stroke(Color.secondary.opacity(0.4), lineWidth: 2)
          .frame(width: 16, height: 16)
    }
  }

  private var textColor: Color {
    switch step.status {
      case "completed": .primary.opacity(0.6)
      case "inProgress": .primary
      case "failed": .statusPermission
      default: .secondary
    }
  }

  private var statusLabel: String {
    switch step.status {
      case "completed": "Done"
      case "inProgress": "In progress..."
      case "failed": "Failed"
      default: "Pending"
    }
  }

  private var statusLabelColor: Color {
    switch step.status {
      case "completed": .statusReady.opacity(0.8)
      case "inProgress": Color.accent
      case "failed": .statusPermission
      default: .secondary.opacity(0.6)
    }
  }

  private var connectorColor: Color {
    switch step.status {
      case "completed": .statusReady.opacity(0.3)
      case "inProgress": Color.accent.opacity(0.3)
      default: Color.secondary.opacity(0.2)
    }
  }
}

// MARK: - Diff Line Row

private struct DiffLineRow: View {
  let line: CodexParsedDiffLine

  private let addedBg = Color(red: 0.15, green: 0.32, blue: 0.18).opacity(0.6)
  private let removedBg = Color(red: 0.35, green: 0.14, blue: 0.14).opacity(0.6)
  private let addedAccent = Color(red: 0.4, green: 0.95, blue: 0.5)
  private let removedAccent = Color(red: 1.0, green: 0.5, blue: 0.5)

  var body: some View {
    HStack(spacing: 0) {
      Text(prefix)
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(prefixColor)
        .frame(width: 16)

      Text(lineContent)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(textColor)
        .lineLimit(1)
        .textSelection(.enabled)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(backgroundColor)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var prefix: String {
    switch line.type {
      case .addition: "+"
      case .deletion: "−"
      case .hunk: "@"
      default: " "
    }
  }

  private var lineContent: String {
    switch line.type {
      case .addition, .deletion:
        String(line.text.dropFirst())
      default:
        line.text
    }
  }

  private var prefixColor: Color {
    switch line.type {
      case .addition: addedAccent
      case .deletion: removedAccent
      case .hunk: Color.accent
      default: .clear
    }
  }

  private var textColor: Color {
    switch line.type {
      case .header: .secondary
      case .hunk: Color.accent
      case .addition: addedAccent
      case .deletion: removedAccent
      case .context: .primary.opacity(0.7)
    }
  }

  private var backgroundColor: Color {
    switch line.type {
      case .addition: addedBg
      case .deletion: removedBg
      case .hunk: Color.accent.opacity(0.05)
      default: .clear
    }
  }
}

// MARK: - Circular Progress View

private struct CircularProgressView: View {
  let progress: Double

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.2), lineWidth: 2)

      Circle()
        .trim(from: 0, to: progress)
        .stroke(
          progress >= 1.0 ? Color.statusReady : Color.accent,
          style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
    }
  }
}

// MARK: - Spinning Animation Modifier

private struct SpinningModifier: ViewModifier {
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

// MARK: - Preview

#Preview("With Content") {
  @Previewable @State var tab: CodexTurnSidebar.Tab = .plan
  @Previewable @State var skills: Set<String> = []
  CodexTurnSidebar(
    sessionId: "test",
    onClose: {},
    selectedTab: $tab,
    selectedSkills: $skills
  )
  .environment(ServerAppState())
  .frame(width: 320, height: 500)
  .background(Color.backgroundPrimary)
}

#Preview("Empty") {
  @Previewable @State var tab: CodexTurnSidebar.Tab = .plan
  @Previewable @State var skills: Set<String> = []
  CodexTurnSidebar(
    sessionId: "empty",
    onClose: {},
    selectedTab: $tab,
    selectedSkills: $skills
  )
  .environment(ServerAppState())
  .frame(width: 320, height: 400)
  .background(Color.backgroundPrimary)
}
