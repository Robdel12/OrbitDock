import SwiftUI

/// Terminal-first expanded view for Bash tool output using the shared Ghostty renderer.
///
/// Supports streaming output via `liveOutputPreview` when the tool is running,
/// falling back to `content.outputDisplay` when complete.
struct BashExpandedView: View {
  let content: ServerRowContent
  let isFailed: Bool
  /// Streaming output preview from toolDisplay, updated via websocket while running.
  var liveOutputPreview: String?
  /// Whether the tool is currently running (enables streaming mode).
  var isRunning: Bool = false

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var outputViewportMaxHeight: CGFloat {
    horizontalSizeClass == .compact ? 360 : 500
  }

  private var commandText: String? {
    guard let input = trimmedOrNil(content.inputDisplay) else {
      return nil
    }
    return input.hasPrefix("$ ") ? String(input.dropFirst(2)) : input
  }

  /// Output using context-aware fallback:
  /// - Running: prefer streaming `liveOutputPreview` (real-time updates)
  /// - Complete: prefer `content.outputDisplay` (full untruncated output from REST)
  private var outputText: String? {
    if isRunning {
      // While running, streaming data is fresher
      if let live = trimmedOrNil(liveOutputPreview) {
        return live
      }
      return trimmedOrNil(content.outputDisplay)
    } else {
      // Once complete, REST fetch has full untruncated output
      if let fetched = trimmedOrNil(content.outputDisplay) {
        return fetched
      }
      return trimmedOrNil(liveOutputPreview)
    }
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
