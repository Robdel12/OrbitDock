import SwiftUI

/// Terminal-first expanded view for Bash tool output using the shared Ghostty renderer.
///
/// Supports two rendering modes:
/// 1. **Live PTY mode**: When `toolPtySession` is provided, streams raw bytes directly
///    to Ghostty for true terminal rendering with ANSI colors and cursor control.
/// 2. **Transcript mode**: Falls back to building a transcript from text output when
///    live PTY isn't available.
struct BashExpandedView: View {
  let content: ServerRowContent
  let isFailed: Bool
  /// Streaming output preview from toolDisplay, updated via websocket while running.
  var liveOutputPreview: String?
  /// Whether the tool is currently running (enables streaming mode).
  var isRunning: Bool = false
  /// Normalized command from the provider-agnostic shell execution payload.
  var commandOverride: String?
  /// Working directory from the provider-agnostic shell execution payload.
  var cwd: String?
  /// Terminal title from the provider-agnostic shell execution payload.
  var terminalTitle: String?
  /// Live PTY session for streaming raw terminal output.
  /// When provided, uses TerminalContainerView instead of transcript rendering.
  var toolPtySession: TerminalSessionController?

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var outputViewportMaxHeight: CGFloat {
    horizontalSizeClass == .compact ? 360 : 500
  }

  private var commandText: String? {
    normalizedCommand(commandOverride) ?? normalizedCommand(content.inputDisplay)
  }

  private var outputText: String? {
    isRunning
      ? nonBlankOrNil(liveOutputPreview) ?? nonBlankOrNil(content.outputDisplay)
      : nonBlankOrNil(content.outputDisplay) ?? nonBlankOrNil(liveOutputPreview)
  }

  private var transcript: String? {
    ShellTranscriptBuilder.makeSnapshot(
      command: commandText,
      output: outputText,
      cwd: cwd
    )
  }

  var body: some View {
    Group {
      if let session = toolPtySession {
        liveTerminalView(session: session)
      } else if let transcript {
        TerminalTranscriptSurface(
          output: transcript,
          maxHeight: outputViewportMaxHeight
        )
      } else {
        emptyOutputState
      }
    }
  }

  @ViewBuilder
  private func liveTerminalView(session: TerminalSessionController) -> some View {
    TerminalContainerView(
      session: session,
      shouldAutoFocusOnFirstAttachment: false,
      captureScrollWithoutFocus: true,
      allowsInput: false,
      titleOverride: title,
      showsTitleBar: false
    )
    .frame(maxHeight: outputViewportMaxHeight)
  }

  private var title: String {
    trimmedOrNil(terminalTitle)
      ?? trimmedOrNil(cwd).map { ToolCardStyle.shortenPath($0) }
      ?? commandText.map { "$ \($0)" }
      ?? "Terminal"
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

  private func normalizedCommand(_ value: String?) -> String? {
    guard let command = trimmedOrNil(value) else { return nil }
    return command.hasPrefix("$ ") ? String(command.dropFirst(2)) : command
  }

  private func nonBlankOrNil(_ value: String?) -> String? {
    guard let value else { return nil }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
  }
}
