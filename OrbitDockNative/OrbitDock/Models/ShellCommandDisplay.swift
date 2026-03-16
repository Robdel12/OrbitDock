import Foundation

extension String {
  private nonisolated static let xmlTagRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: "<[^>]+>",
    options: []
  )

  /// Strips XML/HTML tags from a string.
  nonisolated func strippingXMLTags() -> String {
    guard let regex = Self.xmlTagRegex else {
      return self
    }
    let range = NSRange(startIndex ..< endIndex, in: self)
    let stripped = regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "")
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Strips wrapper shells so UI can show the actual command.
  nonisolated func strippingShellWrapperPrefix() -> String {
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

  /// Builds a display-friendly shell command from either a raw string or an argv-style array.
  nonisolated static func shellCommandDisplay(from value: Any?) -> String? {
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

  private nonisolated static func shellCommandDisplay(fromParts parts: [String]) -> String? {
    guard !parts.isEmpty else { return nil }

    if let wrapped = ShellWrapperParser.extractWrappedCommand(from: parts) {
      return wrapped.isEmpty ? nil : wrapped
    }

    let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? nil : joined
  }
}

private nonisolated enum ShellWrapperParser {
  struct Token {
    let value: String
  }

  private static let shellExecutables: Set<String> = [
    "sh", "bash", "zsh", "fish", "ksh", "dash", "csh", "tcsh",
    "nu", "xonsh", "pwsh", "pwsh.exe", "powershell", "powershell.exe",
    "cmd", "cmd.exe",
  ]

  nonisolated static func extractWrappedCommandTokens(from tokens: [Token]) -> [String]? {
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

  nonisolated static func extractWrappedCommand(from parts: [String]) -> String? {
    let tokens = parts.map { Token(value: $0) }
    guard let commandTokens = extractWrappedCommandTokens(from: tokens) else { return nil }
    let command = commandTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return command.isEmpty ? nil : command
  }

  nonisolated static func tokenize(_ command: String) -> [Token] {
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
