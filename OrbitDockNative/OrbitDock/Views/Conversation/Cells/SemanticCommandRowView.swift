//
//  SemanticCommandRowView.swift
//  OrbitDock
//
//  Structured server-driven shell command row.
//

import SwiftUI

struct SemanticCommandRowView: View {
  let row: ServerConversationShellCommandRow

  @Environment(\.horizontalSizeClass) private var sizeClass

  private var isCompactLayout: Bool {
    sizeClass == .compact
  }

  private var commandText: String {
    row.command ?? String.shellCommandDisplay(from: row.args) ?? row.title
  }

  private var shellLabel: String {
    switch row.kind {
      case .slashCommand:
        "Slash"
      case .localCommandOutput:
        "Local"
      case .shellContext:
        "Shell Context"
      default:
        "Shell"
    }
  }

  private var shellLabelColor: Color {
    switch row.kind {
      case .slashCommand:
        .statusReply
      case .localCommandOutput:
        .feedbackCaution
      case .shellContext:
        .textTertiary
      default:
        .toolBash
    }
  }

  private var exitColor: Color {
    if let exitCode = row.exitCode, exitCode != 0 {
      return .feedbackNegative
    }
    return .feedbackPositive
  }

  private var exitLabel: String? {
    guard let exitCode = row.exitCode else { return nil }
    return exitCode == 0 ? "EXIT 0" : "EXIT \(exitCode)"
  }

  private var durationLabel: String? {
    guard let durationSeconds = row.durationSeconds else { return nil }
    if durationSeconds >= 10 {
      return String(format: "%.1fs", durationSeconds)
    }
    return String(format: "%.2fs", durationSeconds)
  }

  private var workingDirectoryLabel: String? {
    guard let cwd = row.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else { return nil }
    return ToolCardStyle.shortenPath(cwd)
  }

  private var stdoutLines: [String] {
    previewLines(from: row.stdout, limit: isCompactLayout ? 7 : 6)
  }

  private var stderrLines: [String] {
    previewLines(from: row.stderr, limit: isCompactLayout ? 5 : 4)
  }

  private var orderedPreviewLines: [String] {
    guard row.stdout != nil, row.stderr != nil else { return [] }
    return previewLines(from: row.outputPreview, limit: isCompactLayout ? 9 : 8)
  }

  private var hasOutput: Bool {
    !orderedPreviewLines.isEmpty || !stdoutLines.isEmpty || !stderrLines.isEmpty
  }

  private var summaryText: String? {
    let trimmed = row.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty, trimmed != commandText else { return nil }
    return trimmed
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      if let summaryText {
        Text(summaryText)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textSecondary)
          .padding(.horizontal, Spacing.md)
          .padding(.bottom, hasOutput ? Spacing.sm_ : Spacing.md)
      }

      if hasOutput {
        outputPanel
          .padding(.horizontal, isCompactLayout ? Spacing.sm : Spacing.md)
          .padding(.bottom, Spacing.md)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.xl : Radius.lg, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(isCompactLayout ? 0.985 : 0.96))
    )
    .overlay {
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.xl : Radius.lg, style: .continuous)
        .strokeBorder(Color.white.opacity(isCompactLayout ? 0.075 : 0.055), lineWidth: 1)
    }
    .themeShadow(isCompactLayout ? Shadow.md : Shadow.sm)
    .padding(.vertical, Spacing.xs)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        terminalBadge

        VStack(alignment: .leading, spacing: 2) {
          Text(commandText)
            .font(.system(
              size: isCompactLayout ? TypeScale.subhead : TypeScale.body,
              weight: .semibold,
              design: .monospaced
            ))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(isCompactLayout ? 3 : 2)
            .textSelection(.enabled)

          if let workingDirectoryLabel {
            Text(workingDirectoryLabel)
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)

        HStack(spacing: Spacing.xs) {
          if let durationLabel {
            metaCapsule(text: durationLabel, tint: shellLabelColor)
          }

          if let exitLabel {
            metaCapsule(text: exitLabel, tint: exitColor, isEmphasized: true)
          }
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, isCompactLayout ? Spacing.md_ : Spacing.sm_)
    .padding(.bottom, summaryText == nil && !hasOutput ? Spacing.md : Spacing.sm_)
  }

  private var terminalBadge: some View {
    VStack(spacing: 0) {
      ZStack {
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(shellLabelColor.opacity(0.14))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
          )

        Image(systemName: "terminal")
          .font(.system(size: IconScale.md, weight: .semibold))
          .foregroundStyle(shellLabelColor)
      }
      .frame(width: isCompactLayout ? 28 : 24, height: isCompactLayout ? 28 : 24)
    }
  }

  private var outputPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      panelHeader

      if !orderedPreviewLines.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(orderedPreviewLines.enumerated()), id: \.offset) { _, line in
            outputLine(line, tint: Color.textTertiary, textColor: Color.textSecondary)
          }
        }
      } else {
        if !stdoutLines.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(stdoutLines.enumerated()), id: \.offset) { _, line in
              outputLine(line, tint: shellLabelColor.opacity(0.8))
            }
          }
        }

        if !stderrLines.isEmpty {
          if !stdoutLines.isEmpty {
            Rectangle()
              .fill(Color.white.opacity(0.05))
              .frame(height: 1)
              .padding(.vertical, Spacing.xs)
          }

          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(stderrLines.enumerated()), id: \.offset) { _, line in
              outputLine(line, tint: Color.feedbackNegative, textColor: Color.feedbackNegative.opacity(0.92))
            }
          }
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundCode.opacity(0.98))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
        )
    )
  }

  private var panelHeader: some View {
    HStack(spacing: Spacing.sm_) {
      if !stdoutLines.isEmpty {
        headerDot(Color.toolBash)
      }

      if !stderrLines.isEmpty {
        headerDot(Color.feedbackNegative)
      }

      Text(stderrLines.isEmpty ? "Output" : (stdoutLines.isEmpty ? "Error output" : "Output and errors"))
        .font(.system(size: TypeScale.mini, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      Text("\(stdoutLines.count + stderrLines.count) lines")
        .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
    }
  }

  private func headerDot(_ color: Color) -> some View {
    Circle()
      .fill(color)
      .frame(width: 5, height: 5)
  }

  private func metaCapsule(text: String, tint: Color, isEmphasized: Bool = false) -> some View {
    Text(text)
      .font(.system(size: TypeScale.mini, weight: isEmphasized ? .bold : .medium, design: .monospaced))
      .foregroundStyle(isEmphasized ? tint : Color.textTertiary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(
        Capsule()
          .fill(Color.backgroundCode.opacity(0.9))
          .overlay(
            Capsule()
              .fill(tint.opacity(isEmphasized ? 0.08 : 0.0))
          )
          .overlay(
            Capsule()
              .strokeBorder(Color.white.opacity(0.045), lineWidth: 1)
          )
      )
  }

  private func outputLine(_ text: String, tint: Color, textColor: Color = Color.textSecondary) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm_) {
      Text("$")
        .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
        .foregroundStyle(tint.opacity(0.7))
        .frame(width: 10, alignment: .leading)

      Text(text)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(textColor)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
  }

  private func previewLines(from text: String?, limit: Int) -> [String] {
    guard let text else { return [] }

    return text
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .prefix(limit)
      .map { String($0.prefix(180)) }
  }
}
