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
    public let repo: String  // "owner/repo"
    public let title: String?

    public enum LinkType: String {
        case pullRequest = "github_pr"
        case issue = "github_issue"
    }

    /// Format for inbox display
    public var displayContent: String {
        switch type {
        case .pullRequest:
            if let title = title {
                return "PR #\(number): \(title)\n\(url)"
            }
            return "PR #\(number) - \(repo)\n\(url)"
        case .issue:
            if let title = title {
                return "Issue #\(number): \(title)\n\(url)"
            }
            return "Issue #\(number) - \(repo)\n\(url)"
        }
    }
}

public struct LinkDetector {

    /// Detect GitHub PR/issue URLs from command output
    /// Works with `gh pr create` and `gh issue create` output
    public static func detectLinks(from output: String) -> [DetectedLink] {
        var links: [DetectedLink] = []

        // Pattern: https://github.com/owner/repo/pull/123
        let prPattern = #"https://github\.com/([^/]+/[^/]+)/pull/(\d+)"#
        if let prRegex = try? NSRegularExpression(pattern: prPattern, options: []) {
            let range = NSRange(output.startIndex..., in: output)
            for match in prRegex.matches(in: output, range: range) {
                if let repoRange = Range(match.range(at: 1), in: output),
                   let numberRange = Range(match.range(at: 2), in: output),
                   let number = Int(output[numberRange]) {
                    let repo = String(output[repoRange])
                    let url = String(output[Range(match.range, in: output)!])

                    // Try to extract title from gh pr create output
                    // Format: "Creating pull request for branch...\n\nhttps://..."
                    let title = extractPRTitle(from: output)

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
                   let number = Int(output[numberRange]) {
                    let repo = String(output[repoRange])
                    let url = String(output[Range(match.range, in: output)!])

                    // Try to extract title from gh issue create output
                    let title = extractIssueTitle(from: output)

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

    /// Extract PR title from gh pr create output
    /// Output format varies, but title is often in the --title flag or output
    private static func extractPRTitle(from output: String) -> String? {
        // gh pr create output doesn't include title in URL response
        // Title would need to come from command input, not output
        // For now, return nil - we show "PR #N - owner/repo" as fallback
        return nil
    }

    /// Extract issue title from gh issue create output
    private static func extractIssueTitle(from output: String) -> String? {
        // Same as PR - title not in output
        return nil
    }
}
