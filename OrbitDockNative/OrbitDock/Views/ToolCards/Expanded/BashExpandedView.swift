//
//  BashExpandedView.swift
//  OrbitDock
//
//  Terminal emulator feel for bash tool output.
//  Features: terminal chrome header, ANSI color parsing, exit status footer.
//

import SwiftUI

struct BashExpandedView: View {
  let content: ServerRowContent
  let isFailed: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let input = content.inputDisplay, !input.isEmpty {
        let command = input.hasPrefix("$ ") ? String(input.dropFirst(2)) : input

        // Terminal chrome + command
        VStack(alignment: .leading, spacing: 0) {
          TerminalChrome(path: nil)

          // Command line
          HStack(alignment: .top, spacing: Spacing.xs) {
            Text("$")
              .font(.system(size: TypeScale.code, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.toolBash)

            // Syntax-highlighted command
            let highlighted = SyntaxHighlighter.highlightLine(command, language: "bash")
            Text(highlighted)
          }
          .padding(Spacing.sm)
        }
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      }

      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack {
            Text("Output")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
            Spacer()
            if isFailed {
              exitCodePill(code: 1)
            } else {
              exitCodePill(code: 0)
            }
          }
          .padding(.top, Spacing.sm)

          // ANSI-parsed output
          let parsed = ANSIColorParser.parse(output)
          Text(parsed)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
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
