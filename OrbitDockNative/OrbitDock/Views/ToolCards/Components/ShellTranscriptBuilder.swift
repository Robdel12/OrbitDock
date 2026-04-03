import Foundation

/// Builds a shell-like transcript snapshot for non-interactive terminal rendering.
///
/// The transcript includes:
/// 1) a prompt + command line
/// 2) captured command output (if any)
/// 3) a trailing prompt so the snapshot ends like a real shell view
enum ShellTranscriptBuilder {
  private static let ansiReset = "\u{001B}[0m"
  private static let ansiPromptGlyph = "\u{001B}[38;5;84m"
  private static let ansiPromptPath = "\u{001B}[38;5;81m"
  private static let commandSoftWrapThreshold = 120

  static func makeSnapshot(
    command: String?,
    output: String?,
    cwd: String?
  ) -> String? {
    let normalizedCommand = normalizeCommand(command)
    let normalizedOutput = normalizeOutput(output)

    guard normalizedCommand != nil || normalizedOutput != nil else {
      return nil
    }

    let prompt = promptPrefix(cwd: cwd)
    var chunks: [String] = []

    if let normalizedCommand {
      let wrappedCommandLines = wrapCommandForDisplay(normalizedCommand)
      if let firstLine = wrappedCommandLines.first {
        chunks.append(prompt + firstLine)
      }
      if wrappedCommandLines.count > 1 {
        for continuation in wrappedCommandLines.dropFirst() {
          chunks.append("  " + continuation)
        }
      }
    }

    if let normalizedOutput {
      chunks.append(normalizedOutput)
    }

    if normalizedCommand != nil {
      chunks.append(prompt)
    }

    return chunks.joined(separator: "\n")
  }

  private static func normalizeCommand(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    return trimmed
      .components(separatedBy: .newlines)
      .joined(separator: " ")
  }

  private static func normalizeOutput(_ raw: String?) -> String? {
    guard let raw else { return nil }
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
  }

  /// Soft-wrap long commands for readability in transcript snapshots.
  /// Output payload lines are never rewritten; this applies only to the echoed command.
  private static func wrapCommandForDisplay(_ command: String) -> [String] {
    guard command.count > commandSoftWrapThreshold else {
      return [command]
    }

    let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard words.count > 1 else {
      return [command]
    }

    var lines: [String] = []
    var current = ""

    for word in words {
      if current.isEmpty {
        current = word
        continue
      }

      let candidate = current + " " + word
      if candidate.count <= commandSoftWrapThreshold {
        current = candidate
      } else {
        lines.append(current)
        current = word
      }
    }

    if !current.isEmpty {
      lines.append(current)
    }

    return lines.isEmpty ? [command] : lines
  }

  private static func promptPrefix(cwd: String?) -> String {
    let path = normalizePromptPath(cwd)
    return "\(ansiPromptGlyph)➜\(ansiReset) \(ansiPromptPath)\(path)\(ansiReset) $ "
  }

  private static func normalizePromptPath(_ cwd: String?) -> String {
    guard let cwd else { return "~" }
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "~" }

    let home = NSHomeDirectory()
    let withHomeTilde: String
    if trimmed.hasPrefix(home) {
      let suffix = String(trimmed.dropFirst(home.count))
      withHomeTilde = "~" + suffix
    } else {
      withHomeTilde = trimmed
    }

    return ToolCardStyle.shortenPath(withHomeTilde)
  }
}
