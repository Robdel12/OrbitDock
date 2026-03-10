//
//  UserBashCard.swift
//  OrbitDock
//
//  Displays user-initiated bash commands (captured via <bash-input> tags)
//

import SwiftUI

// MARK: - System Context Card View

struct SystemContextCard: View {
  let context: ParsedSystemContext

  @State private var isExpanded = false
  @State private var isHovering = false

  private var lineCount: Int {
    context.body.components(separatedBy: "\n").count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header — always visible
      Button {
        withAnimation(Motion.snappy) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: context.icon)
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Text(context.label)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          if !isExpanded {
            Text("\u{00B7}")
              .foregroundStyle(Color.textQuaternary)
            Text("\(lineCount) lines")
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(isHovering ? 0.8 : 0.5))
        )
      }
      .buttonStyle(.plain)
      .onHover { isHovering = $0 }

      // Expanded content
      if isExpanded {
        ScrollView {
          MarkdownRepresentable(content: context.body, style: .thinking)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
        .padding(Spacing.md)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.3))
        )
        .padding(.top, Spacing.xs)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
}


// MARK: - User Bash Card View

struct UserBashCard: View {
  let bash: ParsedBashContent
  let timestamp: Date

  @State private var isExpanded = false
  @State private var isHovering = false

  private let terminalColor = Color.terminal

  /// Only show error state if stderr has actual content
  private var showErrorState: Bool {
    !bash.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: Spacing.md_) {
      // Meta line - right aligned
      HStack(spacing: Spacing.sm) {
        Text(formatTime(timestamp))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)

        Text("You")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }

      // Bash card - right aligned
      VStack(alignment: .leading, spacing: 0) {
        // Header
        HStack(spacing: Spacing.md_) {
          // Terminal icon
          Image(systemName: "terminal.fill")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(terminalColor)
            .frame(width: 16)

          if bash.hasInput {
            // Command with prompt
            Text("$")
              .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
              .foregroundStyle(terminalColor.opacity(0.8))

            Text(bash.input)
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.9))
              .lineLimit(isExpanded ? nil : 1)
          } else {
            // No input - show label
            Text("Terminal output")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(.secondary)
          }

          Spacer()

          // Status indicators
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

        // Output panel
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
      // Auto-expand if there's no input command
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

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  private func formatTime(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }
}

// MARK: - User Slash Command Card View

struct UserSlashCommandCard: View {
  let command: ParsedSlashCommand
  let timestamp: Date

  @State private var isHovering = false

  private let commandColor = Color.toolSkill // Pink/magenta for skills/commands

  private var hasCommand: Bool {
    !command.name.isEmpty
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: Spacing.md_) {
      // Meta line
      HStack(spacing: Spacing.sm) {
        Text(formatTime(timestamp))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)

        Text("You")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }

      // Command card (only show if there's a command name)
      if hasCommand {
        HStack(spacing: Spacing.md_) {
          // Slash icon
          Image(systemName: "slash.circle.fill")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(commandColor)

          // Command name
          Text(command.name)
            .font(.system(size: TypeScale.code, weight: .semibold, design: .monospaced))
            .foregroundStyle(commandColor)

          // Args (if present)
          if command.hasArgs {
            Text(command.args)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(.primary.opacity(0.85))
              .lineLimit(1)
          }

          Spacer()
        }
        .padding(.horizontal, Spacing.lg_)
        .padding(.vertical, Spacing.md_)
        .background(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(commandColor.opacity(isHovering ? 0.12 : 0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(commandColor.opacity(0.15), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
      }

      // Output (if present)
      if command.hasOutput {
        HStack(spacing: Spacing.sm) {
          Image(systemName: hasCommand ? "arrow.turn.down.right" : "text.bubble")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(hasCommand ? Color.textTertiary : commandColor)

          Text(command.stdout)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(hasCommand ? Color.textSecondary : Color.textPrimary)
            .lineLimit(3)

          Spacer()
        }
        .padding(.horizontal, Spacing.lg_)
        .padding(.vertical, hasCommand ? Spacing.sm : Spacing.md_)
        .background(
          RoundedRectangle(cornerRadius: hasCommand ? Radius.ml : Radius.lg, style: .continuous)
            .fill(hasCommand ? Color.backgroundTertiary : commandColor.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: hasCommand ? Radius.ml : Radius.lg, style: .continuous)
            .strokeBorder(hasCommand ? Color.clear : commandColor.opacity(0.15), lineWidth: 1)
        )
      }
    }
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  private func formatTime(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }
}

// MARK: - System Caveat View (subtle notice)

struct SystemCaveatView: View {
  let caveat: ParsedSystemCaveat

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "info.circle")
        .font(.system(size: TypeScale.micro, weight: .medium))

      Text("System notice")
        .font(.system(size: TypeScale.meta, weight: .medium))
    }
    .foregroundStyle(Color.textQuaternary)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
  }
}

