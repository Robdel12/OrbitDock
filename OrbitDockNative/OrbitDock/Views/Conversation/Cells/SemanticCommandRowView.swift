//
//  SemanticCommandRowView.swift
//  OrbitDock
//
//  Structured server-driven shell command row.
//

import SwiftUI

struct SemanticCommandRowView: View {
  let row: ServerConversationShellCommandRow

  private var metadata: String? {
    var parts: [String] = []
    if let exitCode = row.exitCode {
      parts.append("exit \(exitCode)")
    }
    if let durationSeconds = row.durationSeconds {
      parts.append(String(format: "%.2fs", durationSeconds))
    }
    if let cwd = row.cwd, !cwd.isEmpty {
      parts.append(cwd)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " • ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "terminal")
          .font(.system(size: IconScale.md, weight: .semibold))
          .foregroundStyle(Color.statusWorking)
        Text(row.command ?? row.title)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .textSelection(.enabled)
        Spacer()
      }

      if let summary = row.summary, !summary.isEmpty {
        Text(summary)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textSecondary)
      }

      if let metadata, !metadata.isEmpty {
        Text(metadata)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }

      if let stdout = row.stdout, !stdout.isEmpty {
        Text(stdout)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(8)
          .textSelection(.enabled)
      }

      if let stderr = row.stderr, !stderr.isEmpty {
        Text(stderr)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.feedbackNegative)
          .lineLimit(8)
          .textSelection(.enabled)
      }
    }
    .padding(Spacing.md)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.statusWorking.opacity(0.22), lineWidth: 1)
    )
    .padding(.vertical, Spacing.xs)
  }
}
