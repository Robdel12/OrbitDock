import Foundation

extension TranscriptMessage {
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

  var filePath: String? {
    guard let input = toolInput else { return nil }
    return input["file_path"] as? String ?? input["path"] as? String
  }

  var bashCommand: String? {
    guard isBashLikeCommand else { return nil }
    if let input = toolInput {
      return String.shellCommandDisplay(from: input["command"])
        ?? String.shellCommandDisplay(from: input["cmd"])
        ?? String.shellCommandDisplay(from: content)
        ?? content
    }
    return String.shellCommandDisplay(from: content) ?? content
  }

  var bashMetadataInput: String? {
    guard isBashLikeCommand else { return nil }
    guard var input = toolInput else {
      return trimmedRawToolInput
    }

    input.removeValue(forKey: "command")
    input.removeValue(forKey: "cmd")
    if input.isEmpty {
      return nil
    }

    guard JSONSerialization.isValidJSONObject(input),
          let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted]),
          let text = String(data: data, encoding: .utf8)
    else {
      return trimmedRawToolInput
    }
    return text
  }

  var editOldString: String? {
    guard toolName?.lowercased() == "edit", let input = toolInput else { return nil }
    return input["old_string"] as? String
  }

  var editNewString: String? {
    guard toolName?.lowercased() == "edit", let input = toolInput else { return nil }
    return input["new_string"] as? String
  }

  var writeContent: String? {
    guard toolName?.lowercased() == "write", let input = toolInput else { return nil }
    return input["content"] as? String
  }

  var unifiedDiff: String? {
    guard let input = toolInput else { return nil }
    return input["unified_diff"] as? String
  }

  var hasUnifiedDiff: Bool {
    if let unifiedDiff, !unifiedDiff.isEmpty {
      return true
    }
    return false
  }

  var globPattern: String? {
    guard toolName?.lowercased() == "glob", let input = toolInput else { return nil }
    return input["pattern"] as? String
  }

  var grepPattern: String? {
    guard toolName?.lowercased() == "grep", let input = toolInput else { return nil }
    return input["pattern"] as? String
  }

  var taskPrompt: String? {
    guard toolName?.lowercased() == "task", let input = toolInput else { return nil }
    return input["prompt"] as? String
  }

  var taskDescription: String? {
    guard toolName?.lowercased() == "task", let input = toolInput else { return nil }
    return input["description"] as? String
  }

  var fullFormattedToolInput: String? {
    formatToolInput(maxLength: nil)
  }

  var toolInputRenderSignature: String? {
    if let raw = trimmedRawToolInput {
      return raw
    }

    guard let input = toolInput,
          JSONSerialization.isValidJSONObject(input),
          let data = try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys),
          let canonical = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return canonical
  }

  var formattedToolInput: String? {
    formatToolInput(maxLength: 500)
  }

  var toolOutputPreview: String? {
    guard let output = toolOutput else { return nil }
    if output.count > 300 {
      return String(output.prefix(300)) + "..."
    }
    return output
  }

  var sanitizedToolOutput: String? {
    guard let output = toolOutput else { return nil }
    let pattern = "\u{1b}\\[[0-9;?]*[a-zA-Z]"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return output
    }
    let range = NSRange(output.startIndex..., in: output)
    return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
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
    guard let output = toolOutput, !output.isEmpty else { return nil }
    return output.components(separatedBy: "\n").count
  }

  var globMatchCount: Int? {
    guard toolName?.lowercased() == "glob", let output = toolOutput else { return nil }
    return output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
  }

  var grepMatchCount: Int? {
    guard toolName?.lowercased() == "grep", let output = toolOutput else { return nil }
    return output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
  }

  var bashHasError: Bool {
    guard isBashLikeCommand, let output = toolOutput else { return false }
    let lowerOutput = output.lowercased()
    return lowerOutput.contains("error:")
      || lowerOutput.contains("error[")
      || lowerOutput.contains("command not found")
      || lowerOutput.contains("permission denied")
      || lowerOutput.contains("no such file or directory")
      || lowerOutput.contains("fatal:")
      || lowerOutput.contains("failed to")
  }

  private var trimmedRawToolInput: String? {
    guard let raw = rawToolInput?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    return raw
  }

  private func truncateToolText(_ value: String, maxLength: Int?) -> String {
    guard let maxLength else { return value }
    if value.count > maxLength {
      return String(value.prefix(maxLength)) + "..."
    }
    return value
  }

  private func formatToolInput(maxLength: Int?) -> String? {
    guard let input = toolInput else {
      guard let raw = trimmedRawToolInput else { return nil }
      return truncateToolText(raw, maxLength: maxLength)
    }

    switch toolName?.lowercased() {
      case "bash":
        guard let command = bashCommand else { return nil }
        return truncateToolText(command, maxLength: maxLength)
      case "read":
        guard let path = filePath else { return nil }
        return truncateToolText(path, maxLength: maxLength)
      case "edit":
        if let old = editOldString, let new = editNewString {
          let oldPreview = old.count > 200 ? String(old.prefix(200)) + "..." : old
          let newPreview = new.count > 200 ? String(new.prefix(200)) + "..." : new
          return "- \(oldPreview)\n+ \(newPreview)"
        }
        if let path = filePath {
          return truncateToolText(path, maxLength: maxLength)
        }
        return nil
      case "write":
        if let content = writeContent {
          return truncateToolText(content, maxLength: maxLength)
        }
        if let path = filePath {
          return truncateToolText(path, maxLength: maxLength)
        }
        return nil
      case "glob":
        guard let pattern = globPattern else { return nil }
        return truncateToolText(pattern, maxLength: maxLength)
      case "grep":
        guard let pattern = grepPattern else { return nil }
        return truncateToolText(pattern, maxLength: maxLength)
      case "task":
        if let description = taskDescription {
          return truncateToolText(description, maxLength: maxLength)
        }
        if let prompt = taskPrompt {
          return truncateToolText(prompt, maxLength: maxLength)
        }
        return nil
      default:
        if let data = try? JSONSerialization.data(withJSONObject: input, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8)
        {
          return truncateToolText(str, maxLength: maxLength)
        }
        return nil
    }
  }
}