// MARK: - Parsed Task Notification

struct ParsedTaskNotification {
  let taskId: String
  let outputFile: String
  let status: TaskStatus
  let summary: String

  enum TaskStatus: String {
    case completed
    case running
    case failed

    var icon: String {
      switch self {
        case .completed: "checkmark.circle.fill"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed: "xmark.circle.fill"
      }
    }

    var color: Color {
      switch self {
        case .completed: .feedbackPositive
        case .running: .accent
        case .failed: .feedbackCaution
      }
    }

    var label: String {
      switch self {
        case .completed: "Completed"
        case .running: "Running"
        case .failed: "Failed"
      }
    }
  }

  /// Parse content containing <task-notification> tags
  static func parse(from content: String) -> ParsedTaskNotification? {
    guard content.contains("<task-notification>") else { return nil }

    let taskId = extractTag("task-id", from: content)
    let outputFile = extractTag("output-file", from: content)
    let statusStr = extractTag("status", from: content)
    let summary = extractTag("summary", from: content)

    guard !taskId.isEmpty else { return nil }

    let status: TaskStatus = switch statusStr.lowercased() {
      case "completed": .completed
      case "running": .running
      case "failed": .failed
      default: .completed
    }

    return ParsedTaskNotification(
      taskId: taskId,
      outputFile: outputFile,
      status: status,
      summary: summary
    )
  }

  /// Extract a cleaner description from the summary
  var cleanDescription: String {
    // Extract what's in quotes if present (e.g., "Preview presentation in browser")
    if let quoteStart = summary.firstIndex(of: "\""),
       let quoteEnd = summary[summary.index(after: quoteStart)...].firstIndex(of: "\"")
    {
      return String(summary[summary.index(after: quoteStart) ..< quoteEnd])
    }
    return summary
  }

  /// Check if this is a background command vs agent task
  var isBackgroundCommand: Bool {
    summary.lowercased().contains("background command")
  }
}

// Shared parsing helpers live in UserBashParsing.swift so the card views stay focused on presentation.

// MARK: - Shell Context Card View

struct ShellContextCard: View {
  let context: ParsedShellContext
  let timestamp: Date

  private let shellColor = Color.shellAccent

  var body: some View {
    VStack(alignment: .trailing, spacing: Spacing.md_) {
      // Meta line
      HStack(spacing: Spacing.sm) {
        Text(formatTime(timestamp))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)

        Text("You")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }

      // Shell context card
      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Header pill
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

        // Command rows
        ForEach(context.commands) { cmd in
          ShellContextCommandRow(command: cmd)
        }

        // User prompt (if present)
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

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  private func formatTime(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }
}

// MARK: - Shell Context Command Row (per-command card)

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
      // Command header
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
          // Exit code badge
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

      // Expandable output panel
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

// MARK: - Task Notification Card View

struct TaskNotificationCard: View {
  let notification: ParsedTaskNotification
  let timestamp: Date

  @State private var isExpanded = false
  @State private var isHovering = false
  @State private var outputContent: String?
  @State private var isLoadingOutput = false

  private var taskColor: Color {
    notification.status.color
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: Spacing.md_) {
      // Meta line
      HStack(spacing: Spacing.sm) {
        Text(formatTime(timestamp))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)

        Text("Background Task")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }

