//
//  LinkDetector.swift
//  OrbitDockCore
//
//  Detects GitHub PR/issue URLs from CLI output (gh pr create, gh issue create)
//

import Foundation

public struct DetectedLink {
  public let url: String
  public let type: LinkType
  public let number: Int
  public let repo: String // "owner/repo"
  public let title: String?

  public enum LinkType: String {
    case pullRequest = "github_pr"
    case issue = "github_issue"
  }

  /// Format for inbox display
  public var displayContent: String {
    switch type {
      case .pullRequest:
        if let title {
          return "PR #\(number): \(title)\n\(url)"
        }
        return "PR #\(number) - \(repo)\n\(url)"
      case .issue:
        if let title {
          return "Issue #\(number): \(title)\n\(url)"
        }
        return "Issue #\(number) - \(repo)\n\(url)"
    }
  }
}

public enum LinkDetector {

  /// Detect GitHub PR/issue URLs from command output
  /// Works with `gh pr create` and `gh issue create` output
  /// - Parameters:
  ///   - output: The stdout from the command
  ///   - command: The original command (to extract --title)
  public static func detectLinks(from output: String, command: String? = nil) -> [DetectedLink] {
    var links: [DetectedLink] = []

    // Extract title from command's --title flag
    let title = command.flatMap { extractTitleFromCommand($0) }

    // Pattern: https://github.com/owner/repo/pull/123
    let prPattern = #"https://github\.com/([^/]+/[^/]+)/pull/(\d+)"#
    if let prRegex = try? NSRegularExpression(pattern: prPattern, options: []) {
      let range = NSRange(output.startIndex..., in: output)
      for match in prRegex.matches(in: output, range: range) {
        if let repoRange = Range(match.range(at: 1), in: output),
           let numberRange = Range(match.range(at: 2), in: output),
           let number = Int(output[numberRange])
        {
          let repo = String(output[repoRange])
          let url = String(output[Range(match.range, in: output)!])

          links.append(DetectedLink(
            url: url,
            type: .pullRequest,
            number: number,
            repo: repo,
            title: title
          ))
        }
      }
    }

    // Pattern: https://github.com/owner/repo/issues/123
    let issuePattern = #"https://github\.com/([^/]+/[^/]+)/issues/(\d+)"#
    if let issueRegex = try? NSRegularExpression(pattern: issuePattern, options: []) {
      let range = NSRange(output.startIndex..., in: output)
      for match in issueRegex.matches(in: output, range: range) {
        if let repoRange = Range(match.range(at: 1), in: output),
           let numberRange = Range(match.range(at: 2), in: output),
           let number = Int(output[numberRange])
        {
          let repo = String(output[repoRange])
          let url = String(output[Range(match.range, in: output)!])

          links.append(DetectedLink(
            url: url,
            type: .issue,
            number: number,
            repo: repo,
            title: title
          ))
        }
      }
    }

    return links
  }

  /// Check if command looks like a gh pr/issue create command
  public static func isGitHubCreateCommand(_ command: String) -> Bool {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("gh pr create") || trimmed.hasPrefix("gh issue create")
  }

  /// Extract title from --title "..." or -t "..." flag in command
  private static func extractTitleFromCommand(_ command: String) -> String? {
    // Match --title "..." or --title '...' or -t "..." or -t '...'
    // Also handle --title="...." format
    let patterns = [
      #"--title[=\s]+[\"']([^\"']+)[\"']"#,
      #"-t\s+[\"']([^\"']+)[\"']"#,
      #"--title[=\s]+(\S+)"#, // unquoted
    ]

    for pattern in patterns {
      if let regex = try? NSRegularExpression(pattern: pattern, options: []),
         let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
         let titleRange = Range(match.range(at: 1), in: command)
      {
        return String(command[titleRange])
      }
    }

    return nil
  }
}
