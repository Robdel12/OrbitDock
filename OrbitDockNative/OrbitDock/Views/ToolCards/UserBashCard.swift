import SwiftUI

struct UserBashCard: View {
  let bash: ParsedBashContent
  let timestamp: Date

  @State private var isExpanded = false
  @State private var isHovering = false

  private let terminalColor = Color.terminal

  private var showErrorState: Bool {
    !bash.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

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

      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: Spacing.md_) {
          Image(systemName: "terminal.fill")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(terminalColor)
            .frame(width: 16)

          if bash.hasInput {
            Text("$")
              .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
              .foregroundStyle(terminalColor.opacity(0.8))

            Text(bash.input)
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.9))
              .lineLimit(isExpanded ? nil : 1)
          } else {
            Text("Terminal output")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(.secondary)
          }

          Spacer()

          HStack(spacing: Spacing.sm_) {
            if showErrorState {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: TypeScale.mini))
                .foregroundStyle(Color.feedbackCaution)
            }

            if bash.hasOutput {
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
            .fill(terminalColor.opacity(isHovering ? 0.12 : 0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(terminalColor.opacity(0.15), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
          if bash.hasOutput {
            withAnimation(Motion.snappy) {
              isExpanded.toggle()
            }
          }
        }
        .onHover { isHovering = $0 }

        if isExpanded, bash.hasOutput {
          VStack(alignment: .leading, spacing: 0) {
            if !bash.stdout.isEmpty {
              outputSection(text: bash.stdout, isError: false)
            }

            if showErrorState {
              outputSection(text: bash.stderr, isError: true)
                .padding(.top, bash.stdout.isEmpty ? 0 : Spacing.sm)
            }
          }
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
    .onAppear {
      if !bash.hasInput, bash.hasOutput {
        isExpanded = true
      }
    }
  }

  @ViewBuilder
  private func outputSection(text: String, isError: Bool) -> some View {
    let displayText = text.count > 3_000 ? String(text.prefix(3_000)) + "\n..." : text

    VStack(alignment: .leading, spacing: Spacing.xs) {
      if isError {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 8))
          Text("stderr")
            .font(.system(size: TypeScale.mini, weight: .semibold))
        }
        .foregroundStyle(Color.feedbackCaution.opacity(0.8))
      }

      ScrollView {
        Text(displayText)
          .font(.system(size: TypeScale.meta, design: .monospaced))
          .foregroundStyle(isError ? Color.feedbackCaution.opacity(0.85) : .primary.opacity(0.85))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 200)
    }
  }
}

#Preview("Bash Cards") {
  VStack(alignment: .trailing, spacing: Spacing.section) {
    UserBashCard(
      bash: ParsedBashContent(
        input: "git status",
        stdout: "On branch main\nnothing to commit, working tree clean",
        stderr: ""
      ),
      timestamp: Date()
    )

    UserBashCard(
      bash: ParsedBashContent(
        input: "",
        stdout: "On branch main\nChanges not staged for commit:\n  modified: file.swift",
        stderr: ""
      ),
      timestamp: Date()
    )
  }
  .padding(Spacing.xxl)
  .frame(width: 600)
  .background(Color.backgroundPrimary)
}