      // Task notification card
      VStack(alignment: .leading, spacing: 0) {
        // Header
        HStack(spacing: Spacing.md_) {
          // Status icon
          Image(systemName: notification.status.icon)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(taskColor)

          // Task description
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(notification.cleanDescription)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(.primary.opacity(0.9))
              .lineLimit(isExpanded ? nil : 1)

            HStack(spacing: Spacing.sm_) {
              Text(notification.status.label)
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(taskColor)

              Text("•")
                .font(.system(size: 8))
                .foregroundStyle(Color.textQuaternary)

              Text(notification.taskId)
                .font(.system(size: TypeScale.micro, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
            }
          }

          Spacer()

          // Expand indicator (if output file exists)
          if !notification.outputFile.isEmpty {
            Image(systemName: "chevron.down")
              .font(.system(size: TypeScale.mini, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .rotationEffect(.degrees(isExpanded ? 0 : -90))
          }
        }
        .padding(.horizontal, Spacing.lg_)
        .padding(.vertical, Spacing.md_)
        .background(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(taskColor.opacity(isHovering ? 0.12 : 0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(taskColor.opacity(0.15), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
          if !notification.outputFile.isEmpty {
            withAnimation(Motion.snappy) {
              isExpanded.toggle()
            }
            if isExpanded, outputContent == nil {
              loadOutput()
            }
          }
        }
        .onHover { isHovering = $0 }

        // Output panel
        if isExpanded, !notification.outputFile.isEmpty {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            if isLoadingOutput {
              HStack(spacing: Spacing.sm) {
                ProgressView()
                  .controlSize(.small)
                Text("Loading output...")
                  .font(.system(size: TypeScale.meta))
                  .foregroundStyle(.secondary)
              }
              .padding(.vertical, Spacing.sm)
            } else if let output = outputContent {
              ScrollView {
                Text(output.count > 5_000 ? String(output.prefix(5_000)) + "\n..." : output)
                  .font(.system(size: TypeScale.meta, design: .monospaced))
                  .foregroundStyle(.primary.opacity(0.85))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(maxHeight: 250)
            } else {
              Text("Output file not found")
                .font(.system(size: TypeScale.meta))
                .foregroundStyle(Color.textTertiary)
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
  }

  private func loadOutput() {
    guard !notification.outputFile.isEmpty else { return }

    isLoadingOutput = true

    DispatchQueue.global(qos: .userInitiated).async {
      let content = try? String(contentsOfFile: notification.outputFile, encoding: .utf8)

      DispatchQueue.main.async {
        outputContent = content
        isLoadingOutput = false
      }
    }
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  private func formatTime(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }
}

// MARK: - Previews

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

#Preview("Slash Commands") {
  VStack(alignment: .trailing, spacing: Spacing.section) {
    UserSlashCommandCard(
      command: ParsedSlashCommand(
        name: "/rename",
        message: "rename",
        args: "Design system and colors",
        stdout: ""
      ),
      timestamp: Date()
    )

    UserSlashCommandCard(
      command: ParsedSlashCommand(
        name: "/commit",
        message: "commit",
        args: "",
        stdout: "Created commit abc123"
      ),
      timestamp: Date()
    )

    UserSlashCommandCard(
      command: ParsedSlashCommand(
        name: "",
        message: "",
        args: "",
        stdout: "Session renamed to: Design system and colors"
      ),
      timestamp: Date()
    )
  }
  .padding(Spacing.xxl)
  .frame(width: 600)
  .background(Color.backgroundPrimary)
}

#Preview("Task Notifications") {
  VStack(alignment: .trailing, spacing: Spacing.section) {
    TaskNotificationCard(
      notification: ParsedTaskNotification(
        taskId: "b1b8cae",
        outputFile: "/tmp/example.output",
        status: .completed,
        summary: "Background command \"Preview presentation in browser\" completed (exit code 0)"
      ),
      timestamp: Date()
    )

    TaskNotificationCard(
      notification: ParsedTaskNotification(
        taskId: "c2a9def",
        outputFile: "",
        status: .running,
        summary: "Background command \"Run tests\" is running"
      ),
      timestamp: Date()
    )

    TaskNotificationCard(
      notification: ParsedTaskNotification(
        taskId: "d3b0abc",
        outputFile: "/tmp/failed.output",
        status: .failed,
        summary: "Background command \"Build project\" failed (exit code 1)"
      ),
      timestamp: Date()
    )
  }
  .padding(Spacing.xxl)
  .frame(width: 600)
  .background(Color.backgroundPrimary)
}

#Preview("Shell Context") {
  VStack(alignment: .trailing, spacing: 30) {
    // Single command + user prompt
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

    // Multiple commands with error
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

    // Shell-only (no user prompt)
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
