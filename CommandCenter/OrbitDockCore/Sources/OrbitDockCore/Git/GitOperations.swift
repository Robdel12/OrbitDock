import Foundation

// MARK: - Git Operations

public enum GitOperations {

    /// Execute a git command and return the output
    private static func execGit(_ arguments: [String], in directory: String) -> String? {
        let task = Process()
        task.currentDirectoryURL = URL(fileURLWithPath: directory)
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_TERMINAL_PROMPT": "0"],
            uniquingKeysWith: { _, new in new }
        )

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Get current branch name
    public static func getCurrentBranch(in directory: String) -> String? {
        execGit(["branch", "--show-current"], in: directory)
    }

    /// Check if current branch is a feature branch (not main/master/develop)
    public static func isFeatureBranch(in directory: String) -> Bool {
        guard let branch = getCurrentBranch(in: directory) else { return false }
        return !["main", "master", "develop", "dev"].contains(branch.lowercased())
    }

    /// Get repo root path (worktree-aware)
    /// For worktrees, returns the main repo root, not the worktree root
    public static func getRepoRoot(in directory: String) -> String? {
        guard var root = execGit(["rev-parse", "--show-toplevel"], in: directory) else {
            return nil
        }

        // Check if this is a worktree
        guard let gitCommonDir = execGit(["rev-parse", "--git-common-dir"], in: directory) else {
            return root
        }

        // If git-common-dir is not ".git", we're in a worktree
        if gitCommonDir != ".git" && !gitCommonDir.hasSuffix("/.git") {
            // gitCommonDir is like /path/to/main-repo/.git/worktrees/worktree-name
            // We want /path/to/main-repo
            let url = URL(fileURLWithPath: gitCommonDir)
            if let mainRepoRoot = url.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent().path as String? {
                root = mainRepoRoot
            }
        }

        return root
    }

    /// Get repo name from path
    public static func getRepoName(in directory: String) -> String {
        if let root = getRepoRoot(in: directory) {
            return URL(fileURLWithPath: root).lastPathComponent
        }
        return URL(fileURLWithPath: directory).lastPathComponent
    }

    /// Get GitHub remote info (owner/name)
    public static func getGitHubRemote(in directory: String) -> (owner: String, name: String)? {
        guard let remoteUrl = execGit(["remote", "get-url", "origin"], in: directory) else {
            return nil
        }

        // Parse SSH format: git@github.com:owner/repo.git
        let sshPattern = #"github\.com[:/]([^/]+)/([^/.]+)"#
        if let regex = try? NSRegularExpression(pattern: sshPattern),
           let match = regex.firstMatch(
               in: remoteUrl,
               range: NSRange(remoteUrl.startIndex..., in: remoteUrl)
           ) {
            if let ownerRange = Range(match.range(at: 1), in: remoteUrl),
               let nameRange = Range(match.range(at: 2), in: remoteUrl) {
                return (String(remoteUrl[ownerRange]), String(remoteUrl[nameRange]))
            }
        }

        return nil
    }

    /// Parse Linear issue ID from branch name
    /// e.g., "viz-42-add-dark-mode" -> "VIZ-42"
    public static func parseLinearIssueFromBranch(_ branch: String) -> String? {
        let pattern = #"([a-zA-Z]+-\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: branch,
                  range: NSRange(branch.startIndex..., in: branch)
              ),
              let range = Range(match.range(at: 1), in: branch) else {
            return nil
        }
        return String(branch[range]).uppercased()
    }

    /// Detect if a tool invocation is creating a new branch
    /// Returns the new branch name if detected, nil otherwise
    public static func detectBranchCreation(toolName: String, command: String?) -> String? {
        guard toolName == "Bash", let cmd = command else { return nil }

        // git checkout -b <branch> or -B
        let checkoutPattern = #"git\s+checkout\s+-[bB]\s+["']?([^\s"']+)["']?"#
        if let match = firstMatch(pattern: checkoutPattern, in: cmd) {
            return match
        }

        // git switch -c <branch> or -C or --create
        let switchPattern = #"git\s+switch\s+(?:-[cC]|--create)\s+["']?([^\s"']+)["']?"#
        if let match = firstMatch(pattern: switchPattern, in: cmd) {
            return match
        }

        // git branch <branch> (without -d, -D, -m flags)
        let branchPattern = #"git\s+branch\s+(?!-[dDm])["']?([^\s"']+)["']?"#
        if let match = firstMatch(pattern: branchPattern, in: cmd) {
            return match
        }

        // git worktree add -b <branch>
        let worktreePattern = #"git\s+worktree\s+add\s+.*-b\s+["']?([^\s"']+)["']?"#
        if let match = firstMatch(pattern: worktreePattern, in: cmd) {
            return match
        }

        return nil
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
