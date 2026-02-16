//
//  Session.swift
//  OrbitDock
//

import Foundation

// MARK: - Codex Integration Mode

/// Distinguishes passive (file watching) from direct (app-server JSON-RPC) Codex sessions
enum CodexIntegrationMode: String, Hashable, Sendable {
  case passive // FSEvents watching of rollout files (current behavior)
  case direct // App-server JSON-RPC (full bidirectional control)
}

// MARK: - Claude Integration Mode

/// Distinguishes passive (hooks-based) from direct (server-managed) Claude sessions
enum ClaudeIntegrationMode: String, Hashable, Sendable {
  case passive // Hooks-based monitoring (current behavior)
  case direct // Server-managed bidirectional control
}

struct Session: Identifiable, Hashable, Sendable {
  let id: String
  let projectPath: String
  let projectName: String?
  var branch: String?
  var model: String?
  var summary: String? // AI-generated conversation title
  var customName: String? // User-defined custom name (overrides summary)
  var firstPrompt: String? // First user message (conversation-specific fallback)
  var lastMessage: String? // Most recent user or assistant message (for dashboard context)
  let transcriptPath: String?
  var status: SessionStatus
  var workStatus: WorkStatus
  let startedAt: Date?
  var endedAt: Date?
  let endReason: String?
  var totalTokens: Int
  var totalCostUSD: Double
  var lastActivityAt: Date?
  var lastTool: String?
  var lastToolAt: Date?
  var promptCount: Int
  var toolCount: Int
  var terminalSessionId: String?
  var terminalApp: String?
  var attentionReason: AttentionReason
  var pendingToolName: String? // Which tool needs permission
  var pendingToolInput: String? // JSON string of tool input (for rich permission display)
  var pendingQuestion: String? // Question text from AskUserQuestion
  var provider: Provider // AI provider (claude, codex)

  // MARK: - Direct Integration

  var codexIntegrationMode: CodexIntegrationMode? // nil for non-Codex sessions
  var claudeIntegrationMode: ClaudeIntegrationMode? // nil for non-Claude direct sessions
  var codexThreadId: String? // Thread ID for direct Codex sessions
  var pendingApprovalId: String? // Request ID for approval correlation

  // MARK: - Token Usage

  var inputTokens: Int? // Input tokens used in session
  var outputTokens: Int? // Output tokens generated
  var cachedTokens: Int? // Cached input tokens (cost savings)
  var contextWindow: Int? // Model context window size

  // MARK: - Turn State (transient, updated during turns)

  var gitSha: String? // Git commit SHA
  var currentCwd: String? // Agent's current working directory

  var currentDiff: String? // Aggregated diff for current turn
  var currentPlan: [PlanStep]? // Agent's plan for current turn

  struct PlanStep: Codable, Hashable, Identifiable, Sendable {
    let step: String
    let status: String

    var id: String {
      step
    }

    var isCompleted: Bool {
      status == "completed"
    }

    var isInProgress: Bool {
      status == "inProgress"
    }
  }

  enum SessionStatus: String, Sendable {
    case active
    case idle
    case ended
  }

  enum WorkStatus: String, Sendable {
    case working // Agent is actively processing
    case waiting // Waiting for user input
    case permission // Waiting for permission approval
    case unknown // Unknown state
  }

  enum AttentionReason: String, Sendable {
    case none // Working or ended - no attention needed
    case awaitingReply // Agent finished, waiting for next prompt
    case awaitingPermission // Tool needs approval (Bash, Write, etc.)
    case awaitingQuestion // AskUserQuestion tool - agent asked a question

    var label: String {
      switch self {
        case .none: ""
        case .awaitingReply: "Ready"
        case .awaitingPermission: "Permission"
        case .awaitingQuestion: "Question"
      }
    }

    var icon: String {
      switch self {
        case .none: "circle"
        case .awaitingReply: "checkmark.circle"
        case .awaitingPermission: "lock.fill"
        case .awaitingQuestion: "questionmark.bubble"
      }
    }
  }

