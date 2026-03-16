//
//  BashExpandedView.swift
//  OrbitDock
//
//  Terminal emulator feel for bash tool output.
//  Features: slim terminal chrome header, ANSI color parsing, output truncation, exit status.
//

import SwiftUI

struct BashExpandedView: View {
  let content: ServerRowContent
  let isFailed: Bool

  @State private var showAllOutput = false

  /// Max lines shown before truncation
  private let truncationThreshold = 50
  /// Lines shown when truncated
  private let truncatedLineCount = 30

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let input = content.inputDisplay, !input.isEmpty {
        let command = input.hasPrefix("$ ") ? String(input.dropFirst(2)) : input

        // Terminal chrome + command as a single block
        VStack(alignment: .leading, spacing: 0) {
          TerminalChrome(path: nil)

          // Command line
          HStack(alignment: .top, spacing: Spacing.xs) {
            Text("$")
              .font(.system(size: TypeScale.code, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.toolBash)

            let highlighted = SyntaxHighlighter.highlightLine(command, language: "bash")
            Text(highlighted)
          }
          .padding(Spacing.sm)
        }
        .background(Color.backgroundCode)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
      }

      if let output = content.outputDisplay, !output.isEmpty {
        let allLines = output.components(separatedBy: "\n")
        let lineCount = allLines.count
        let shouldTruncate = lineCount > truncationThreshold && !showAllOutput
        let displayOutput = shouldTruncate
          ? allLines.prefix(truncatedLineCount).joined(separator: "\n")
          : output

        VStack(alignment: .leading, spacing: Spacing.xs) {
          // Output header: label + line count badge + exit code pill
          HStack(spacing: Spacing.sm) {
            Text("Output")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)

            Spacer()

            // Line count badge
            Text("\(lineCount) lines")
              .font(.system(size: TypeScale.mini, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
              .padding(.horizontal, Spacing.sm_)
              .padding(.vertical, Spacing.xxs)
              .background(Color.backgroundSecondary, in: Capsule())

            exitCodePill(code: isFailed ? 1 : 0)
          }
          .padding(.top, Spacing.sm)

          // ANSI-parsed output
          VStack(alignment: .leading, spacing: 0) {
            let parsed = ANSIColorParser.parse(displayOutput)
            Text(parsed)
              .padding(Spacing.sm)
              .frame(maxWidth: .infinity, alignment: .leading)

            // "Show all N lines" button when truncated
            if shouldTruncate {
              Button {
                withAnimation(Motion.standard) {
                  showAllOutput = true
                }
              } label: {
                Text("Show all \(lineCount) lines")
                  .font(.system(size: TypeScale.caption))
                  .foregroundStyle(Color.accent)
              }
              .buttonStyle(.plain)
              .padding(.horizontal, Spacing.sm)
              .padding(.bottom, Spacing.sm)
            }
          }
          .background(
            isFailed
              ? Color.feedbackNegative.opacity(OpacityTier.tint)
              : Color.backgroundCode,
            in: RoundedRectangle(cornerRadius: Radius.sm)
          )
        }
      }
    }
  }

  private func exitCodePill(code: Int) -> some View {
    let color: Color = code == 0 ? .feedbackPositive : .feedbackNegative
    return Text("EXIT \(code)")
      .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, 1)
      .background(color.opacity(OpacityTier.subtle), in: Capsule())
  }
}
