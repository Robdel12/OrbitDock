//
//  UserBashCard.swift
//  OrbitDock
//
//  Displays user-initiated bash commands (captured via <bash-input> tags)
//

import SwiftUI

// MARK: - Tag Extraction Helper

private func extractTag(_ tag: String, from content: String) -> String {
  let openTag = "<\(tag)>"
  let closeTag = "</\(tag)>"

  guard let startRange = content.range(of: openTag),
        let endRange = content.range(of: closeTag, range: startRange.upperBound ..< content.endIndex)
  else {
    return ""
  }

  return String(content[startRange.upperBound ..< endRange.lowerBound])
}

// MARK: - System Context (AGENTS.md, skills, developer instructions)

struct ParsedSystemContext {
  enum ContextKind {
    case agentsMd(directory: String)
    case skill(name: String, path: String)
    case legacyInstructions
    case systemReminder
  }

  let kind: ContextKind
  let body: String // The instruction content

  var label: String {
    switch kind {
      case let .agentsMd(dir):
        let short = (dir as NSString).lastPathComponent
        return "AGENTS.md \u{00B7} \(short)"
      case let .skill(name, _):
        return "Skill \u{00B7} \(name)"
      case .legacyInstructions:
        return "Instructions"
      case .systemReminder:
        return "System"
    }
  }

  var icon: String {
    switch kind {
      case .agentsMd: "doc.text"
      case .skill: "wand.and.stars"
      case .legacyInstructions: "gearshape"
      case .systemReminder: "info.circle"
    }
  }

  /// Parse a user message for system-injected context
  static func parse(from content: String) -> ParsedSystemContext? {
    // AGENTS.md: starts with "# AGENTS.md instructions for {directory}"
    if content.hasPrefix("# AGENTS.md instructions for ") {
      let firstLine = content.components(separatedBy: "\n").first ?? ""
      let directory = String(firstLine.dropFirst("# AGENTS.md instructions for ".count))
      let body = extractTag("INSTRUCTIONS", from: content)
      return ParsedSystemContext(
        kind: .agentsMd(directory: directory),
        body: body.isEmpty ? content : body
      )
    }

    // Skill instructions: starts with "<skill>"
    if content.hasPrefix("<skill") {
      let name = extractTag("name", from: content)
      let path = extractTag("path", from: content)
      // Body is everything after the closing </path> tag or the skill content
      let body = content
        .replacingOccurrences(of: "<skill>", with: "")
        .replacingOccurrences(of: "</skill>", with: "")
        .replacingOccurrences(of: "<name>\(name)</name>", with: "")
        .replacingOccurrences(of: "<path>\(path)</path>", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return ParsedSystemContext(
        kind: .skill(name: name.isEmpty ? "unknown" : name, path: path),
        body: body
      )
    }

    // Legacy user_instructions tag
    if content.hasPrefix("<user_instructions>") {
      let body = extractTag("user_instructions", from: content)
      return ParsedSystemContext(
        kind: .legacyInstructions,
        body: body.isEmpty ? content : body
      )
    }

    // System reminder (sometimes injected as user message)
    if content.hasPrefix("<system-reminder>") {
      let body = extractTag("system-reminder", from: content)
      return ParsedSystemContext(
        kind: .systemReminder,
        body: body.isEmpty ? content : body
      )
    }

    return nil
  }
}

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
        withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: context.icon)
            .font(.system(size: 11, weight: .semibold))
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
            .font(.system(size: 9, weight: .semibold))
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
          ThinkingMarkdownView(content: context.body)
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

// MARK: - System Caveat (should be hidden or shown subtly)

struct ParsedSystemCaveat {
  let message: String

  /// Check if content is a local-command-caveat system message
  static func parse(from content: String) -> ParsedSystemCaveat? {
    guard content.contains("<local-command-caveat>") else { return nil }

    let message = extractTag("local-command-caveat", from: content)
    guard !message.isEmpty else { return nil }

    return ParsedSystemCaveat(message: message)
  }
}

// MARK: - Parsed Bash Content

