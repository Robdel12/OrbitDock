import Foundation

enum TranscriptMessageToolKind: String, Sendable {
  case read
  case edit
  case write
  case bash
  case glob
  case grep
  case task
  case handoff
  case hook
  case webFetch
  case webSearch
  case unknown

  init(toolName: String?) {
    switch toolName?.lowercased() {
      case "read": self = .read
      case "edit": self = .edit
      case "write": self = .write
      case "bash": self = .bash
      case "glob": self = .glob
      case "grep": self = .grep
      case "task": self = .task
      case "handoff": self = .handoff
      case "hook": self = .hook
      case "webfetch": self = .webFetch
      case "websearch": self = .webSearch
      default: self = .unknown
    }
  }

  var iconName: String {
    switch self {
      case .read: return "doc.text"
      case .edit: return "pencil"
      case .write: return "square.and.pencil"
      case .bash: return "terminal"
      case .glob: return "folder.badge.gearshape"
      case .grep: return "magnifyingglass"
      case .task: return "person.2"
      case .handoff: return "arrow.triangle.branch"
      case .hook: return "bolt.badge.clock"
      case .webFetch: return "globe"
      case .webSearch: return "magnifyingglass.circle"
      case .unknown: return "gearshape"
    }
  }

  var colorName: String {
    switch self {
      case .read: return "blue"
      case .edit, .write: return "orange"
      case .bash: return "green"
      case .glob, .grep: return "purple"
      case .task: return "indigo"
      case .handoff: return "blue"
      case .hook: return "teal"
      case .webFetch, .webSearch: return "teal"
      case .unknown: return "secondary"
    }
  }
}

extension TranscriptMessage {
  var toolKind: TranscriptMessageToolKind {
    TranscriptMessageToolKind(toolName: toolName)
  }

  var toolIcon: String {
    toolKind.iconName
  }

  var toolColor: String {
    toolKind.colorName
  }

  /// File path extracted from toolDisplay subtitle (server now provides this).
  var filePath: String? {
    toolDisplay?.subtitle
  }

  /// Bash command extracted from toolDisplay summary.
  var bashCommand: String? {
    guard isBashLikeCommand else { return nil }
    return toolDisplay?.summary ?? String.shellCommandDisplay(from: content) ?? content
  }

  /// Bash metadata — no longer available without raw tool input. Returns nil.
  var bashMetadataInput: String? {
    nil
  }

  /// Edit old string — no longer available without raw tool input. Returns nil.
  var editOldString: String? {
    nil
  }

  /// Edit new string — no longer available without raw tool input. Returns nil.
  var editNewString: String? {
    nil
  }

  /// Write content — no longer available without raw tool input. Returns nil.
  var writeContent: String? {
    nil
  }

  /// Unified diff — use toolDisplay.diffDisplay instead.
  var unifiedDiff: String? {
    toolDisplay?.diffDisplay
  }

  var hasUnifiedDiff: Bool {
    if let unifiedDiff, !unifiedDiff.isEmpty {
      return true
    }
    return false
  }

  /// Glob pattern — extracted from toolDisplay summary.
  var globPattern: String? {
    guard toolKind == .glob else { return nil }
    return toolDisplay?.summary
  }

  /// Grep pattern — extracted from toolDisplay summary.
  var grepPattern: String? {
    guard toolKind == .grep else { return nil }
    return toolDisplay?.summary
  }

  /// Task prompt — extracted from toolDisplay inputDisplay.
  var taskPrompt: String? {
    guard toolKind == .task else { return nil }
    return toolDisplay?.inputDisplay
  }

  /// Task description — extracted from toolDisplay subtitle.
  var taskDescription: String? {
    guard toolKind == .task else { return nil }
    return toolDisplay?.subtitle
  }

  var fullFormattedToolInput: String? {
    toolDisplay?.inputDisplay
  }

  var toolInputRenderSignature: String? {
    toolDisplay?.inputDisplay
  }

  var formattedToolInput: String? {
    toolDisplay?.inputDisplay
  }

  var toolOutputPreview: String? {
    toolDisplay?.outputPreview
  }

  var sanitizedToolOutput: String? {
    toolDisplay?.outputDisplay ?? toolDisplay?.outputPreview
  }

  var formattedDuration: String? {
    guard let duration = toolDuration, duration > 0 else { return nil }

    if duration < 1.0 {
      let ms = Int(duration * 1_000)
      return "\(ms)ms"
    } else if duration < 60 {
      return String(format: "%.1fs", duration)
    } else {
      let minutes = Int(duration / 60)
      let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
      return "\(minutes)m \(seconds)s"
    }
  }

  var outputLineCount: Int? {
    guard let output = toolDisplay?.outputDisplay ?? toolDisplay?.outputPreview, !output.isEmpty else { return nil }
    return output.components(separatedBy: "\n").count
  }

  var globMatchCount: Int? {
    guard toolKind == .glob, let output = toolDisplay?.outputDisplay ?? toolDisplay?.outputPreview else { return nil }
    return output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
  }

  var grepMatchCount: Int? {
    guard toolKind == .grep, let output = toolDisplay?.outputDisplay ?? toolDisplay?.outputPreview else { return nil }
    return output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
  }

  var bashHasError: Bool {
    guard isBashLikeCommand else { return false }
    if isError { return true }
    guard let output = toolDisplay?.outputDisplay ?? toolDisplay?.outputPreview else { return false }
    let lowerOutput = output.lowercased()
    return lowerOutput.contains("error:")
      || lowerOutput.contains("error[")
      || lowerOutput.contains("command not found")
      || lowerOutput.contains("permission denied")
      || lowerOutput.contains("no such file or directory")
      || lowerOutput.contains("fatal:")
      || lowerOutput.contains("failed to")
  }

  private func truncateToolText(_ value: String, maxLength: Int?) -> String {
    guard let maxLength else { return value }
    if value.count > maxLength {
      return String(value.prefix(maxLength)) + "..."
    }
    return value
  }
}
