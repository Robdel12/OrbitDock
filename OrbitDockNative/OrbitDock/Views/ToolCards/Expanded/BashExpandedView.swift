//
//  BashExpandedView.swift
//  OrbitDock
//
//  Terminal emulator feel for bash tool output.
//  Features: slim terminal chrome, ANSI color parsing, scrollable capped output, exit status.
//

import SwiftUI

struct BashExpandedView: View {
  let content: ServerRowContent
  let isFailed: Bool

  @State private var isFullyExpanded = false

  /// Height cap for the output viewport
  private let maxOutputHeight: CGFloat = 350
  /// Line count threshold — outputs shorter than this render inline
  private let inlineThreshold = 25

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
        let lineCount = output.components(separatedBy: "\n").count
        let parsed = ANSIColorParser.parse(output)
        let useViewport = lineCount > inlineThreshold && !isFullyExpanded

        VStack(alignment: .leading, spacing: Spacing.xs) {
          // Output header
          HStack(spacing: Spacing.sm) {
            Text("Output")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)

            Spacer()

            Text("\(lineCount) lines")
              .font(.system(size: TypeScale.mini, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
              .padding(.horizontal, Spacing.sm_)
              .padding(.vertical, Spacing.xxs)
              .background(Color.backgroundSecondary, in: Capsule())

            exitCodePill(code: isFailed ? 1 : 0)
          }
          .padding(.top, Spacing.sm)

          // Output content — viewport or inline
          if useViewport {
            // Scrollable capped viewport
            VStack(spacing: 0) {
              ScrollView(.vertical, showsIndicators: false) {
                Text(parsed)
                  .padding(Spacing.sm)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(maxHeight: maxOutputHeight)
              .mask(edgeFadeMask)

              // Footer
              HStack {
                Text("\(lineCount) lines")
                  .font(.system(size: TypeScale.mini, design: .monospaced))
                  .foregroundStyle(Color.textQuaternary)
                Spacer()
                Button {
                  withAnimation(Motion.standard) {
                    isFullyExpanded = true
                  }
                } label: {
                  HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                      .font(.system(size: 8))
                    Text("Expand to full")
                      .font(.system(size: TypeScale.mini, weight: .medium))
                  }
                  .foregroundStyle(Color.toolBash)
                }
                .buttonStyle(.plain)
              }
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.sm_)
              .overlay(alignment: .top) {
                Rectangle()
                  .fill(Color.textQuaternary.opacity(0.06))
                  .frame(height: 1)
              }
            }
            .background(
              isFailed
                ? Color.feedbackNegative.opacity(OpacityTier.tint)
                : Color.backgroundCode,
              in: RoundedRectangle(cornerRadius: Radius.sm)
            )
          } else {
            // Inline (small output or fully expanded)
            VStack(alignment: .leading, spacing: 0) {
              Text(parsed)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)

              if lineCount > inlineThreshold {
                // Collapse button
                HStack {
                  Spacer()
                  Button {
                    withAnimation(Motion.standard) {
                      isFullyExpanded = false
                    }
                  } label: {
                    HStack(spacing: Spacing.xs) {
                      Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 8))
                      Text("Collapse to viewport")
                        .font(.system(size: TypeScale.mini, weight: .medium))
                    }
                    .foregroundStyle(Color.toolBash)
                  }
                  .buttonStyle(.plain)
                }
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
  }

  // MARK: - Edge Fade Mask

  private var edgeFadeMask: some View {
    VStack(spacing: 0) {
      LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
        .frame(height: 10)
      Color.black
      LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
        .frame(height: 10)
    }
  }

  // MARK: - Exit Code

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
