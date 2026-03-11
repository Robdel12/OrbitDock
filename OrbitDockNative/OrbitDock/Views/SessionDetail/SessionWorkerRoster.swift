import Foundation
import SwiftUI

struct SessionWorkerRosterPresentation {
  struct Worker: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let statusLabel: String
    let statusColor: Color
    let isActive: Bool
    let iconName: String
  }

  let title: String
  let workers: [Worker]
}

struct SessionWorkerDetailPresentation {
  struct DetailLine: Identifiable {
    let id: String
    let label: String
    let value: String
  }

  struct ToolActivity: Identifiable {
    let id: String
    let iconName: String
    let toolName: String
    let summary: String
    let statusLabel: String
    let statusColor: Color
  }

  let id: String
  let title: String
  let subtitle: String?
  let statusLabel: String
  let statusColor: Color
  let iconName: String
  let isActive: Bool
  let statusNarrative: String
  let reportPreview: String?
  let detailLines: [DetailLine]
  let tools: [ToolActivity]
}

@MainActor
enum SessionWorkerRosterPlanner {
  static func presentation(subagents: [ServerSubagentInfo]) -> SessionWorkerRosterPresentation? {
    let workers = subagents
      .sorted(by: workerSort)
      .map(workerPresentation)

    guard !workers.isEmpty else { return nil }

    let activeCount = workers.filter(\.isActive).count
    let title = activeCount > 0 ? "Workers · \(activeCount) active" : "Workers"
    return SessionWorkerRosterPresentation(title: title, workers: workers)
  }

  static func preferredSelectedWorkerID(
    currentSelectionID: String?,
    subagents: [ServerSubagentInfo]
  ) -> String? {
    let sorted = subagents.sorted(by: workerSort)
    guard !sorted.isEmpty else { return nil }

    if let currentSelectionID,
       sorted.contains(where: { $0.id == currentSelectionID })
    {
      return currentSelectionID
    }

    return sorted.first?.id
  }

  static func detailPresentation(
    subagents: [ServerSubagentInfo],
    selectedWorkerID: String?,
    toolsByWorker: [String: [ServerSubagentTool]],
    timelineMessages: [TranscriptMessage]
  ) -> SessionWorkerDetailPresentation? {
    guard let selectedWorkerID,
          let subagent = subagents.first(where: { $0.id == selectedWorkerID })
    else {
      return nil
    }

    let status = statusPresentation(subagent.status)
    let visuals = visuals(for: subagent.agentType)
    let tools = (toolsByWorker[subagent.id] ?? []).prefix(8).map(toolPresentation)

    return SessionWorkerDetailPresentation(
      id: subagent.id,
      title: subagent.label ?? visuals.label,
      subtitle: workerSubtitle(subagent),
      statusLabel: status.label,
      statusColor: status.color,
      iconName: visuals.iconName,
      isActive: status.isActive,
      statusNarrative: status.narrative,
      reportPreview: latestReportPreview(
        for: subagent.id,
        timelineMessages: timelineMessages
      ),
      detailLines: detailLines(for: subagent),
      tools: Array(tools)
    )
  }

  private static func workerSort(lhs: ServerSubagentInfo, rhs: ServerSubagentInfo) -> Bool {
    let lhsActive = isActive(lhs.status)
    let rhsActive = isActive(rhs.status)
    if lhsActive != rhsActive {
      return lhsActive && !rhsActive
    }

    return sortDate(for: lhs) > sortDate(for: rhs)
  }

  private static func workerPresentation(subagent: ServerSubagentInfo) -> SessionWorkerRosterPresentation.Worker {
    let status = statusPresentation(subagent.status)
    let visuals = visuals(for: subagent.agentType)

    return SessionWorkerRosterPresentation.Worker(
      id: subagent.id,
      title: subagent.label ?? visuals.label,
      subtitle: workerSubtitle(subagent),
      statusLabel: status.label,
      statusColor: status.color,
      isActive: status.isActive,
      iconName: visuals.iconName
    )
  }

  private static func detailLines(for subagent: ServerSubagentInfo) -> [SessionWorkerDetailPresentation.DetailLine] {
    [
      detailLine(id: "type", label: "Role", value: visuals(for: subagent.agentType).label),
      detailLine(id: "provider", label: "Provider", value: subagent.provider?.rawValue.capitalized),
      detailLine(id: "model", label: "Model", value: subagent.model),
      detailLine(id: "started", label: "Started", value: formattedDate(subagent.startedAt)),
      detailLine(id: "last", label: "Last active", value: formattedDate(subagent.lastActivityAt)),
      detailLine(id: "ended", label: "Ended", value: formattedDate(subagent.endedAt)),
      detailLine(id: "parent", label: "Parent worker", value: subagent.parentSubagentId),
    ]
    .compactMap { $0 }
  }

