//
//  UserBashParsing.swift
//  OrbitDock
//
//  Pure parsing helpers for user-authored bash, slash command, and shell-context cards.
//

import Foundation

func extractTag(_ tag: String, from content: String) -> String {
  let openTag = "<\(tag)>"
  let closeTag = "</\(tag)>"

  guard let startRange = content.range(of: openTag),
        let endRange = content.range(of: closeTag, range: startRange.upperBound ..< content.endIndex)
  else {
    return ""
  }

  return String(content[startRange.upperBound ..< endRange.lowerBound])
}

struct ParsedSystemContext {
  enum ContextKind {
    case agentsMd(directory: String)
    case skill(name: String, path: String)
    case legacyInstructions
    case systemReminder
  }

  let kind: ContextKind
  let body: String

  var label: String {
    switch kind {
      case let .agentsMd(dir):
        let short = (dir as NSString).lastPathComponent
        return "AGENTS.md · \(short)"
      case let .skill(name, _):
        return "Skill · \(name)"
      case .legacyInstructions:
        return "Instructions"
      case .systemReminder:
        return "System"
    }
  }

  var icon: String {
    switch kind {
      case .agentsMd: "doc.text"
      case .skill: "wand.and.stars"
      case .legacyInstructions: "gearshape"
      case .systemReminder: "info.circle"
    }
  }

  static func parse(from content: String) -> ParsedSystemContext? {
    if content.hasPrefix("# AGENTS.md instructions for ") {
      let firstLine = content.components(separatedBy: "\n").first ?? ""
      let directory = String(firstLine.dropFirst("# AGENTS.md instructions for ".count))
      let body = extractTag("INSTRUCTIONS", from: content)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return ParsedSystemContext(
        kind: .agentsMd(directory: directory),
        body: body.isEmpty ? content : body
      )
    }

    if content.hasPrefix("<skill") {
      let name = extractTag("name", from: content)
      let path = extractTag("path", from: content)
      let body = content
        .replacingOccurrences(of: "<skill>", with: "")
        .replacingOccurrences(of: "</skill>", with: "")
        .replacingOccurrences(of: "<name>\(name)</name>", with: "")
        .replacingOccurrences(of: "<path>\(path)</path>", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return ParsedSystemContext(
        kind: .skill(name: name.isEmpty ? "unknown" : name, path: path),
        body: body
      )
    }

    if content.hasPrefix("<user_instructions>") {
      let body = extractTag("user_instructions", from: content)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return ParsedSystemContext(
        kind: .legacyInstructions,
        body: body.isEmpty ? content : body
      )
    }

    if content.hasPrefix("<system-reminder>") {
      let body = extractTag("system-reminder", from: content)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return ParsedSystemContext(
        kind: .systemReminder,
        body: body.isEmpty ? content : body
      )
    }

    return nil
  }
}

struct ParsedSystemCaveat {
  let message: String

  static func parse(from content: String) -> ParsedSystemCaveat? {
    guard content.contains("<local-command-caveat>") else { return nil }

    let message = extractTag("local-command-caveat", from: content)
    guard !message.isEmpty else { return nil }

    return ParsedSystemCaveat(message: message)
  }
}

struct ParsedBashContent {
  let input: String
  let stdout: String
  let stderr: String

  var hasOutput: Bool {
    !stdout.isEmpty || !stderr.isEmpty
  }

  var hasError: Bool {
    !stderr.isEmpty
  }

  var hasInput: Bool {
    !input.isEmpty
  }

  static func parse(from content: String) -> ParsedBashContent? {
    let hasBashInput = content.contains("<bash-input>")
    let hasBashStdout = content.contains("<bash-stdout>")
    let hasBashStderr = content.contains("<bash-stderr>")

    guard hasBashInput || hasBashStdout || hasBashStderr else { return nil }

    let input = extractTag("bash-input", from: content).strippingShellWrapperPrefix()
    let stdout = extractTag("bash-stdout", from: content)
    let stderr = extractTag("bash-stderr", from: content)

    guard !input.isEmpty || !stdout.isEmpty || !stderr.isEmpty else { return nil }

    return ParsedBashContent(input: input, stdout: stdout, stderr: stderr)
  }
}

struct ParsedSlashCommand {
  let name: String
  let message: String
  let args: String
  let stdout: String

  var hasArgs: Bool {
    !args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var hasOutput: Bool {
    !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func parse(from content: String) -> ParsedSlashCommand? {
    let hasCommandName = content.contains("<command-name>")
    let hasLocalStdout = content.contains("<local-command-stdout>")

    guard hasCommandName || hasLocalStdout else { return nil }

    let name = extractTag("command-name", from: content)
    let message = extractTag("command-message", from: content)
    let args = extractTag("command-args", from: content)
    let stdout = extractTag("local-command-stdout", from: content)

    guard !name.isEmpty || !stdout.isEmpty else { return nil }

    return ParsedSlashCommand(name: name, message: message, args: args, stdout: stdout)
  }
}

struct ParsedShellContext {
  struct CommandBlock: Identifiable {
    let id = UUID()
    let command: String
    let output: String
    let exitCode: Int?

    var hasError: Bool {
      guard let code = exitCode else { return false }
      return code != 0
    }
  }

  let commands: [CommandBlock]
  let userPrompt: String

  var commandCount: Int {
    commands.count
  }

  static func parse(from content: String) -> ParsedShellContext? {
    guard content.contains("<shell-context>") else { return nil }

    let contextBody = extractTag("shell-context", from: content)
    guard !contextBody.isEmpty else { return nil }

    let userPrompt: String
    if let closeRange = content.range(of: "</shell-context>") {
      userPrompt = String(content[closeRange.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      userPrompt = ""
    }

    let allLines = contextBody.components(separatedBy: "\n")
    var commands: [CommandBlock] = []
    var currentCommand: String?
    var currentOutputLines: [String] = []

    func flushBlock() {
      guard let cmd = currentCommand else { return }

      var exitCode: Int?
      var outputLines = currentOutputLines
      while outputLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        outputLines.removeLast()
      }
      if let lastLine = outputLines.last?.trimmingCharacters(in: .whitespaces),
         lastLine.hasPrefix("(exit "), lastLine.hasSuffix(")")
      {
        let codeStr = lastLine
          .replacingOccurrences(of: "(exit ", with: "")
          .replacingOccurrences(of: ")", with: "")
        exitCode = Int(codeStr)
        outputLines = Array(outputLines.dropLast())
      }

      let output = outputLines.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      commands.append(CommandBlock(
        command: cmd,
        output: output,
        exitCode: exitCode
      ))
    }

    for line in allLines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("$ ") {
        flushBlock()
        currentCommand = String(trimmed.dropFirst(2))
        currentOutputLines = []
      } else if trimmed == "$" {
        flushBlock()
        currentCommand = ""
        currentOutputLines = []
      } else if currentCommand != nil {
        currentOutputLines.append(line)
      }
    }

    flushBlock()

    guard !commands.isEmpty else { return nil }

    return ParsedShellContext(commands: commands, userPrompt: userPrompt)
  }
}
