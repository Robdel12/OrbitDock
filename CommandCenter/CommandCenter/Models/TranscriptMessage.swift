//
//  TranscriptMessage.swift
//  OrbitDock
//

import Foundation

// MARK: - Message Image

struct MessageImage: Identifiable, Hashable {
  let id: String
  let data: Data
  let mimeType: String

  init(data: Data, mimeType: String) {
    self.id = UUID().uuidString
    self.data = data
    self.mimeType = mimeType
  }
}

// MARK: - Transcript Message

struct TranscriptMessage: Identifiable, Hashable {
  let id: String
  let type: MessageType
  let content: String
  let timestamp: Date
  let toolName: String?
  let toolInput: [String: Any]?
  var toolOutput: String? // Result of tool execution (var for incremental updates)
  let toolDuration: TimeInterval? // How long the tool took
  let inputTokens: Int?
  let outputTokens: Int?
  var isInProgress: Bool = false // Tool is currently running
  var images: [MessageImage] = [] // Support multiple images
  var thinking: String? // Claude's thinking trace (collapsed by default)

  /// Legacy single image support (for backwards compatibility)
  var imageData: Data? {
    images.first?.data
  }

  var imageMimeType: String? {
    images.first?.mimeType
  }

  enum MessageType: String {
    case user
    case assistant
    case tool // Tool call from assistant
    case toolResult // Result of tool call
    case thinking // Claude's internal reasoning
    case system
  }

  var isUser: Bool {
    type == .user
  }

  var isAssistant: Bool {
    type == .assistant
  }

  var isTool: Bool {
    type == .tool
  }

  var isThinking: Bool {
    type == .thinking
  }

