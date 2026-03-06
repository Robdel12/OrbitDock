//
//  PermissionSummaryPopover.swift
//  OrbitDock
//
//  Inline permission panel showing real permission rules from the
//  provider's config. Mobile-first, collapsible tool groups with
//  swipe-to-delete on iOS.
//

import SwiftUI

// MARK: - Rule Parsing

private struct ParsedRule: Identifiable {
  let tool: String
  let detail: String?
  let behavior: String
  let rawPattern: String

  var id: String {
    "\(behavior):\(rawPattern)"
  }

  /// A short display label — trims long paths/commands to the meaningful part.
  var displayLabel: String {
    guard let detail else { return tool }

    // "domain:docs.anthropic.com" → "docs.anthropic.com"
    if detail.hasPrefix("domain:") {
      return String(detail.dropFirst(7))
    }

    // Long absolute paths → last 2 components
    if detail.hasPrefix("/"), detail.count > 40 {
      let parts = detail.split(separator: "/")
      if parts.count > 2 {
        return "…/" + parts.suffix(2).joined(separator: "/")
      }
    }

    // Very long env/command strings → first 50 chars
    if detail.count > 60 {
      return String(detail.prefix(50)) + "…"
    }

    return detail
  }

  static func parse(_ pattern: String, behavior: String) -> ParsedRule {
    if let parenStart = pattern.firstIndex(of: "("),
       let parenEnd = pattern.lastIndex(of: ")"),
       parenStart < parenEnd
    {
      let tool = String(pattern[pattern.startIndex ..< parenStart])
      let detail = String(pattern[pattern.index(after: parenStart) ..< parenEnd])
      return ParsedRule(tool: tool, detail: detail, behavior: behavior, rawPattern: pattern)
    }

    if pattern.hasPrefix("mcp__") {
      let parts = pattern.dropFirst(5).split(separator: "__", maxSplits: 1)
      if parts.count == 2 {
        return ParsedRule(
          tool: "MCP",
          detail: "\(parts[0]) · \(parts[1])",
          behavior: behavior,
          rawPattern: pattern
        )
      }
    }

    return ParsedRule(tool: pattern, detail: nil, behavior: behavior, rawPattern: pattern)
  }
}

// MARK: - Tool Group

private struct ToolGroup: Identifiable {
  let tool: String
  let rules: [ParsedRule]
  let behavior: String

  var id: String {
    "\(behavior):\(tool)"
  }

  var count: Int {
    rules.count
  }

  var color: Color {
    switch behavior {
      case "allow": .feedbackPositive
      case "deny": .feedbackNegative
      case "ask": .statusQuestion
      default: .textSecondary
    }
  }

  var icon: String {
    switch tool {
      case "Bash": "terminal"
      case "Edit", "Write", "Read": "doc.text"
      case "MCP": "puzzlepiece.extension"
      case "WebFetch": "globe"
      case "WebSearch": "magnifyingglass"
      case "Glob", "Grep": "text.magnifyingglass"
      default: "gearshape"
    }
  }

  static func group(_ parsed: [ParsedRule]) -> [ToolGroup] {
    var order: [String] = []
    var map: [String: [ParsedRule]] = [:]
    for rule in parsed {
      if map[rule.tool] == nil { order.append(rule.tool) }
      map[rule.tool, default: []].append(rule)
    }
    return order.compactMap { tool in
      guard let rules = map[tool] else { return nil }
      return ToolGroup(tool: tool, rules: rules, behavior: rules[0].behavior)
    }
  }
}

// MARK: - Inline Permission Panel

struct PermissionInlinePanel: View {
  let sessionId: String
  @Binding var isExpanded: Bool
  @Environment(ServerAppState.self) private var serverState

  @State private var headerHovering = false
  @State private var expandedGroups: Set<String> = []

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  private var currentSession: Session? {
    serverState.sessions.first { $0.id == sessionId }
  }

  // MARK: - Provider helpers

  private var panelColor: Color {
    guard let session = currentSession else { return .textTertiary }
    if session.isDirectCodex { return obs.autonomy.color }
    if session.isDirectClaude { return obs.permissionMode.color }
    return .textTertiary
  }

