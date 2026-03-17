//
//  BashExpandedView.swift
//  OrbitDock
//
//  Unified terminal block for bash tool output.
//  Features: single terminal chrome + command + output block, ANSI color parsing,
//  scrollable capped output viewport, footer bar with exit status + expand/collapse.
//

import SwiftUI

struct BashExpandedView: View {
  let content: ServerRowContent
  let isFailed: Bool

  @State private var isFullyExpanded = false

  /// Height cap for the output viewport (shorter on iOS to preserve scroll context)
  private var maxOutputHeight: CGFloat {
    #if os(iOS)
      260
    #else
      350
    #endif
  }

  /// Line count threshold — outputs shorter than this render inline
  private let inlineThreshold = 25

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Single unified terminal block
      VStack(alignment: .leading, spacing: 0) {
        TerminalChrome(path: nil)

        // Command line
        if let input = content.inputDisplay, !input.isEmpty {
          let command = input.hasPrefix("$ ") ? String(input.dropFirst(2)) : input
          HStack(alignment: .top, spacing: Spacing.xs) {
            Text("$")
              .font(.system(size: TypeScale.code, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.toolBash)
            let highlighted = SyntaxHighlighter.highlightLine(command, language: "bash")
            Text(highlighted)
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.sm)
        }

        // Output flows directly below — no gap, no header
        if let output = content.outputDisplay, !output.isEmpty {
          // Thin separator between command and output
          Rectangle()
            .fill(Color.textQuaternary.opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, Spacing.sm)

          outputContent(output)

          // Footer bar
          footerBar(lineCount: output.components(separatedBy: "\n").count)
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

  // MARK: - Output Content

  /// Output content — viewport or inline depending on line count
  @ViewBuilder
  private func outputContent(_ output: String) -> some View {
    let lineCount = output.components(separatedBy: "\n").count
    let parsed = ANSIColorParser.parse(output)
    let useViewport = lineCount > inlineThreshold && !isFullyExpanded

    if useViewport {
      ScrollView(.vertical, showsIndicators: false) {
        Text(parsed)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: maxOutputHeight)
      .mask(edgeFadeMask)
    } else {
      Text(parsed)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
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

  // MARK: - Footer Bar

  /// Unified footer bar with line count, exit code pill, and expand/collapse
  private func footerBar(lineCount: Int) -> some View {
    HStack(spacing: Spacing.sm) {
      Text("\(lineCount) lines")
        .font(.system(size: TypeScale.mini, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)

      exitCodePill(failed: isFailed)

      Spacer()

      if lineCount > inlineThreshold {
        Button {
          withAnimation(Motion.standard) {
            isFullyExpanded.toggle()
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: isFullyExpanded
              ? "arrow.down.right.and.arrow.up.left"
              : "arrow.up.left.and.arrow.down.right")
              .font(.system(size: 8))
            Text(isFullyExpanded ? "Collapse" : "Expand")
              .font(.system(size: TypeScale.mini, weight: .medium))
          }
          .foregroundStyle(Color.toolBash)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.textQuaternary.opacity(0.06))
        .frame(height: 1)
    }
  }

  // MARK: - Exit Code Pill

  private func exitCodePill(failed: Bool) -> some View {
    let color: Color = failed ? .feedbackNegative : .feedbackPositive
    let label = failed ? "EXIT \u{2717}" : "EXIT 0"
    return Text(label)
      .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, 1)
      .background(color.opacity(OpacityTier.subtle), in: Capsule())
  }
}