  /// Hashable conformance - exclude toolInput since [String: Any] isn't Hashable
  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(type)
    hasher.combine(content)
    hasher.combine(timestamp)
    hasher.combine(toolName)
    hasher.combine(images)
  }

  var hasImage: Bool {
    !images.isEmpty
  }

  var hasThinking: Bool {
    thinking != nil && !thinking!.isEmpty
  }

  static func == (lhs: TranscriptMessage, rhs: TranscriptMessage) -> Bool {
    lhs.id == rhs.id
  }

  var preview: String {
    let cleaned = content
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.count > 200 {
      return String(cleaned.prefix(200)) + "..."
    }
    return cleaned
  }

  /// Helper for tool display
  var toolIcon: String {
    guard let tool = toolName?.lowercased() else { return "gearshape" }
    switch tool {
      case "read": return "doc.text"
      case "edit": return "pencil"
      case "write": return "square.and.pencil"
      case "bash": return "terminal"
      case "glob": return "folder.badge.gearshape"
      case "grep": return "magnifyingglass"
      case "task": return "person.2"
      case "webfetch": return "globe"
      case "websearch": return "magnifyingglass.circle"
      default: return "gearshape"
    }
  }

  var toolColor: String {
    guard let tool = toolName?.lowercased() else { return "secondary" }
    switch tool {
      case "read": return "blue"
      case "edit", "write": return "orange"
      case "bash": return "green"
      case "glob", "grep": return "purple"
      case "task": return "indigo"
      case "webfetch", "websearch": return "teal"
      default: return "secondary"
    }
  }

  /// Extract file path from tool input if present
  var filePath: String? {
    guard let input = toolInput else { return nil }
    return input["file_path"] as? String ?? input["path"] as? String
  }

  /// Extract command from Bash tool
  var bashCommand: String? {
    guard toolName?.lowercased() == "bash", let input = toolInput else { return nil }
    return input["command"] as? String
  }

  /// Extract edit details
  var editOldString: String? {
    guard toolName?.lowercased() == "edit", let input = toolInput else { return nil }
    return input["old_string"] as? String
  }

  var editNewString: String? {
    guard toolName?.lowercased() == "edit", let input = toolInput else { return nil }
    return input["new_string"] as? String
  }

  /// Extract write content
  var writeContent: String? {
    guard toolName?.lowercased() == "write", let input = toolInput else { return nil }
    return input["content"] as? String
  }

  /// Extract unified diff (from Codex fileChange)
  var unifiedDiff: String? {
    guard let input = toolInput else { return nil }
    return input["unified_diff"] as? String
  }

  /// Check if this is a Codex file change with diff
  var hasUnifiedDiff: Bool {
    unifiedDiff != nil && !(unifiedDiff?.isEmpty ?? true)
  }

  /// Extract glob pattern
  var globPattern: String? {
    guard toolName?.lowercased() == "glob", let input = toolInput else { return nil }
    return input["pattern"] as? String
  }

  /// Extract grep pattern
  var grepPattern: String? {
    guard toolName?.lowercased() == "grep", let input = toolInput else { return nil }
    return input["pattern"] as? String
  }

  /// Task/subagent details
  var taskPrompt: String? {
    guard toolName?.lowercased() == "task", let input = toolInput else { return nil }
    return input["prompt"] as? String
  }

  var taskDescription: String? {
    guard toolName?.lowercased() == "task", let input = toolInput else { return nil }
    return input["description"] as? String
  }

  /// Format tool input as displayable text
  var formattedToolInput: String? {
    guard let input = toolInput else { return nil }

    switch toolName?.lowercased() {
      case "bash":
        return bashCommand
      case "read":
        return filePath
      case "edit":
        if let old = editOldString, let new = editNewString {
          let oldPreview = old.count > 200 ? String(old.prefix(200)) + "..." : old
          let newPreview = new.count > 200 ? String(new.prefix(200)) + "..." : new
          return "- \(oldPreview)\n+ \(newPreview)"
        }
        return filePath
      case "write":
        if let content = writeContent {
          return content.count > 500 ? String(content.prefix(500)) + "..." : content
        }
        return filePath
      case "glob":
        return globPattern
      case "grep":
        return grepPattern
      case "task":
        return taskDescription ?? taskPrompt
      default:
        // Generic JSON display for unknown tools
        if let data = try? JSONSerialization.data(withJSONObject: input, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8)
        {
          return str.count > 500 ? String(str.prefix(500)) + "..." : str
        }
        return nil
    }
  }

  /// Truncated output for preview
  var toolOutputPreview: String? {
    guard let output = toolOutput else { return nil }
    if output.count > 300 {
      return String(output.prefix(300)) + "..."
    }
    return output
  }

  /// Tool output with ANSI escape codes stripped for clean display
  var sanitizedToolOutput: String? {
    guard let output = toolOutput else { return nil }
    // Match ANSI escape sequences: ESC[ followed by params and command letter
    let pattern = "\u{1b}\\[[0-9;?]*[a-zA-Z]"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return output
    }
    let range = NSRange(output.startIndex..., in: output)
    return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
  }

  // MARK: - Duration & Statistics

  /// Format duration for display (e.g., "245ms", "1.2s", "2m 15s")
  var formattedDuration: String? {
    guard let duration = toolDuration, duration > 0 else { return nil }

    if duration < 1.0 {
      // Under 1 second: show milliseconds
      let ms = Int(duration * 1_000)
      return "\(ms)ms"
    } else if duration < 60 {
      // Under 1 minute: show seconds with 1 decimal
      return String(format: "%.1fs", duration)
    } else {
      // Over 1 minute: show minutes and seconds
      let minutes = Int(duration / 60)
      let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
      return "\(minutes)m \(seconds)s"
    }
  }

  /// Output statistics
  var outputLineCount: Int? {
    guard let output = toolOutput, !output.isEmpty else { return nil }
    return output.components(separatedBy: "\n").count
  }

  /// For Glob: count matched files
  var globMatchCount: Int? {
    guard toolName?.lowercased() == "glob", let output = toolOutput else { return nil }
    return output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
  }

  /// For Grep: count matches
  var grepMatchCount: Int? {
    guard toolName?.lowercased() == "grep", let output = toolOutput else { return nil }
    return output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
  }

  /// Detect if bash command likely errored
  var bashHasError: Bool {
    guard toolName?.lowercased() == "bash", let output = toolOutput else { return false }
    let lowerOutput = output.lowercased()
    return lowerOutput.contains("error:") ||
      lowerOutput.contains("error[") ||
      lowerOutput.contains("command not found") ||
      lowerOutput.contains("permission denied") ||
      lowerOutput.contains("no such file or directory") ||
      lowerOutput.contains("fatal:") ||
      lowerOutput.contains("failed to")
  }
}