struct ParsedBashContent {
  let input: String
  let stdout: String
  let stderr: String

  var hasOutput: Bool {
    !stdout.isEmpty || !stderr.isEmpty
  }

  var hasError: Bool {
    !stderr.isEmpty
  }

  var hasInput: Bool {
    !input.isEmpty
  }

  /// Parse content containing <bash-input>, <bash-stdout>, <bash-stderr> tags
  /// Handles cases where only some tags are present
  static func parse(from content: String) -> ParsedBashContent? {
    // Must contain at least one bash tag
    let hasBashInput = content.contains("<bash-input>")
    let hasBashStdout = content.contains("<bash-stdout>")
    let hasBashStderr = content.contains("<bash-stderr>")

    guard hasBashInput || hasBashStdout || hasBashStderr else { return nil }

    let input = extractTag("bash-input", from: content).strippingShellWrapperPrefix()
    let stdout = extractTag("bash-stdout", from: content)
    let stderr = extractTag("bash-stderr", from: content)

    // Must have at least some content
    guard !input.isEmpty || !stdout.isEmpty || !stderr.isEmpty else { return nil }

    return ParsedBashContent(input: input, stdout: stdout, stderr: stderr)
  }
}

// MARK: - Parsed Slash Command

struct ParsedSlashCommand {
  let name: String // e.g., "/rename"
  let message: String // e.g., "rename"
  let args: String // e.g., "Design system and colors"
  let stdout: String // Output from local-command-stdout

