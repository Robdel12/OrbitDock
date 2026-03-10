//
//  DiffModel.swift
//  OrbitDock
//
//  Parsed representation of unified diffs. Shared by EditCard and the Agent Workbench.
//

import Foundation

// MARK: - File Change Type

enum FileChangeType {
  case added
  case modified
  case deleted
  case renamed
}

// MARK: - Diff Line Types

enum DiffLineType {
  case added, removed, context
}

struct DiffLine {
  let type: DiffLineType
  let content: String
  let oldLineNum: Int?
  let newLineNum: Int?
  let prefix: String
}

// MARK: - Diff Hunk

struct DiffHunk: Identifiable {
  let id: Int
  let header: String // @@ -1,5 +1,7 @@
  let oldStart: Int
  let oldCount: Int
  let newStart: Int
  let newCount: Int
  let lines: [DiffLine]
}

// MARK: - File Diff

struct FileDiff: Identifiable {
  let id: String // file path
  let oldPath: String
  let newPath: String
  let changeType: FileChangeType
  let hunks: [DiffHunk]

  var stats: (additions: Int, deletions: Int) {
    let adds = hunks.flatMap(\.lines).filter { $0.type == .added }.count
    let dels = hunks.flatMap(\.lines).filter { $0.type == .removed }.count
    return (adds, dels)
  }
}

// MARK: - Diff Model

struct DiffModel {
  let files: [FileDiff]

  /// Parse a multi-file unified diff string into structured data.
  /// When the same file appears multiple times (e.g. from concatenated turn diffs),
  /// the latest entry wins — this gives the most recent version of each file's changes.
  static func parse(unifiedDiff: String) -> DiffModel {
    let fileChunks = splitIntoFileChunks(unifiedDiff)
    let allFiles = fileChunks.compactMap { parseFileChunk($0) }

    // Deduplicate: keep latest entry per file ID
    var seen: [String: Int] = [:]
    var deduped: [FileDiff] = []
    for file in allFiles {
      if let existing = seen[file.id] {
        deduped[existing] = file
      } else {
        seen[file.id] = deduped.count
        deduped.append(file)
      }
    }

    return DiffModel(files: deduped)
  }

  // MARK: - Private Parsing

  /// Split a unified diff into per-file chunks by detecting `diff --git` or `---`/`+++` boundaries.
  private static func splitIntoFileChunks(_ diff: String) -> [String] {
    let lines = diff.components(separatedBy: "\n")
    var chunks: [String] = []
    var currentChunk: [String] = []

    for line in lines {
      if line.hasPrefix("diff --git ") {
        if !currentChunk.isEmpty {
          chunks.append(currentChunk.joined(separator: "\n"))
        }
        currentChunk = [line]
      } else {
        currentChunk.append(line)
      }
    }

    if !currentChunk.isEmpty {
      chunks.append(currentChunk.joined(separator: "\n"))
    }

    // If no `diff --git` headers, treat the whole thing as one chunk
    if chunks.isEmpty, !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      chunks = [diff]
    }

