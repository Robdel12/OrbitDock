import SwiftUI

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

  var cleanDescription: String {
    if let quoteStart = summary.firstIndex(of: "\""),
       let quoteEnd = summary[summary.index(after: quoteStart)...].firstIndex(of: "\"")
    {
      return String(summary[summary.index(after: quoteStart) ..< quoteEnd])
    }
    return summary
  }

  var isBackgroundCommand: Bool {
    summary.lowercased().contains("background command")
  }
}

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
      HStack(spacing: Spacing.sm) {
        Text(ToolCardTimestamp.format(timestamp))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)

        Text("Background Task")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }

      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: Spacing.md_) {
          Image(systemName: notification.status.icon)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(taskColor)

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