  /// Custom initializer with backward compatibility for legacy code using contextLabel
  nonisolated init(
    id: String,
    projectPath: String,
    projectName: String? = nil,
    branch: String? = nil,
    model: String? = nil,
    summary: String? = nil,
    customName: String? = nil,
    firstPrompt: String? = nil,
    contextLabel: String? = nil, // Legacy parameter, mapped to customName
    transcriptPath: String? = nil,
    status: SessionStatus,
    workStatus: WorkStatus,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    endReason: String? = nil,
    totalTokens: Int = 0,
    totalCostUSD: Double = 0,
    lastActivityAt: Date? = nil,
    lastTool: String? = nil,
    lastToolAt: Date? = nil,
    promptCount: Int = 0,
    toolCount: Int = 0,
    terminalSessionId: String? = nil,
    terminalApp: String? = nil,
    attentionReason: AttentionReason = .none,
    pendingToolName: String? = nil,
    pendingToolInput: String? = nil,
    pendingQuestion: String? = nil,
    provider: Provider = .claude,
    codexIntegrationMode: CodexIntegrationMode? = nil,
    claudeIntegrationMode: ClaudeIntegrationMode? = nil,
    codexThreadId: String? = nil,
    pendingApprovalId: String? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    cachedTokens: Int? = nil,
    contextWindow: Int? = nil
  ) {
    self.id = id
    self.projectPath = projectPath
    self.projectName = projectName
    self.branch = branch
    self.model = model
    self.summary = summary
    // Don't use contextLabel as customName fallback - it's just source metadata (e.g., "codex_cli_rs")
    // Let displayName fall through to firstPrompt or projectName instead
    self.customName = customName
    self.firstPrompt = firstPrompt
    self.transcriptPath = transcriptPath
    self.status = status
    self.workStatus = workStatus
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.endReason = endReason
    self.totalTokens = totalTokens
    self.totalCostUSD = totalCostUSD
    self.lastActivityAt = lastActivityAt
    self.lastTool = lastTool
    self.lastToolAt = lastToolAt
    self.promptCount = promptCount
    self.toolCount = toolCount
    self.terminalSessionId = terminalSessionId
    self.terminalApp = terminalApp
    self.attentionReason = attentionReason
    self.pendingToolName = pendingToolName
    self.pendingToolInput = pendingToolInput
    self.pendingQuestion = pendingQuestion
    self.provider = provider
    self.codexIntegrationMode = codexIntegrationMode
    self.claudeIntegrationMode = claudeIntegrationMode
    self.codexThreadId = codexThreadId
    self.pendingApprovalId = pendingApprovalId
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedTokens = cachedTokens
    self.contextWindow = contextWindow
  }

  var displayName: String {
    let raw = customName ?? summary ?? firstPrompt ?? projectName ?? projectPath.components(separatedBy: "/").last ?? "Unknown"
    return raw.strippingXMLTags()
  }

  /// For backward compatibility
  var contextLabel: String? {
    get { customName }
    set { customName = newValue }
  }

  var isActive: Bool {
    status == .active
  }

  var needsAttention: Bool {
    isActive && attentionReason != .none && attentionReason != .awaitingReply
  }

  /// Returns true if session is waiting but not blocking (just needs a reply)
  var isReady: Bool {
    isActive && attentionReason == .awaitingReply
  }

  // MARK: - Direct Integration

  /// Returns true if this is a direct Codex session (not passive file watching)
  var isDirectCodex: Bool {
    provider == .codex && codexIntegrationMode == .direct
  }

  /// Returns true if this is a direct Claude session (server-managed)
  var isDirectClaude: Bool {
    provider == .claude && claudeIntegrationMode == .direct
  }

  /// Returns true if this is any direct (server-controlled) session
  var isDirect: Bool {
    isDirectCodex || isDirectClaude
  }

  /// Returns true if user can send input to this session (any direct session)
  var canSendInput: Bool {
    guard isActive else { return false }
    return isDirect
  }