  var hasArgs: Bool {
    !args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var hasOutput: Bool {
    !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Parse content containing <command-name>, <command-message>, <command-args>, <local-command-stdout> tags
  static func parse(from content: String) -> ParsedSlashCommand? {
    // Check for slash command tags
    let hasCommandName = content.contains("<command-name>")
    let hasLocalStdout = content.contains("<local-command-stdout>")

    guard hasCommandName || hasLocalStdout else { return nil }

    let name = extractTag("command-name", from: content)
    let message = extractTag("command-message", from: content)
    let args = extractTag("command-args", from: content)
    let stdout = extractTag("local-command-stdout", from: content)

    // Must have at least a command name or output
    guard !name.isEmpty || !stdout.isEmpty else { return nil }

    return ParsedSlashCommand(name: name, message: message, args: args, stdout: stdout)
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
    VStack(alignment: .trailing, spacing: 10) {
      // Meta line - right aligned
      HStack(spacing: 8) {
        Text(formatTime(timestamp))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.quaternary)

        Text("You")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.tertiary)
      }

      // Bash card - right aligned
      VStack(alignment: .leading, spacing: 0) {
        // Header
        HStack(spacing: 10) {
          // Terminal icon
          Image(systemName: "terminal.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(terminalColor)
            .frame(width: 16)

          if bash.hasInput {
            // Command with prompt
            Text("$")
              .font(.system(size: 11, weight: .bold, design: .monospaced))
              .foregroundStyle(terminalColor.opacity(0.8))

            Text(bash.input)
              .font(.system(size: 12, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.9))
              .lineLimit(isExpanded ? nil : 1)
          } else {
            // No input - show label
            Text("Terminal output")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.secondary)
          }

          Spacer()

          // Status indicators
          HStack(spacing: 6) {
            if showErrorState {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.statusWaiting)
            }

            if bash.hasOutput {
              Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(terminalColor.opacity(isHovering ? 0.12 : 0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(terminalColor.opacity(0.15), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
          if bash.hasOutput {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
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
                .padding(.top, bash.stdout.isEmpty ? 0 : 8)
            }
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

    VStack(alignment: .leading, spacing: 4) {
      if isError {
        HStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 8))
          Text("stderr")
            .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Color.statusWaiting.opacity(0.8))
      }

      ScrollView {
        Text(displayText)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(isError ? Color.statusWaiting.opacity(0.85) : .primary.opacity(0.85))
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
    VStack(alignment: .trailing, spacing: 10) {
      // Meta line
      HStack(spacing: 8) {
        Text(formatTime(timestamp))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.quaternary)

        Text("You")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.tertiary)
      }

      // Command card (only show if there's a command name)
      if hasCommand {
        HStack(spacing: 10) {
          // Slash icon
          Image(systemName: "slash.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(commandColor)

          // Command name
          Text(command.name)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(commandColor)

          // Args (if present)
          if command.hasArgs {
            Text(command.args)
              .font(.system(size: 12))
              .foregroundStyle(.primary.opacity(0.85))
              .lineLimit(1)
          }

          Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(commandColor.opacity(isHovering ? 0.12 : 0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(commandColor.opacity(0.15), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
      }

      // Output (if present)
      if command.hasOutput {
        HStack(spacing: 8) {
          Image(systemName: hasCommand ? "arrow.turn.down.right" : "text.bubble")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(hasCommand ? Color.textTertiary : commandColor)

          Text(command.stdout)
            .font(.system(size: 12))
            .foregroundStyle(hasCommand ? Color.textSecondary : Color.textPrimary)
            .lineLimit(3)

          Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, hasCommand ? 8 : 10)
        .background(
          RoundedRectangle(cornerRadius: hasCommand ? 8 : 10, style: .continuous)
            .fill(hasCommand ? Color.backgroundTertiary : commandColor.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: hasCommand ? 8 : 10, style: .continuous)
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
    HStack(spacing: 8) {
      Image(systemName: "info.circle")
        .font(.system(size: 10, weight: .medium))

      Text("System notice")
        .font(.system(size: 11, weight: .medium))
    }
    .foregroundStyle(.quaternary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
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
        case .completed: .statusSuccess
        case .running: .accent
        case .failed: .statusWaiting
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
    VStack(alignment: .trailing, spacing: 10) {
      // Meta line
      HStack(spacing: 8) {
        Text(formatTime(timestamp))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.quaternary)

        Text("Background Task")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.tertiary)
      }

      // Task notification card
      VStack(alignment: .leading, spacing: 0) {
        // Header
        HStack(spacing: 10) {
          // Status icon
          Image(systemName: notification.status.icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(taskColor)

          // Task description
          VStack(alignment: .leading, spacing: 2) {
            Text(notification.cleanDescription)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.primary.opacity(0.9))
              .lineLimit(isExpanded ? nil : 1)

            HStack(spacing: 6) {
              Text(notification.status.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(taskColor)

              Text("•")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)

              Text(notification.taskId)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
          }

          Spacer()

          // Expand indicator (if output file exists)
          if !notification.outputFile.isEmpty {
            Image(systemName: "chevron.down")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.tertiary)
              .rotationEffect(.degrees(isExpanded ? 0 : -90))
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(taskColor.opacity(isHovering ? 0.12 : 0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(taskColor.opacity(0.15), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
          if !notification.outputFile.isEmpty {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
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
          VStack(alignment: .leading, spacing: 8) {
            if isLoadingOutput {
              HStack(spacing: 8) {
                ProgressView()
                  .controlSize(.small)
                Text("Loading output...")
                  .font(.system(size: 11))
                  .foregroundStyle(.secondary)
              }
              .padding(.vertical, 8)
            } else if let output = outputContent {
              ScrollView {
                Text(output.count > 5_000 ? String(output.prefix(5_000)) + "\n..." : output)
                  .font(.system(size: 11, design: .monospaced))
                  .foregroundStyle(.primary.opacity(0.85))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(maxHeight: 250)
            } else {
              Text("Output file not found")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
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
  VStack(alignment: .trailing, spacing: 20) {
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
  .padding(32)
  .frame(width: 600)
  .background(Color.backgroundPrimary)
}

#Preview("Slash Commands") {
  VStack(alignment: .trailing, spacing: 20) {
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
  .padding(32)
  .frame(width: 600)
  .background(Color.backgroundPrimary)
}

#Preview("Task Notifications") {
  VStack(alignment: .trailing, spacing: 20) {
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
  .padding(32)
  .frame(width: 600)
  .background(Color.backgroundPrimary)
}