  private static func detailLine(
    id: String,
    label: String,
    value: String?
  ) -> SessionWorkerDetailPresentation.DetailLine? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
      return nil
    }
    return .init(id: id, label: label, value: value)
  }

  private static func workerSubtitle(_ subagent: ServerSubagentInfo) -> String? {
    [
      subagent.taskSummary,
      subagent.resultSummary,
      subagent.errorSummary,
    ]
    .compactMap {
      $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    .first
  }

  private static func statusPresentation(_ status: ServerSubagentStatus?) -> (label: String, color: Color, isActive: Bool, narrative: String) {
    switch status {
    case .pending:
      return ("Pending", .feedbackCaution, true, "Queued up and waiting for a turn.")
    case .running:
      return ("Running", .statusWorking, true, "Actively working through its assignment.")
    case .completed:
      return ("Complete", .feedbackPositive, false, "Finished cleanly and reported back.")
    case .failed:
      return ("Failed", .feedbackNegative, false, "Stopped with an error and may need attention.")
    case .cancelled:
      return ("Cancelled", .feedbackWarning, false, "Cancelled before it could finish.")
    case .shutdown:
      return ("Stopped", .textSecondary, false, "Closed down after the run ended.")
    case .notFound:
      return ("Unavailable", .feedbackNegative, false, "Could not be found when OrbitDock checked in.")
    case nil:
      return ("Known", .textSecondary, false, "Known to the session, but still waiting on more detail.")
    }
  }

  private static func isActive(_ status: ServerSubagentStatus?) -> Bool {
    status == .pending || status == .running
  }

  private static func sortDate(for subagent: ServerSubagentInfo) -> Date {
    parseDate(subagent.lastActivityAt)
      ?? parseDate(subagent.startedAt)
      ?? .distantPast
  }

  private static func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    return ISO8601DateFormatter().date(from: value)
  }

  private static func formattedDate(_ value: String?) -> String? {
    guard let date = parseDate(value) else { return nil }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func visuals(for agentType: String) -> (label: String, iconName: String) {
    switch agentType.lowercased() {
    case "explore", "explorer":
      return ("Explorer", "binoculars.fill")
    case "plan", "planner":
      return ("Planner", "map.fill")
    case "worker":
      return ("Worker", "person.crop.circle.badge.gearshape.fill")
    case "reviewer":
      return ("Reviewer", "checklist.checked")
    case "researcher":
      return ("Researcher", "magnifyingglass.circle.fill")
    case "general-purpose":
      return ("General", "cpu.fill")
    default:
      return (agentType.replacingOccurrences(of: "-", with: " ").capitalized, "person.crop.circle.fill")
    }
  }

  private static func toolPresentation(_ tool: ServerSubagentTool) -> SessionWorkerDetailPresentation.ToolActivity {
    let statusColor: Color = tool.isInProgress ? .statusWorking : .feedbackPositive
    return .init(
      id: tool.id,
      iconName: ToolCardStyle.icon(for: tool.toolName),
      toolName: tool.toolName,
      summary: tool.summary,
      statusLabel: tool.isInProgress ? "Running" : "Done",
      statusColor: statusColor
    )
  }

  private static func latestReportPreview(
    for subagentID: String,
    timelineMessages: [TranscriptMessage]
  ) -> String? {
    for message in timelineMessages.reversed() {
      guard message.toolName?.lowercased() == "task" else { continue }

      if let explicitSubagentID = message.toolInput?["subagent_id"] as? String,
         explicitSubagentID == subagentID,
         let preview = message.sanitizedToolOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      {
        return cleanedReportPreview(preview)
      }

      if let receiverThreadIDs = message.toolInput?["receiver_thread_ids"] as? [String],
         receiverThreadIDs.contains(subagentID),
         let preview = message.sanitizedToolOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      {
        return cleanedReportPreview(preview)
      }
    }

    return nil
  }

  private static func cleanedReportPreview(_ preview: String) -> String {
    if let range = preview.range(of: "Completed(Some(\"") {
      let remainder = preview[range.upperBound...]
      if let closingRange = remainder.range(of: "\"))") {
        return unescapedReportText(String(remainder[..<closingRange.lowerBound]))
      }
    }

    let filteredLines = preview
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter {
        !$0.isEmpty &&
        !$0.hasPrefix("sender:") &&
        !$0.contains("Completed(Some(")
      }

    if !filteredLines.isEmpty {
      return filteredLines.joined(separator: "\n")
    }

    return unescapedReportText(preview)
  }

  private static func unescapedReportText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\\"", with: "\"")
      .replacingOccurrences(of: "\\'", with: "'")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct SessionWorkerRosterView: View {
  let presentation: SessionWorkerRosterPresentation
  let selectedWorkerID: String?
  let onSelectWorker: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "person.3.sequence.fill")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)
          .frame(width: 28, height: 28)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Workers")
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(presentation.title)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textSecondary)
        }
      }

      VStack(spacing: Spacing.sm) {
        ForEach(presentation.workers) { worker in
          workerRow(worker)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.md)
    .padding(.bottom, Spacing.sm)
  }

  private func workerRow(_ worker: SessionWorkerRosterPresentation.Worker) -> some View {
    let isSelected = worker.id == selectedWorkerID

    return Button {
      onSelectWorker(worker.id)
    } label: {
      HStack(spacing: Spacing.sm) {
        Circle()
          .fill(worker.statusColor)
          .frame(width: 8, height: 8)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(spacing: Spacing.xs) {
            Text(worker.title)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
              .lineLimit(1)

            Text(worker.statusLabel)
              .font(.system(size: TypeScale.mini, weight: .medium))
              .foregroundStyle(worker.statusColor)
          }

          if let subtitle = worker.subtitle {
            Text(subtitle)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(2)
          }
        }

        Spacer(minLength: 0)

        Image(systemName: isSelected ? "chevron.right.circle.fill" : worker.iconName)
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(isSelected ? Color.accent : Color.textTertiary)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(isSelected ? Color.surfaceSelected : Color.backgroundSecondary.opacity(0.72))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .stroke(isSelected ? Color.accent.opacity(0.35) : Color.panelBorder.opacity(0.45), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}

struct SessionWorkerCompanionPanel: View {
  let rosterPresentation: SessionWorkerRosterPresentation
  let detailPresentation: SessionWorkerDetailPresentation?
  let selectedWorkerID: String?
  let onSelectWorker: (String) -> Void

  var body: some View {
    VStack(spacing: 0) {
      SessionWorkerRosterView(
        presentation: rosterPresentation,
        selectedWorkerID: selectedWorkerID,
        onSelectWorker: onSelectWorker
      )

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.6))

      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if let detailPresentation {
            SessionWorkerDetailView(presentation: detailPresentation)
          } else {
            SessionWorkerEmptyState()
          }
        }
        .padding(.vertical, Spacing.md)
      }
    }
  }
}