  /// Returns true if user can approve/reject a pending tool (direct Codex only)
  var canApprove: Bool {
    canSendInput && attentionReason == .awaitingPermission && pendingApprovalId != nil
  }

  /// Returns true if user can answer a pending question (direct Codex only)
  var canAnswer: Bool {
    canSendInput && attentionReason == .awaitingQuestion && pendingApprovalId != nil
  }

  var statusIcon: String {
    if !isActive { return "moon.fill" }
    switch workStatus {
      case .working: return "bolt.fill"
      case .waiting: return "hand.raised.fill"
      case .permission: return "lock.fill"
      case .unknown: return "questionmark.circle"
    }
  }

  var statusColor: String {
    if !isActive { return "secondary" }
    switch workStatus {
      case .working: return "green"
      case .waiting: return "orange"
      case .permission: return "yellow"
      case .unknown: return "secondary"
    }
  }

  var statusLabel: String {
    if !isActive { return "Ended" }
    switch workStatus {
      case .working: return "Working"
      case .waiting: return "Waiting"
      case .permission: return "Permission"
      case .unknown: return "Active"
    }
  }

  var duration: TimeInterval? {
    guard let start = startedAt else { return nil }
    let end = endedAt ?? Date()
    return end.timeIntervalSince(start)
  }

  var formattedDuration: String {
    guard let duration else { return "--" }
    let hours = Int(duration) / 3_600
    let minutes = (Int(duration) % 3_600) / 60
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  var formattedCost: String {
    if totalCostUSD > 0 {
      return String(format: "$%.2f", totalCostUSD)
    }
    return "--"
  }

  var lastToolDisplay: String? {
    guard let tool = lastTool, !tool.isEmpty else { return nil }
    return tool
  }

  // MARK: - Token Usage Computed Properties

  /// Total tokens used (input + output)
  var totalTokensUsed: Int {
    (inputTokens ?? 0) + (outputTokens ?? 0)
  }

  /// Percentage of context window used (0-100)
  var contextUsagePercent: Double {
    guard let contextWindow, contextWindow > 0 else { return 0 }
    return Double(totalTokensUsed) / Double(contextWindow) * 100
  }

  /// Whether token usage data is available
  var hasTokenUsage: Bool {
    (inputTokens ?? 0) > 0 || (outputTokens ?? 0) > 0 || (cachedTokens ?? 0) > 0
  }

  /// Formatted token count string
  var formattedTokenUsage: String {
    guard hasTokenUsage else { return "--" }
    let total = totalTokensUsed
    if total >= 1_000 {
      return String(format: "%.1fk", Double(total) / 1_000)
    }
    return "\(total)"
  }
}

// MARK: - String Extensions

extension String {
  /// Strips XML/HTML tags from a string
  /// e.g., "<bash-input>git checkout</bash-input>" → "git checkout"
  func strippingXMLTags() -> String {
    // Remove XML/HTML tags using regex
    guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else {
      return self
    }
    let range = NSRange(startIndex ..< endIndex, in: self)
    let stripped = regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "")

    // Clean up any extra whitespace
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Strips shell wrapper prefixes used by tooling so UI can show the actual command.
  /// e.g., "/bin/zsh -lc git status" -> "git status"
  func strippingShellWrapperPrefix() -> String {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }

    let tokens = ShellWrapperParser.tokenize(trimmed)
    guard !tokens.isEmpty else { return trimmed }
    guard let commandTokens = ShellWrapperParser.extractWrappedCommandTokens(from: tokens) else {
      return trimmed
    }

    let command = commandTokens
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return command.isEmpty ? trimmed : command
  }

  /// Build a display-friendly shell command from either a raw string or an argv-style array.
  static func shellCommandDisplay(from value: Any?) -> String? {
    guard let value else { return nil }

    if let command = value as? String {
      let cleaned = command.strippingShellWrapperPrefix()
      return cleaned.isEmpty ? nil : cleaned
    }

    if let commandParts = value as? [String] {
      return shellCommandDisplay(fromParts: commandParts)
    }

    if let commandParts = value as? [Any] {
      let parts = commandParts.compactMap { $0 as? String }
      guard parts.count == commandParts.count else { return nil }
      return shellCommandDisplay(fromParts: parts)
    }

    return nil
  }