  private var panelTitle: String {
    guard let session = currentSession else { return "Permissions" }
    if session.isDirectCodex { return obs.autonomy.displayName }
    if session.isDirectClaude { return obs.permissionMode.displayName }
    return "Permissions"
  }

  private var panelIcon: String {
    guard let session = currentSession else { return "shield.lefthalf.filled" }
    if session.isDirectCodex { return obs.autonomy.icon }
    if session.isDirectClaude { return obs.permissionMode.icon }
    return "shield.lefthalf.filled"
  }

  private var modeDescription: String {
    guard let session = currentSession else { return "" }
    if session.isDirectCodex { return obs.autonomy.description }
    if session.isDirectClaude { return obs.permissionMode.description }
    return ""
  }

  // MARK: - Rule data

  private var parsedRules: [ParsedRule] {
    guard case let .claude(_, rules, _) = obs.permissionRules else { return [] }
    return rules.map { ParsedRule.parse($0.pattern, behavior: $0.behavior) }
  }

  private var allowRules: [ParsedRule] {
    parsedRules.filter { $0.behavior == "allow" }
  }

  private var denyRules: [ParsedRule] {
    parsedRules.filter { $0.behavior == "deny" }
  }

  private var askRules: [ParsedRule] {
    parsedRules.filter { $0.behavior == "ask" }
  }

  private var additionalDirectories: [String]? {
    guard case let .claude(_, _, dirs) = obs.permissionRules else { return nil }
    return dirs
  }

