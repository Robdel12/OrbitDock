//
//  ShellCard.swift
//  OrbitDock
//
//  Terminal-style card for user-initiated shell commands.
//  Right-aligned like other user entries, with output shown by default.
//

import SwiftUI

struct ShellCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool
  @Binding var isHovering: Bool
  var onSendToAI: ((String) -> Void)?

  private var hasError: Bool {
    message.bashHasError
  }

  private var accentColor: Color {
    hasError ? .orange : .shellAccent
  }

  private var hasOutput: Bool {
    guard let output = message.sanitizedToolOutput else { return false }
    return !output.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // ━━━ Command header ━━━
      HStack(spacing: 10) {
        Image(systemName: "terminal.fill")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(accentColor)
          .frame(width: 16)

        Text("$")
          .font(.system(size: 11, weight: .bold, design: .monospaced))
          .foregroundStyle(accentColor.opacity(0.8))

        Text(message.content)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(isExpanded ? nil : 1)

        Spacer()

        // Status cluster
        HStack(spacing: 6) {
          if message.isInProgress {
            ProgressView()
              .controlSize(.mini)
          } else {
            if let duration = message.formattedDuration {
              Text(duration)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
            }

            if onSendToAI != nil, !message.isInProgress {
              Button {
                onSendToAI?(buildContextString())
              } label: {
                Image(systemName: "arrow.up.message")
                  .font(.system(size: 10))
                  .foregroundStyle(accentColor)
              }
              .buttonStyle(.plain)
              .help("Send output to AI as context")
            }

            if hasOutput {
              Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
          }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(accentColor.opacity(isHovering ? 0.12 : 0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(accentColor.opacity(0.15), lineWidth: 1)
      )
      .contentShape(Rectangle())
      .onTapGesture {
        if hasOutput {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            isExpanded.toggle()
          }
        }
      }
      .onHover { isHovering = $0 }

      // ━━━ Output panel ━━━
      if isExpanded, let output = message.sanitizedToolOutput, !output.isEmpty {
        let displayOutput = output.count > 3_000
          ? String(output.prefix(3_000)) + "\n\u{2026}"
          : output

        VStack(alignment: .leading, spacing: 0) {
          if hasError {
            HStack(spacing: 4) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
              Text("stderr")
                .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.orange.opacity(0.8))
            .padding(.bottom, 6)
          }

          ScrollView {
            Text(displayOutput)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(
                hasError
                  ? Color.orange.opacity(0.85)
                  : Color.textPrimary.opacity(0.85)
              )
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 200)
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.backgroundTertiary)
        )
        .padding(.top, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .onAppear {
      // Auto-expand to show output by default
      if hasOutput {
        isExpanded = true
      }
    }
  }

  private func buildContextString() -> String {
    let output = message.sanitizedToolOutput ?? ""
    return "$ \(message.content)\n\(output)"
  }
}

#Preview("Shell Cards") {
  VStack(alignment: .trailing, spacing: 20) {
    // Success with output
    ShellCard(
      message: TranscriptMessage(
        id: "shell-1",
        type: .shell,
        content: "git status",
        timestamp: Date(),
        toolName: nil,
        toolInput: nil,
        toolOutput: "On branch main\nChanges not staged for commit:\n  modified: ShellCard.swift\n  modified: WorkStreamEntry.swift",
        toolDuration: 0.032,
        inputTokens: nil,
        outputTokens: nil
      ),
      isExpanded: .constant(true),
      isHovering: .constant(false)
    )

    // In progress
    ShellCard(
      message: TranscriptMessage(
        id: "shell-2",
        type: .shell,
        content: "make build",
        timestamp: Date(),
        toolName: nil,
        toolInput: nil,
        toolDuration: nil,
        inputTokens: nil,
        outputTokens: nil,
        isInProgress: true
      ),
      isExpanded: .constant(false),
      isHovering: .constant(false)
    )
  }
  .padding(32)
  .frame(width: 500)
  .background(Color.backgroundPrimary)
}
