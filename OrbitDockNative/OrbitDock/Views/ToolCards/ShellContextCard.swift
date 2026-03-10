import SwiftUI

struct ShellContextCard: View {
  let context: ParsedShellContext
  let timestamp: Date

  private let shellColor = Color.shellAccent

  var body: some View {
    VStack(alignment: .trailing, spacing: Spacing.md_) {
      HStack(spacing: Spacing.sm) {
        Text(ToolCardTimestamp.format(timestamp))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)

        Text("You")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }

      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "terminal.fill")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(shellColor)

          Text("Shell Context")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          Text("\u{00B7}")
            .foregroundStyle(Color.textQuaternary)

          Text("\(context.commandCount) command\(context.commandCount == 1 ? "" : "s")")
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)

          Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(shellColor.opacity(OpacityTier.subtle))
        )

        ForEach(context.commands) { cmd in
          ShellContextCommandRow(command: cmd)
        }

        if !context.userPrompt.isEmpty {
          HStack(alignment: .top, spacing: 0) {
            Text(context.userPrompt)
              .font(.system(size: TypeScale.reading))
              .foregroundStyle(Color.textPrimary)
              .lineSpacing(5)
              .multilineTextAlignment(.trailing)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .trailing)
              .padding(.vertical, Spacing.sm)
              .padding(.horizontal, Spacing.md)

            Rectangle()
              .fill(Color.accent.opacity(OpacityTier.strong))
              .frame(width: EdgeBar.width)
          }
        }
      }
    }
  }
}

private struct ShellContextCommandRow: View {
  let command: ParsedShellContext.CommandBlock

  @State private var isExpanded = false
  @State private var isHovering = false

  private var accentColor: Color {
    command.hasError ? .feedbackWarning : .shellAccent
  }

  private var hasOutput: Bool {
    !command.output.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.md_) {
        if !command.command.isEmpty {
          Text("$")
            .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
            .foregroundStyle(accentColor.opacity(0.8))

          Text(command.command)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(isExpanded ? nil : 1)
        } else {
          Text("Output")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer()

        HStack(spacing: Spacing.sm_) {
          if let code = command.exitCode {
            Text("exit \(code)")
              .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
              .foregroundStyle(command.hasError ? Color.feedbackWarning : Color.textTertiary)
              .padding(.horizontal, Spacing.sm_)
              .padding(.vertical, Spacing.xxs)
              .background(
                Capsule()
                  .fill((command.hasError ? Color.feedbackWarning : Color.textTertiary).opacity(OpacityTier.subtle))
              )
          }

          if command.hasError {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.feedbackWarning)
          }

          if hasOutput {
            Image(systemName: "chevron.down")
              .font(.system(size: TypeScale.mini, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .rotationEffect(.degrees(isExpanded ? 0 : -90))
          }
        }
      }
      .padding(.horizontal, Spacing.lg_)
      .padding(.vertical, Spacing.md_)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(accentColor.opacity(isHovering ? OpacityTier.light : OpacityTier.subtle))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .strokeBorder(accentColor.opacity(0.15), lineWidth: 1)
      )
      .contentShape(Rectangle())
      .onTapGesture {
        if hasOutput {
          withAnimation(Motion.snappy) {
            isExpanded.toggle()
          }
        }
      }
      .onHover { isHovering = $0 }

      if isExpanded, hasOutput {
        let displayOutput = command.output.count > 3_000
          ? String(command.output.prefix(3_000)) + "\n\u{2026}"
          : command.output

        ScrollView {
          Text(displayOutput)
            .font(.system(size: TypeScale.meta, design: .monospaced))
            .foregroundStyle(
              command.hasError
                ? Color.feedbackWarning.opacity(0.85)
                : Color.textPrimary.opacity(0.85)
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .padding(Spacing.md)
        .background(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .fill(Color.backgroundTertiary)
        )
        .padding(.top, Spacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
}

#Preview("Shell Context") {
  VStack(alignment: .trailing, spacing: 30) {
    ShellContextCard(
      context: ParsedShellContext(
        commands: [
          .init(
            command: "git status",
            output: "On branch main\nChanges not staged for commit:\n  modified: ShellCard.swift",
            exitCode: 0
          ),
        ],
        userPrompt: "What files did I change?"
      ),
      timestamp: Date()
    )

    ShellContextCard(
      context: ParsedShellContext(
        commands: [
          .init(
            command: "npm test",
            output: "FAIL src/utils.test.ts\n  Expected: 42\n  Received: undefined",
            exitCode: 1
          ),
          .init(
            command: "cat src/utils.ts",
            output: "export function calculate() {\n  return undefined\n}",
            exitCode: 0
          ),
        ],
        userPrompt: "Fix the failing test"
      ),
      timestamp: Date()
    )

    ShellContextCard(
      context: ParsedShellContext(
        commands: [
          .init(
            command: "make build",
            output: "Build succeeded",
            exitCode: 0
          ),
        ],
        userPrompt: ""
      ),
      timestamp: Date()
    )
  }
  .padding(Spacing.xxl)
  .frame(width: 600)
  .background(Color.backgroundPrimary)
}