struct SessionWorkerDetailView: View {
  let presentation: SessionWorkerDetailPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: presentation.iconName)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(presentation.statusColor)
          .frame(width: 28, height: 28)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(presentation.title)
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(presentation.statusLabel)
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(presentation.statusColor)

          if let subtitle = presentation.subtitle {
            Text(subtitle)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          Text(presentation.statusNarrative)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if !presentation.detailLines.isEmpty {
        workerFactsGrid
      }

      if let reportPreview = presentation.reportPreview {
        infoCard(
          title: "Worker Report",
          icon: "text.bubble.fill",
          accent: presentation.statusColor
        ) {
          Text(reportPreview)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      infoCard(
        title: "Recent Activity",
        icon: "rectangle.stack.fill",
        accent: Color.accent
      ) {
        if presentation.tools.isEmpty {
          Text(presentation.isActive ? "Activity will appear here as the worker reports tool calls." : "This worker finished without captured tool rows yet.")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textSecondary)
        } else {
          VStack(spacing: Spacing.sm) {
            ForEach(presentation.tools) { tool in
              HStack(spacing: Spacing.sm) {
                Image(systemName: tool.iconName)
                  .font(.system(size: TypeScale.mini, weight: .medium))
                  .foregroundStyle(ToolCardStyle.color(for: tool.toolName))
                  .frame(width: 14)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text(tool.toolName)
                    .font(.system(size: TypeScale.meta, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                  Text(tool.summary)
                    .font(.system(size: TypeScale.micro, design: .monospaced))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                }

                Spacer()

                Text(tool.statusLabel)
                  .font(.system(size: TypeScale.mini, weight: .medium))
                  .foregroundStyle(tool.statusColor)
              }
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm_)
              .background(Color.backgroundSecondary.opacity(0.62), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
          }
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.sm)
    .padding(.bottom, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.74))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.panelBorder.opacity(0.45), lineWidth: 1)
        )
    )
    .padding(.horizontal, Spacing.md)
    .padding(.bottom, Spacing.sm)
  }

  private var workerFactsGrid: some View {
    LazyVGrid(
      columns: [
        GridItem(.adaptive(minimum: 170), alignment: .leading)
      ],
      alignment: .leading,
      spacing: Spacing.sm
    ) {
      ForEach(presentation.detailLines) { line in
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(line.label.uppercased())
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)

          Text(line.value)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.backgroundTertiary.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
      }
    }
  }

  private func infoCard<Content: View>(
    title: String,
    icon: String,
    accent: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.micro, weight: .bold))
          .foregroundStyle(accent)

        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
      }

      content()
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, Spacing.md)
    .background(Color.backgroundTertiary.opacity(0.58), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
  }
}

private struct SessionWorkerEmptyState: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Select a worker")
        .font(.system(size: TypeScale.large, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Text("Pick a worker from the deck to inspect its report, status, and recent activity without losing the conversation.")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
