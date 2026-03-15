//
//  WordLevelDiff.swift
//  OrbitDock
//
//  Computes word-level diff between two strings for inline highlighting.
//  Used by EditExpandedView to show exactly which words changed within a line pair.
//

import Foundation

enum WordLevelDiff {
  struct Segment {
    let text: String
    let isChanged: Bool
  }

  /// Split strings on word boundaries and compute LCS-based diff.
  /// Returns (oldSegments, newSegments) with changed regions marked.
  static func compute(old: String, new: String) -> (old: [Segment], new: [Segment]) {
    let oldTokens = tokenize(old)
    let newTokens = tokenize(new)

    let lcs = longestCommonSubsequence(oldTokens, newTokens)

    let oldSegments = markChanged(tokens: oldTokens, lcs: lcs.oldIndices)
    let newSegments = markChanged(tokens: newTokens, lcs: lcs.newIndices)

    return (oldSegments, newSegments)
  }

  // MARK: - Tokenization

  private static func tokenize(_ string: String) -> [String] {
    var tokens: [String] = []
    var current = ""

    for char in string {
      if char.isWhitespace || char.isPunctuation {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
        tokens.append(String(char))
      } else {
        current.append(char)
      }
    }
    if !current.isEmpty {
      tokens.append(current)
    }

    return tokens
  }

  // MARK: - LCS

  private struct LCSResult {
    let oldIndices: Set<Int>
    let newIndices: Set<Int>
  }

  private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> LCSResult {
    let m = a.count
    let n = b.count

    // For very long sequences, fall back to marking everything changed
    if m * n > 50_000 {
      return LCSResult(oldIndices: [], newIndices: [])
    }

    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

    for i in 1...max(m, 1) {
      for j in 1...max(n, 1) {
        if i <= m, j <= n, a[i - 1] == b[j - 1] {
          dp[i][j] = dp[i - 1][j - 1] + 1
        } else {
          dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
        }
      }
    }

    // Backtrack to find LCS indices
    var oldIndices = Set<Int>()
    var newIndices = Set<Int>()
    var i = m
    var j = n

    while i > 0, j > 0 {
      if a[i - 1] == b[j - 1] {
        oldIndices.insert(i - 1)
        newIndices.insert(j - 1)
        i -= 1
        j -= 1
      } else if dp[i - 1][j] > dp[i][j - 1] {
        i -= 1
      } else {
        j -= 1
      }
    }

    return LCSResult(oldIndices: oldIndices, newIndices: newIndices)
  }

  // MARK: - Mark Changed

  private static func markChanged(tokens: [String], lcs: Set<Int>) -> [Segment] {
    var segments: [Segment] = []
    var currentText = ""
    var currentChanged: Bool?

    for (index, token) in tokens.enumerated() {
      let isChanged = !lcs.contains(index)

      if isChanged == currentChanged {
        currentText += token
      } else {
        if !currentText.isEmpty, let changed = currentChanged {
          segments.append(Segment(text: currentText, isChanged: changed))
        }
        currentText = token
        currentChanged = isChanged
      }
    }

    if !currentText.isEmpty, let changed = currentChanged {
      segments.append(Segment(text: currentText, isChanged: changed))
    }

    return segments
  }
}