  private static func shellCommandDisplay(fromParts parts: [String]) -> String? {
    guard !parts.isEmpty else { return nil }

    if let wrapped = ShellWrapperParser.extractWrappedCommand(from: parts) {
      return wrapped.isEmpty ? nil : wrapped
    }

    let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? nil : joined
  }
}

private enum ShellWrapperParser {
  struct Token {
    let value: String
  }

  private static let shellExecutables: Set<String> = [
    "sh", "bash", "zsh", "fish", "ksh", "dash", "csh", "tcsh",
    "nu", "xonsh", "pwsh", "pwsh.exe", "powershell", "powershell.exe",
    "cmd", "cmd.exe",
  ]

  static func extractWrappedCommandTokens(from tokens: [Token]) -> [String]? {
    guard let shellIndex = shellTokenIndex(in: tokens) else { return nil }
    let shell = executableName(from: tokens[shellIndex].value)

    if isCommandPromptExecutable(shell) {
      return commandTokensForCommandPrompt(from: tokens, shellIndex: shellIndex)
    }

    if isPowerShellExecutable(shell) {
      return commandTokensForPowerShell(from: tokens, shellIndex: shellIndex)
    }

    return commandTokensForPosixShell(from: tokens, shellIndex: shellIndex)
  }

  static func extractWrappedCommand(from parts: [String]) -> String? {
    let tokens = parts.map { Token(value: $0) }
    guard let commandTokens = extractWrappedCommandTokens(from: tokens) else { return nil }
    let command = commandTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return command.isEmpty ? nil : command
  }

  static func tokenize(_ command: String) -> [Token] {
    var tokens: [Token] = []
    var index = command.startIndex

    func advance(_ i: inout String.Index) {
      i = command.index(after: i)
    }

    while index < command.endIndex {
      while index < command.endIndex, command[index].isWhitespace {
        advance(&index)
      }
      guard index < command.endIndex else { break }

      var value = ""
      var consumed = false
      var inSingleQuotes = false
      var inDoubleQuotes = false

      while index < command.endIndex {
        let ch = command[index]

        if inSingleQuotes {
          consumed = true
          if ch == "'" {
            inSingleQuotes = false
            advance(&index)
            continue
          }
          value.append(ch)
          advance(&index)
          continue
        }

        if inDoubleQuotes {
          consumed = true
          if ch == "\"" {
            inDoubleQuotes = false
            advance(&index)
            continue
          }

          if ch == "\\" {
            let next = command.index(after: index)
            if next < command.endIndex {
              value.append(command[next])
              index = command.index(after: next)
            } else {
              index = next
            }
            continue
          }

          value.append(ch)
          advance(&index)
          continue
        }

        if ch.isWhitespace {
          break
        }

        consumed = true
        if ch == "'" {
          inSingleQuotes = true
          advance(&index)
          continue
        }
        if ch == "\"" {
          inDoubleQuotes = true
          advance(&index)
          continue
        }
        if ch == "\\" {
          let next = command.index(after: index)
          if next < command.endIndex {
            value.append(command[next])
            index = command.index(after: next)
          } else {
            index = next
          }
          continue
        }

        value.append(ch)
        advance(&index)
      }

      if consumed {
        tokens.append(Token(value: value))
      }
    }

    return tokens
  }

  private static func shellTokenIndex(in tokens: [Token]) -> Int? {
    guard !tokens.isEmpty else { return nil }
    var index = 0

    if executableName(from: tokens[0].value) == "env" {
      index = 1
      while index < tokens.count {
        let token = tokens[index].value
        let lowercased = token.lowercased()

        if lowercased == "--" {
          index += 1
          break
        }

        if lowercased.hasPrefix("-") || isEnvironmentAssignment(token) {
          index += 1
          continue
        }

        break
      }
    }

    guard index < tokens.count else { return nil }
    return isShellExecutable(tokens[index].value) ? index : nil
  }