    return chunks
  }

  /// Parse a single file chunk into a FileDiff.
  private static func parseFileChunk(_ chunk: String) -> FileDiff? {
    let lines = chunk.components(separatedBy: "\n")
    guard !lines.isEmpty else { return nil }

    var oldPath = ""
    var newPath = ""
    var changeType: FileChangeType = .modified
    var hunkStartIndex = 0

    // Parse header lines
    for (i, line) in lines.enumerated() {
      if line.hasPrefix("diff --git ") {
        let parts = line.components(separatedBy: " ")
        if parts.count >= 4 {
          oldPath = String(parts[2].dropFirst(2)) // drop "a/"
          newPath = String(parts[3].dropFirst(2)) // drop "b/"
        }
      } else if line.hasPrefix("--- ") {
        let path = String(line.dropFirst(4))
        if path == "/dev/null" {
          changeType = .added
        } else {
          oldPath = path.hasPrefix("a/") ? String(path.dropFirst(2)) : path
        }
      } else if line.hasPrefix("+++ ") {
        let path = String(line.dropFirst(4))
        if path == "/dev/null" {
          changeType = .deleted
        } else {
          newPath = path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
        }
      } else if line.hasPrefix("rename from ") {
        changeType = .renamed
        oldPath = String(line.dropFirst(12))
      } else if line.hasPrefix("rename to ") {
        newPath = String(line.dropFirst(10))
      } else if line.hasPrefix("new file mode") {
        changeType = .added
      } else if line.hasPrefix("deleted file mode") {
        changeType = .deleted
      } else if line.hasPrefix("@@") {
        hunkStartIndex = i
        break
      }
    }

    // Determine file path for ID
    let filePath = newPath.isEmpty ? oldPath : newPath
    guard !filePath.isEmpty else { return nil }

    // Parse hunks
    let hunks = parseHunks(Array(lines[hunkStartIndex...]))

    return FileDiff(
      id: filePath,
      oldPath: oldPath,
      newPath: newPath,
      changeType: changeType,
      hunks: hunks
    )
  }

  /// Parse `@@` hunk headers and their content lines.
  private static func parseHunks(_ lines: [String]) -> [DiffHunk] {
    var hunks: [DiffHunk] = []
    var currentLines: [DiffLine] = []
    var header = ""
    var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
    var hunkId = 0
    var oldLine = 0
    var newLine = 0

    for line in lines {
      if line.hasPrefix("@@") {
        // Save previous hunk
        if !header.isEmpty {
          hunks.append(DiffHunk(
            id: hunkId,
            header: header,
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            lines: currentLines
          ))
          hunkId += 1
          currentLines = []
        }

        header = line
        // Parse @@ -oldStart,oldCount +newStart,newCount @@
        let parsed = parseHunkHeader(line)
        oldStart = parsed.oldStart
        oldCount = parsed.oldCount
        newStart = parsed.newStart
        newCount = parsed.newCount
        oldLine = oldStart
        newLine = newStart
      } else if !header.isEmpty {
        if line.hasPrefix("+") {
          currentLines.append(DiffLine(
            type: .added,
            content: String(line.dropFirst()),
            oldLineNum: nil,
            newLineNum: newLine,
            prefix: "+"
          ))
          newLine += 1
        } else if line.hasPrefix("-") {
          currentLines.append(DiffLine(
            type: .removed,
            content: String(line.dropFirst()),
            oldLineNum: oldLine,
            newLineNum: nil,
            prefix: "-"
          ))
          oldLine += 1
        } else if line.hasPrefix(" ") || line.isEmpty {
          let content = line.isEmpty ? "" : String(line.dropFirst())
          currentLines.append(DiffLine(
            type: .context,
            content: content,
            oldLineNum: oldLine,
            newLineNum: newLine,
            prefix: " "
          ))
          oldLine += 1
          newLine += 1
        } else if line.hasPrefix("\\") {
          // "\ No newline at end of file" — skip
          continue
        }
      }
    }

    // Save last hunk
    if !header.isEmpty {
      hunks.append(DiffHunk(
        id: hunkId,
        header: header,
        oldStart: oldStart,
        oldCount: oldCount,
        newStart: newStart,
        newCount: newCount,
        lines: currentLines
      ))
    }

    return hunks
  }

  /// Parse a hunk header like `@@ -1,5 +1,7 @@` into components.
  private static func parseHunkHeader(_ header: String)
    -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)
  {
    // Match @@ -oldStart,oldCount +newStart,newCount @@
    guard let regex = try? NSRegularExpression(pattern: #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#),
          let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header))
    else {
      return (1, 0, 1, 0)
    }

    let ns = header as NSString

    let os = match.range(at: 1).location != NSNotFound
      ? Int(ns.substring(with: match.range(at: 1))) ?? 1 : 1
    let oc = match.range(at: 2).location != NSNotFound
      ? Int(ns.substring(with: match.range(at: 2))) ?? 0 : 1
    let nss = match.range(at: 3).location != NSNotFound
      ? Int(ns.substring(with: match.range(at: 3))) ?? 1 : 1
    let nc = match.range(at: 4).location != NSNotFound
      ? Int(ns.substring(with: match.range(at: 4))) ?? 0 : 1

    return (os, oc, nss, nc)
  }
}

// MARK: - Word-Level Inline Diff

extension DiffModel {
  /// For adjacent removed+added line pairs, compute character-level changes.
  /// Returns ranges within each line that represent the actual changes.
  static func inlineChanges(
    oldLine: String,
    newLine: String
  ) -> (old: [Range<String.Index>], new: [Range<String.Index>]) {
    let lcs = longestCommonSubsequence(Array(oldLine), Array(newLine))
    let oldRanges = findChangedRanges(oldLine, lcs: lcs, isOld: true)
    let newRanges = findChangedRanges(newLine, lcs: lcs, isOld: false)
    return (oldRanges, newRanges)
  }

  private static func longestCommonSubsequence(_ a: [Character], _ b: [Character]) -> [[Int]] {
    let m = a.count
    let n = b.count
    var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
    for i in 1 ... m {
      for j in 1 ... n {
        if a[i - 1] == b[j - 1] {
          dp[i][j] = dp[i - 1][j - 1] + 1
        } else {
          dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
        }
      }
    }
    return dp
  }

  private static func findChangedRanges(_ text: String, lcs: [[Int]], isOld: Bool) -> [Range<String.Index>] {
    let chars = Array(text)
    let m = lcs.count - 1
    let n = lcs[0].count - 1

    // Backtrack to find which characters are NOT in the LCS
    var inLCS = [Bool](repeating: false, count: isOld ? m : n)
    var i = m, j = n
    while i > 0, j > 0 {
      if lcs[i][j] == lcs[i - 1][j] {
        i -= 1
      } else if lcs[i][j] == lcs[i][j - 1] {
        j -= 1
      } else {
        // Match
        if isOld { inLCS[i - 1] = true } else { inLCS[j - 1] = true }
        i -= 1
        j -= 1
      }
    }

    // Build ranges of consecutive non-LCS characters
    var ranges: [Range<String.Index>] = []
    let count = isOld ? m : n
    guard count > 0, count == chars.count else { return ranges }

    var idx = text.startIndex
    var rangeStart: String.Index?

    for k in 0 ..< count {
      if !inLCS[k] {
        if rangeStart == nil { rangeStart = idx }
      } else {
        if let start = rangeStart {
          ranges.append(start ..< idx)
          rangeStart = nil
        }
      }
      idx = text.index(after: idx)
    }
    if let start = rangeStart {
      ranges.append(start ..< text.endIndex)
    }

    return ranges
  }
}