  private var ruleCount: Int {
    switch obs.permissionRules {
      case let .claude(_, rules, _): rules.count
      case .codex: 2
      case nil: 0
    }
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      headerButton

      if isExpanded {
        expandedContent
      }

      // Accent divider
      Rectangle()
        .fill(panelColor.opacity(OpacityTier.light))
        .frame(height: 0.5)
        .padding(.horizontal, Spacing.sm)
    }
    .onAppear { serverState.loadPermissionRules(sessionId: sessionId) }
    .onChange(of: isExpanded) { _, on in
      if on { serverState.loadPermissionRules(sessionId: sessionId) }
    }
  }

  // MARK: - Header

  private var headerButton: some View {
    Button {
      withAnimation(Motion.standard) { isExpanded.toggle() }
    } label: {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: panelIcon)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(panelColor)

        Text("Permissions")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        Text("\u{00B7}")
          .foregroundStyle(Color.textQuaternary)

        Text(panelTitle)
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(panelColor)

        if ruleCount > 0 {
          Text("\(ruleCount)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
            .foregroundStyle(panelColor.opacity(OpacityTier.vivid))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(panelColor.opacity(OpacityTier.light), in: Capsule())
        }

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textTertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(Motion.snappy, value: isExpanded)
      }
      .padding(.horizontal, Spacing.md_)
      .padding(.vertical, Spacing.sm_)
      .background(headerHovering ? Color.surfaceHover : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .platformHover { headerHovering = $0 }
  }

  // MARK: - Expanded content

  private var expandedContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Mode selector
        modeSelector
          .padding(.horizontal, Spacing.md_)

        // Description
        Text(modeDescription)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textSecondary)
          .padding(.horizontal, Spacing.md_)

        // Rules
        rulesContent
          .padding(.horizontal, Spacing.sm)
      }
      .padding(.top, Spacing.xs)
      .padding(.bottom, Spacing.sm)
    }
    .scrollIndicators(.hidden)
    .frame(maxHeight: 320)
    .transition(.opacity.animation(Motion.gentle.delay(0.05)))
  }

  // MARK: - Mode Selector

  @ViewBuilder
  private var modeSelector: some View {
    if let session = currentSession {
      if session.isDirectCodex { modePills(AutonomyLevel.allCases, current: obs.autonomy) }
      else if session.isDirectClaude { modePills(ClaudePermissionMode.allCases, current: obs.permissionMode) }
    }
  }

  private func modePills<T: Identifiable & CaseIterable & Equatable & PermissionModeRepresentable>(
    _ items: [T], current: T
  ) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        ForEach(items) { item in
          Button { selectMode(item) } label: {
            HStack(spacing: Spacing.xxs) {
              Image(systemName: item.icon)
                .font(.system(size: TypeScale.micro, weight: .semibold))
              Text(item.displayName)
                .font(.system(size: TypeScale.micro, weight: .semibold))
            }
            .foregroundStyle(item == current ? item.color : Color.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
              item == current
                ? item.color.opacity(OpacityTier.light)
                : Color.backgroundTertiary.opacity(OpacityTier.medium),
              in: Capsule()
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  private func selectMode(_ mode: some PermissionModeRepresentable) {
    if let level = mode as? AutonomyLevel {
      serverState.updateSessionConfig(sessionId: sessionId, autonomy: level)
    } else if let mode = mode as? ClaudePermissionMode {
      serverState.updateClaudePermissionMode(sessionId: sessionId, mode: mode)
    }
  }

  // MARK: - Rules Content

  @ViewBuilder
  private var rulesContent: some View {
    if obs.permissionRulesLoading, obs.permissionRules == nil {
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Loading…")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(.horizontal, Spacing.sm)
    } else if let session = currentSession {
      if session.isDirectClaude { claudeRulesContent }
      else if session.isDirectCodex { codexRulesContent }
    }
  }

  // MARK: - Claude rules

  @ViewBuilder
  private var claudeRulesContent: some View {
    if obs.permissionRules != nil {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if !allowRules.isEmpty { behaviorSection("Allowed", allowRules, .feedbackPositive) }
        if !denyRules.isEmpty { behaviorSection("Denied", denyRules, .feedbackNegative) }
        if !askRules.isEmpty { behaviorSection("Ask", askRules, .statusQuestion) }
        if let dirs = additionalDirectories, !dirs.isEmpty { directoriesSection(dirs) }

        if allowRules.isEmpty, denyRules.isEmpty, askRules.isEmpty {
          Text("No permission rules configured")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, Spacing.sm)
        }
      }
    }
  }

  // MARK: - Behavior section

  private func behaviorSection(_ title: String, _ rules: [ParsedRule], _ color: Color) -> some View {
    let groups = ToolGroup.group(rules)

    return VStack(alignment: .leading, spacing: Spacing.xxs) {
      // Section header
      HStack(spacing: Spacing.xs) {
        RoundedRectangle(cornerRadius: 1)
          .fill(color)
          .frame(width: EdgeBar.width, height: 10)

        Text(title.uppercased())
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(color.opacity(OpacityTier.vivid))

        Text("\(rules.count)")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(color.opacity(OpacityTier.medium))

        Spacer()
      }
      .padding(.horizontal, Spacing.sm_)
      .padding(.bottom, Spacing.xxs)

      // Tool groups
      ForEach(groups) { group in
        toolGroupCard(group)
      }
    }
  }

  // MARK: - Tool group card

  private func toolGroupCard(_ group: ToolGroup) -> some View {
    let isOpen = expandedGroups.contains(group.id)

    return VStack(alignment: .leading, spacing: 0) {
      // Header row
      Button {
        withAnimation(Motion.snappy) {
          if isOpen { expandedGroups.remove(group.id) }
          else { expandedGroups.insert(group.id) }
        }
      } label: {
        HStack(spacing: Spacing.sm_) {
          // Icon in tinted circle
          Image(systemName: group.icon)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(group.color)
            .frame(width: 22, height: 22)
            .background(group.color.opacity(OpacityTier.tint), in: Circle())

          Text(group.tool)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text("\(group.count)")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(group.color.opacity(OpacityTier.vivid))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(group.color.opacity(OpacityTier.tint), in: Capsule())

          Spacer(minLength: 0)

          Image(systemName: "chevron.right")
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Expanded rules
      if isOpen {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(group.rules) { rule in
            ruleRow(rule, color: group.color)
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .background(
      Color.backgroundTertiary.opacity(isOpen ? OpacityTier.medium : OpacityTier.tint),
      in: RoundedRectangle(cornerRadius: Radius.md)
    )
  }

  // MARK: - Individual rule row

  private func ruleRow(_ rule: ParsedRule, color: Color) -> some View {
    HStack(spacing: Spacing.sm_) {
      // Thin color indicator
      RoundedRectangle(cornerRadius: 1)
        .fill(color.opacity(OpacityTier.strong))
        .frame(width: 2)
        .padding(.vertical, Spacing.xxs)

      // Rule label — truncated smartly
      Text(rule.displayLabel)
        .font(.system(size: TypeScale.meta, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: Spacing.sm)

      // Remove button — sized for touch
      Button {
        withAnimation(Motion.snappy) {
          serverState.removePermissionRule(
            sessionId: sessionId,
            pattern: rule.rawPattern,
            behavior: rule.behavior
          )
        }
      } label: {
        Image(systemName: "minus.circle.fill")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textQuaternary)
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xxs)
  }

  // MARK: - Directories

  private func directoriesSection(_ dirs: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      HStack(spacing: Spacing.xs) {
        RoundedRectangle(cornerRadius: 1)
          .fill(Color.accent)
          .frame(width: EdgeBar.width, height: 10)

        Text("DIRECTORIES")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent.opacity(OpacityTier.vivid))

        Spacer()
      }
      .padding(.horizontal, Spacing.sm_)
      .padding(.bottom, Spacing.xxs)

      ForEach(dirs, id: \.self) { dir in
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "folder")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.accent)
            .frame(width: 22, height: 22)
            .background(Color.accent.opacity(OpacityTier.tint), in: Circle())

          Text(dir.abbreviatingHome)
            .font(.system(size: TypeScale.meta, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

          Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
        .background(Color.backgroundTertiary.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
      }
    }
  }

  // MARK: - Codex

  @ViewBuilder
  private var codexRulesContent: some View {
    if case let .codex(approvalPolicy, sandboxMode) = obs.permissionRules {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        codexRow("Approval Policy", approvalPolicy ?? "default")
        codexRow("Sandbox", sandboxMode ?? "default")
      }
      .padding(.horizontal, Spacing.sm)
    }
  }

  private func codexRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textSecondary)
      Spacer()
      Text(value)
        .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(Color.backgroundTertiary, in: Capsule())
    }
    .padding(.vertical, Spacing.xs)
    .padding(.horizontal, Spacing.sm)
    .background(Color.backgroundTertiary.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
  }
}

// MARK: - PermissionModeRepresentable

private protocol PermissionModeRepresentable: Identifiable, CaseIterable, Equatable {
  var icon: String { get }
  var displayName: String { get }
  var color: Color { get }
}

extension AutonomyLevel: PermissionModeRepresentable {}
extension ClaudePermissionMode: PermissionModeRepresentable {}

// MARK: - String Extension

private extension String {
  var abbreviatingHome: String {
    if let home = ProcessInfo.processInfo.environment["HOME"], hasPrefix(home) {
      return "~" + dropFirst(home.count)
    }
    return self
  }
}

// MARK: - Shared Helpers

enum ApprovalDecisionHelpers {
  static func label(for decision: String) -> String {
    switch decision {
      case "approved": "approved once"
      case "approved_for_session": "session-scoped"
      case "approved_always": "always allow"
      case "denied": "denied"
      case "abort": "denied & stop"
      default: decision
    }
  }

  static func color(for decision: String?) -> Color {
    switch decision {
      case "approved", "approved_for_session", "approved_always": .feedbackPositive
      case "denied", "abort": .feedbackNegative
      default: .textSecondary
    }
  }

  static func relativeTime(_ timestamp: String) -> String {
    guard let date = parseTimestamp(timestamp) else { return timestamp }
    return date.formatted(.relative(presentation: .named))
  }

  static func parseTimestamp(_ value: String) -> Date? {
    let stripped = value.hasSuffix("Z") ? String(value.dropLast()) : value
    if let seconds = TimeInterval(stripped) {
      return Date(timeIntervalSince1970: seconds)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

// MARK: - Legacy Popover Wrapper

struct PermissionSummaryPopover: View {
  let sessionId: String
  @State private var expanded = true

  var body: some View {
    ScrollView {
      PermissionInlinePanel(sessionId: sessionId, isExpanded: $expanded)
    }
    .scrollBounceBehavior(.basedOnSize)
    .ifMacOS { $0.frame(width: 360) }
    #if os(iOS)
      .frame(maxWidth: .infinity)
    #endif
      .background(Color.backgroundSecondary)
  }
}
