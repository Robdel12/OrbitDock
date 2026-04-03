import SwiftUI

/// Terminal-first expanded view for Bash tool output using the shared Ghostty renderer.
struct BashExpandedView: View {
  let content: ServerRowContent
  let isFailed: Bool

  private var outputViewportMaxHeight: CGFloat {
    #if os(iOS)
      360
    #else
      500
    #endif
  }

  private var commandText: String? {
    guard let input = trimmedOrNil(content.inputDisplay) else {
      return nil
    }
    return input.hasPrefix("$ ") ? String(input.dropFirst(2)) : input
  }

  private var outputText: String? {
    trimmedOrNil(content.outputDisplay)
  }

  private var transcript: String? {
    ShellTranscriptBuilder.makeSnapshot(
      command: commandText,
      output: outputText,
      cwd: nil
    )
  }

  var body: some View {
    Group {
      if let transcript {
        TerminalTranscriptSurface(
          output: transcript,
          maxHeight: outputViewportMaxHeight
        )
      } else {
        emptyOutputState
      }
    }
  }

  private var emptyOutputState: some View {
    HStack(spacing: Spacing.xs) {
      Circle()
        .fill(Color.statusWorking.opacity(0.75))
        .frame(width: 5, height: 5)
      Text("Waiting for output…")
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
      Spacer()
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      isFailed ? Color.feedbackNegative.opacity(OpacityTier.tint) : Color.backgroundCode,
      in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
    )
  }

  private func trimmedOrNil(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
