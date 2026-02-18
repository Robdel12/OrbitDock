//
//  TodoTaskCard.swift
//  OrbitDock
//
//  Shows todo/task management operations (TaskCreate, TaskUpdate, etc.)
//

import SwiftUI

struct TodoTaskCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  private var color: Color {
    Color(red: 0.65, green: 0.75, blue: 0.4)
  } // Lime/olive

  private var operation: TaskOperation {
    guard let name = message.toolName?.lowercased() else { return .unknown }
    switch name {
      case "taskcreate": return .create
      case "taskupdate": return .update
      case "tasklist": return .list
      case "taskget": return .get
      default: return .unknown
    }
  }

  private enum TaskOperation {
    case create, update, list, get, unknown

    var icon: String {
      switch self {
        case .create: "plus.circle.fill"
        case .update: "pencil.circle.fill"
        case .list: "list.bullet.clipboard.fill"
        case .get: "doc.text.fill"
        case .unknown: "checklist"
      }
    }

    var label: String {
      switch self {
        case .create: "Create Task"
        case .update: "Update Task"
        case .list: "List Tasks"
        case .get: "Get Task"
        case .unknown: "Task"
      }
    }

    var verb: String {
      switch self {
        case .create: "Creating..."
        case .update: "Updating..."
        case .list: "Loading..."
        case .get: "Fetching..."
        case .unknown: "Processing..."
      }
    }
  }

  private var subject: String {
    (message.toolInput?["subject"] as? String) ?? ""
  }

  private var taskId: String {
    (message.toolInput?["taskId"] as? String) ?? ""
  }

  private var status: String? {
    message.toolInput?["status"] as? String
  }

  private var output: String {
    message.toolOutput ?? ""
  }

  var body: some View {
    ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: message.toolInput != nil || !output.isEmpty) {
      header
    } content: {
      expandedContent
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: operation.icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(operation.label)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)

          // Status badge for updates
          if let status {
            statusBadge(status)
          }
        }

        // Show subject or task ID
        if !subject.isEmpty {
          Text(subject.count > 60 ? String(subject.prefix(60)) + "..." : subject)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if !taskId.isEmpty {
          Text("Task #\(taskId)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      if !message.isInProgress {
        ToolCardDuration(duration: message.formattedDuration)
      }

      if message.isInProgress {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.mini)
          Text(operation.verb)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
        }
      } else if message.toolInput != nil || !output.isEmpty {
        ToolCardExpandButton(isExpanded: $isExpanded)
      }
    }
  }

  @ViewBuilder
  private func statusBadge(_ status: String) -> some View {
    let (statusColor, statusIcon) = statusStyle(status)
    HStack(spacing: 4) {
      Image(systemName: statusIcon)
        .font(.system(size: 8, weight: .bold))
      Text(status)
        .font(.system(size: 9, weight: .bold))
    }
    .foregroundStyle(.white.opacity(0.9))
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(statusColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
  }

  private func statusStyle(_ status: String) -> (Color, String) {
    switch status.lowercased() {
      case "completed":
        (Color(red: 0.3, green: 0.75, blue: 0.45), "checkmark")
      case "in_progress":
        (Color(red: 0.4, green: 0.6, blue: 0.95), "arrow.right")
      case "pending":
        (Color(red: 0.6, green: 0.6, blue: 0.6), "clock")
      case "deleted":
        (Color(red: 0.9, green: 0.4, blue: 0.4), "trash")
      default:
        (Color.secondary, "questionmark")
    }
  }

  // MARK: - Expanded Content

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Input details
      if let input = message.toolInput, !input.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("DETAILS")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.quaternary)
            .tracking(0.5)

          VStack(alignment: .leading, spacing: 4) {
            if !subject.isEmpty {
              detailRow(label: "Subject", value: subject)
            }
            if !taskId.isEmpty {
              detailRow(label: "Task ID", value: taskId)
            }
            if let status {
              detailRow(label: "Status", value: status)
            }
            if let desc = input["description"] as? String, !desc.isEmpty {
              detailRow(label: "Description", value: desc)
            }
          }
        }
        .padding(12)
      }

      // Output
      if !output.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("RESULT")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.quaternary)
            .tracking(0.5)

          Text(output.count > 500 ? String(output.prefix(500)) + "..." : output)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.8))
            .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.backgroundTertiary.opacity(0.5))
      }
    }
  }

  private func detailRow(label: String, value: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(label)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
        .frame(width: 70, alignment: .trailing)

      Text(value.count > 150 ? String(value.prefix(150)) + "..." : value)
        .font(.system(size: 10))
        .foregroundStyle(.primary.opacity(0.8))
        .textSelection(.enabled)
    }
  }
}