  private static func commandTokensForPosixShell(from tokens: [Token], shellIndex: Int) -> [String]? {
    var index = shellIndex + 1
    while index < tokens.count {
      let option = tokens[index].value.lowercased()

      if option == "-c" || option == "--command" {
        return tokensAfter(index + 1, in: tokens)
      }

      if isCompactCommandSwitch(option) {
        return tokensAfter(index + 1, in: tokens)
      }

      if !option.hasPrefix("-") {
        return nil
      }

      index += 1
    }

    return nil
  }

  private static func commandTokensForPowerShell(from tokens: [Token], shellIndex: Int) -> [String]? {
    var index = shellIndex + 1
    while index < tokens.count {
      let option = tokens[index].value.lowercased()
      if option == "-command" || option == "--command" || option == "-c" || option == "-encodedcommand" || option ==
        "-ec"
      {
        return tokensAfter(index + 1, in: tokens)
      }

      if !option.hasPrefix("-") {
        return nil
      }

      index += 1
    }

    return nil
  }

  private static func commandTokensForCommandPrompt(from tokens: [Token], shellIndex: Int) -> [String]? {
    var index = shellIndex + 1
    while index < tokens.count {
      let option = tokens[index].value.lowercased()

      if option == "/c" || option == "/k" {
        return tokensAfter(index + 1, in: tokens)
      }

      if option.hasPrefix("/c"), option.count > 2 {
        let remainder = String(tokens[index].value.dropFirst(2))
        var commandTokens: [String] = []
        if !remainder.isEmpty {
          commandTokens.append(remainder)
        }
        if index + 1 < tokens.count {
          commandTokens.append(contentsOf: tokens[(index + 1)...].map(\.value))
        }
        return commandTokens.isEmpty ? nil : commandTokens
      }

      if option.hasPrefix("/k"), option.count > 2 {
        let remainder = String(tokens[index].value.dropFirst(2))
        var commandTokens: [String] = []
        if !remainder.isEmpty {
          commandTokens.append(remainder)
        }
        if index + 1 < tokens.count {
          commandTokens.append(contentsOf: tokens[(index + 1)...].map(\.value))
        }
        return commandTokens.isEmpty ? nil : commandTokens
      }

      if !option.hasPrefix("/") {
        return nil
      }

      index += 1
    }

    return nil
  }

  private static func tokensAfter(_ index: Int, in tokens: [Token]) -> [String]? {
    guard index < tokens.count else { return nil }
    return tokens[index...].map(\.value)
  }

  private static func isCompactCommandSwitch(_ option: String) -> Bool {
    guard option.hasPrefix("-"), option.count > 2 else { return false }
    let flags = option.dropFirst()
    guard flags.contains("c") else { return false }
    return flags.allSatisfy { $0 == "c" || $0 == "i" || $0 == "l" }
  }

  private static func isPowerShellExecutable(_ shell: String) -> Bool {
    shell == "pwsh" || shell == "pwsh.exe" || shell == "powershell" || shell == "powershell.exe"
  }

  private static func isCommandPromptExecutable(_ shell: String) -> Bool {
    shell == "cmd" || shell == "cmd.exe"
  }

  private static func isShellExecutable(_ token: String) -> Bool {
    shellExecutables.contains(executableName(from: token))
  }

  private static func executableName(from token: String) -> String {
    token
      .split(whereSeparator: { $0 == "/" || $0 == "\\" })
      .last
      .map { String($0).lowercased() } ?? token.lowercased()
  }

  private static func isEnvironmentAssignment(_ token: String) -> Bool {
    guard let separatorIndex = token.firstIndex(of: "="), separatorIndex != token.startIndex else {
      return false
    }

    let name = token[..<separatorIndex]
    guard let first = name.first, first == "_" || first.isLetter else {
      return false
    }

    return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }
}
