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
  let summary: String
  let detailPrompt: String
  let workers: [Worker]
}

struct SessionWorkerDetailPresentation {
  struct DetailLine: Identifiable {
    let id: String
    let label: String
    let value: String
  }

  struct ConversationEvent: Identifiable {
    let id: String
    let iconName: String
    let title: String
    let summary: String
    let timestampLabel: String?
    let statusLabel: String
    let statusColor: Color
  }

  struct ToolActivity: Identifiable {
    let id: String
    let iconName: String
    let toolName: String
    let summary: String
    let statusLabel: String
    let statusColor: Color
  }

  struct ThreadEntry: Identifiable {
    let id: String
    let iconName: String
    let title: String
    let body: String
    let timestampLabel: String?
    let tint: Color
  }

  let id: String
  let title: String
  let subtitle: String?
  let statusLabel: String
  let statusColor: Color
  let iconName: String
  let isActive: Bool
  let statusNarrative: String
  let assignmentPreview: String?
  let reportPreview: String?
  let detailLines: [DetailLine]
  let tools: [ToolActivity]
  let threadEntries: [ThreadEntry]
  let conversationEvents: [ConversationEvent]
}

@MainActor
enum SessionWorkerRosterPlanner {
  static func presentation(subagents: [ServerSubagentInfo]) -> SessionWorkerRosterPresentation? {
    let workers = subagents
      .sorted(by: workerSort)
      .map(workerPresentation)

    guard !workers.isEmpty else { return nil }

    let activeCount = workers.filter(\.isActive).count
    let completedCount = workers.filter { $0.statusLabel == "Complete" }.count
    let stalledCount = workers.count - activeCount - completedCount
    let title = "Workers"
    let summary = workerSummary(
      activeCount: activeCount,
      completedCount: completedCount,
      stalledCount: stalledCount
    )

    return SessionWorkerRosterPresentation(
      title: title,
      summary: summary,
      detailPrompt: activeCount > 0
        ? "Keep an eye on live workers here while the conversation stays in front."
        : "Use this sidecar to revisit finished workers without losing the main thread.",
      workers: workers
    )
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
    messagesByWorker: [String: [ServerMessage]],
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
    let threadEntries = threadEntries(for: messagesByWorker[subagent.id] ?? [])
    let conversationEvents = conversationEvents(
      for: subagent.id,
      timelineMessages: timelineMessages
    )

    return SessionWorkerDetailPresentation(
      id: subagent.id,
      title: subagent.label ?? visuals.label,
      subtitle: workerSubtitle(subagent),
      statusLabel: status.label,
      statusColor: status.color,
      iconName: visuals.iconName,
      isActive: status.isActive,
      statusNarrative: status.narrative,
      assignmentPreview: assignmentPreview(for: subagent.id, subagent: subagent, timelineMessages: timelineMessages),
      reportPreview: latestReportPreview(
        for: subagent.id,
        timelineMessages: timelineMessages
      ),
      detailLines: detailLines(for: subagent),
      tools: Array(tools),
      threadEntries: threadEntries,
      conversationEvents: conversationEvents
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

  private static func workerSummary(
    activeCount: Int,
    completedCount: Int,
    stalledCount: Int
  ) -> String {
    let parts = [
      activeCount > 0 ? "\(activeCount) active" : nil,
      completedCount > 0 ? "\(completedCount) complete" : nil,
      stalledCount > 0 ? "\(stalledCount) needs review" : nil,
    ].compactMap { $0 }

    if !parts.isEmpty {
      return parts.joined(separator: " · ")
    }

    return "No worker activity yet"
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

  private static func threadEntries(
    for messages: [ServerMessage]
  ) -> [SessionWorkerDetailPresentation.ThreadEntry] {
    messages
      .map { $0.toTranscriptMessage() }
      .filter {
        !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || (($0.sanitizedToolOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
      }
      .suffix(8)
      .map(threadEntryPresentation)
  }

  private static func threadEntryPresentation(
    _ message: TranscriptMessage
  ) -> SessionWorkerDetailPresentation.ThreadEntry {
    let timestampLabel = formattedEventTime(message.timestamp)

    let title: String
    let iconName: String
    let tint: Color

    switch message.type {
    case .user:
      title = "Worker prompt"
      iconName = "arrow.up.circle.fill"
      tint = .accent
    case .assistant:
      title = "Worker reply"
      iconName = "sparkles"
      tint = .textPrimary
    case .thinking:
      title = "Reasoning"
      iconName = "brain.head.profile"
      tint = .textSecondary
    case .tool, .toolResult:
      title = message.toolName.map(CompactToolHelpers.displayName(for:)) ?? "Tool activity"
      iconName = ToolCardStyle.icon(for: message.toolName ?? "tool")
      tint = ToolCardStyle.color(for: message.toolName ?? "tool")
    case .steer:
      title = "Steer"
      iconName = "arrowshape.turn.up.right.fill"
      tint = .statusReply
    case .shell:
      title = "Shell"
      iconName = "terminal.fill"
      tint = .feedbackWarning
    case .system:
      title = "System"
      iconName = "info.circle.fill"
      tint = .textSecondary
    }

    return .init(
      id: message.id,
      iconName: iconName,
      title: title,
      body: threadEntryBody(for: message),
      timestampLabel: timestampLabel,
      tint: tint
    )
  }

  private static func threadEntryBody(for message: TranscriptMessage) -> String {
    if let output = message.sanitizedToolOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
      return truncatedThreadBody(output)
    }

    let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    if !content.isEmpty {
      return truncatedThreadBody(content)
    }

    return "No readable output yet."
  }

  private static func truncatedThreadBody(_ body: String) -> String {
    if body.count > 260 {
      return String(body.prefix(260)) + "..."
    }
    return body
  }

  private static func assignmentPreview(
    for subagentID: String,
    subagent: ServerSubagentInfo,
    timelineMessages: [TranscriptMessage]
  ) -> String? {
    if let taskSummary = subagent.taskSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
      return taskSummary
    }

    for message in timelineMessages {
      guard matchesWorker(message, workerID: subagentID) else { continue }

      if let prompt = message.taskPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        return prompt
      }

      if let description = message.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        return description
      }

      let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedContent.isEmpty {
        return trimmedContent
      }
    }

    return nil
  }

  private static func latestReportPreview(
    for subagentID: String,
    timelineMessages: [TranscriptMessage]
  ) -> String? {
    for message in timelineMessages.reversed() {
      guard message.toolName?.lowercased() == "task" else { continue }
      guard matchesWorker(message, workerID: subagentID) else { continue }
      if let preview = message.sanitizedToolOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        return cleanedReportPreview(preview)
      }
    }

    return nil
  }

  private static func conversationEvents(
    for subagentID: String,
    timelineMessages: [TranscriptMessage]
  ) -> [SessionWorkerDetailPresentation.ConversationEvent] {
    timelineMessages
      .filter { matchesWorker($0, workerID: subagentID) }
      .suffix(8)
      .map(conversationEventPresentation)
  }

  private static func conversationEventPresentation(
    _ message: TranscriptMessage
  ) -> SessionWorkerDetailPresentation.ConversationEvent {
    let title = workerEventTitle(for: message)
    let summary = workerEventSummary(for: message) ?? "Worker activity updated."
    let status = eventStatusPresentation(for: message)

    return .init(
      id: message.id,
      iconName: workerEventIcon(for: message),
      title: title,
      summary: summary,
      timestampLabel: formattedEventTime(message.timestamp),
      statusLabel: status.label,
      statusColor: status.color
    )
  }

  private static func matchesWorker(_ message: TranscriptMessage, workerID: String) -> Bool {
    if SharedModelBuilders.linkedWorkerID(for: message) == workerID {
      return true
    }

    if let receiverThreadIDs = message.toolInput?["receiver_thread_ids"] as? [String],
       receiverThreadIDs.contains(workerID)
    {
      return true
    }

    return false
  }

  private static func workerEventTitle(for message: TranscriptMessage) -> String {
    if let toolName = message.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
      return CompactToolHelpers.displayName(for: toolName)
    }

    switch message.type {
    case .assistant:
      return "Assistant Update"
    case .thinking:
      return "Reasoning"
    case .steer:
      return "Steer"
    case .shell:
      return "Shell"
    case .toolResult:
      return "Tool Result"
    case .system:
      return "System"
    case .user:
      return "User"
    case .tool:
      return "Tool"
    }
  }

  private static func workerEventSummary(for message: TranscriptMessage) -> String? {
    if let taskDescription = message.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
      return taskDescription
    }

    if let taskPrompt = message.taskPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
      return taskPrompt
    }

    if let output = message.sanitizedToolOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
      return cleanedReportPreview(output)
    }

    let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    return content.nilIfEmpty
  }

  private static func workerEventIcon(for message: TranscriptMessage) -> String {
    if let toolName = message.toolName {
      return ToolCardStyle.icon(for: toolName)
    }

    switch message.type {
    case .assistant:
      return "bubble.left.and.text.bubble.right.fill"
    case .thinking:
      return "brain"
    case .steer:
      return "arrow.turn.down.right"
    case .shell:
      return "terminal"
    case .toolResult:
      return "checkmark.circle"
    case .system:
      return "gearshape.2.fill"
    case .user:
      return "person.fill"
    case .tool:
      return "gearshape"
    }
  }

  private static func eventStatusPresentation(
    for message: TranscriptMessage
  ) -> (label: String, color: Color) {
    if message.isError {
      return ("Error", .feedbackNegative)
    }

    if message.isInProgress {
      return ("Live", .statusWorking)
    }

    switch message.type {
    case .thinking:
      return ("Reasoning", .statusQuestion)
    case .steer:
      return ("Guidance", .statusReply)
    default:
      return ("Captured", .textSecondary)
    }
  }

  private static func formattedEventTime(_ date: Date) -> String? {
    date.formatted(date: .omitted, time: .shortened)
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
      workerHeader

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

  private var workerHeader: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .center, spacing: Spacing.sm) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.92))

          Image(systemName: "person.3.sequence.fill")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.accent)
        }
        .frame(width: 34, height: 34)

        VStack(alignment: .leading, spacing: 2) {
          Text(presentation.title)
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(presentation.summary)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer(minLength: 0)
      }

      Text(presentation.detailPrompt)
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textQuaternary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func workerRow(_ worker: SessionWorkerRosterPresentation.Worker) -> some View {
    let isSelected = worker.id == selectedWorkerID

    return Button {
      onSelectWorker(worker.id)
    } label: {
      HStack(alignment: .top, spacing: Spacing.sm) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(isSelected ? Color.surfaceSelected.opacity(0.8) : Color.backgroundTertiary.opacity(0.92))

          Image(systemName: worker.iconName)
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(isSelected ? Color.accent : worker.statusColor)
        }
        .frame(width: 28, height: 28)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(worker.title)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
              .lineLimit(1)

            Spacer(minLength: 0)

            statusCapsule(label: worker.statusLabel, color: worker.statusColor)
          }

          if let subtitle = worker.subtitle {
            Text(subtitle)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(2)
          } else {
            Text(worker.isActive ? "Watching for the next update." : "No additional worker note captured.")
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textQuaternary)
              .lineLimit(2)
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm_)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(isSelected ? Color.surfaceSelected.opacity(0.9) : Color.backgroundSecondary.opacity(0.72))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .stroke(isSelected ? Color.accent.opacity(0.35) : Color.panelBorder.opacity(0.45), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private func statusCapsule(label: String, color: Color) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)

      Text(label)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(color)
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.vertical, 5)
    .background(color.opacity(0.12), in: Capsule())
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
      workerHero

      if !presentation.detailLines.isEmpty {
        workerFactsGrid
      }

      missionBriefing

      if !presentation.tools.isEmpty {
        activitySection(
          title: "Tool Feed",
          eyebrow: "Runtime",
          icon: "rectangle.stack.fill",
          accent: Color.accent
        ) {
          VStack(spacing: Spacing.sm) {
            ForEach(presentation.tools) { tool in
              HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: tool.iconName)
                  .font(.system(size: TypeScale.mini, weight: .medium))
                  .foregroundStyle(ToolCardStyle.color(for: tool.toolName))
                  .frame(width: 14, height: 14)
                  .padding(.top, 2)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  HStack(spacing: Spacing.xs) {
                    Text(tool.toolName)
                      .font(.system(size: TypeScale.meta, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)

                    Spacer(minLength: 0)

                    compactStatus(label: tool.statusLabel, color: tool.statusColor)
                  }

                  Text(tool.summary)
                    .font(.system(size: TypeScale.meta))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                }
              }
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm)
              .background(Color.backgroundSecondary.opacity(0.72), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
          }
        }
      }

      activitySection(
        title: "Thread Feed",
        eyebrow: "Sub-thread",
        icon: "text.bubble.fill",
        accent: Color.statusReply
      ) {
        if presentation.threadEntries.isEmpty {
          Text("Open worker transcript updates will land here as this worker talks through the run.")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textSecondary)
        } else {
          VStack(spacing: Spacing.sm) {
            ForEach(presentation.threadEntries) { entry in
              HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: entry.iconName)
                  .font(.system(size: TypeScale.mini, weight: .semibold))
                  .foregroundStyle(entry.tint)
                  .frame(width: 14, height: 14)
                  .padding(.top, 2)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  HStack(spacing: Spacing.xs) {
                    Text(entry.title)
                      .font(.system(size: TypeScale.meta, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)

                    if let timestampLabel = entry.timestampLabel {
                      Text(timestampLabel)
                        .font(.system(size: TypeScale.mini))
                        .foregroundStyle(Color.textQuaternary)
                    }
                  }

                  Text(entry.body)
                    .font(.system(size: TypeScale.meta))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm)
              .background(Color.backgroundSecondary.opacity(0.62), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
          }
        }
      }

      activitySection(
        title: "Conversation Trail",
        eyebrow: "Main thread",
        icon: "point.topleft.down.curvedto.point.bottomright.up.fill",
        accent: Color.statusReply
      ) {
        if presentation.conversationEvents.isEmpty {
          Text(
            presentation.isActive
              ? "Timeline-linked worker activity will appear here as this worker talks back through the main conversation."
              : "No worker-specific conversation events were captured for this run."
          )
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textSecondary)
        } else {
          VStack(spacing: Spacing.sm) {
            ForEach(presentation.conversationEvents) { event in
              HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: event.iconName)
                  .font(.system(size: TypeScale.mini, weight: .semibold))
                  .foregroundStyle(event.statusColor)
                  .frame(width: 14, height: 14)
                  .padding(.top, 2)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  HStack(spacing: Spacing.xs) {
                    Text(event.title)
                      .font(.system(size: TypeScale.meta, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)
                      .lineLimit(1)

                    Text(event.statusLabel)
                      .font(.system(size: TypeScale.mini, weight: .medium))
                      .foregroundStyle(event.statusColor)

                    if let timestampLabel = event.timestampLabel {
                      Text(timestampLabel)
                        .font(.system(size: TypeScale.mini))
                        .foregroundStyle(Color.textQuaternary)
                    }
                  }

                  Text(event.summary)
                    .font(.system(size: TypeScale.micro))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm)
              .background(Color.backgroundSecondary.opacity(0.62), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
          }
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.xs)
    .padding(.bottom, Spacing.md)
  }

  private var workerHero: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.95))

          Image(systemName: presentation.iconName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(presentation.statusColor)
        }
        .frame(width: 34, height: 34)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(alignment: .center, spacing: Spacing.xs) {
            Text(presentation.title)
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(Color.textPrimary)

            compactStatus(label: presentation.statusLabel, color: presentation.statusColor)
          }

          if let subtitle = presentation.subtitle {
            Text(subtitle)
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          Text(presentation.statusNarrative)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.82))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.panelBorder.opacity(0.42), lineWidth: 1)
        )
    )
  }

  private var missionBriefing: some View {
    let briefing = missionBriefingMeta

    return activitySection(
      title: briefing.title,
      eyebrow: briefing.eyebrow,
      icon: briefing.icon,
      accent: briefing.accent
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if let reportPreview = presentation.reportPreview {
          MarkdownRepresentable(content: reportPreview, style: .standard)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let assignmentPreview = presentation.assignmentPreview {
          Text(assignmentPreview)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Text("This worker has been registered, but OrbitDock has not captured a readable brief yet.")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textSecondary)
        }

        if presentation.reportPreview != nil, let assignmentPreview = presentation.assignmentPreview {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Original assignment")
              .font(.system(size: TypeScale.mini, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)

            Text(assignmentPreview)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
          .background(Color.backgroundSecondary.opacity(0.68), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
      }
    }
  }

  private var missionBriefingMeta: (title: String, eyebrow: String, icon: String, accent: Color) {
    if presentation.reportPreview != nil {
      return ("Latest Report", "Returned context", "text.bubble.fill", presentation.statusColor)
    }

    return ("Current Assignment", "Mission brief", "scope", Color.accent)
  }

  private var workerFactsGrid: some View {
    LazyVGrid(
      columns: [
        GridItem(.adaptive(minimum: 128), alignment: .leading)
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
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
            .lineLimit(3)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.backgroundTertiary.opacity(0.62), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
      }
    }
  }

  private func activitySection<Content: View>(
    title: String,
    eyebrow: String,
    icon: String,
    accent: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(accent.opacity(0.14))

          Image(systemName: icon)
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(accent)
        }
        .frame(width: 20, height: 20)

        VStack(alignment: .leading, spacing: 1) {
          Text(eyebrow.uppercased())
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)

          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }
      }

      content()
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.58))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.panelBorder.opacity(0.35), lineWidth: 1)
        )
    )
  }

  private func compactStatus(label: String, color: Color) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)

      Text(label)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(color)
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.vertical, 5)
    .background(color.opacity(0.12), in: Capsule())
  }
}

private struct SessionWorkerEmptyState: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Select a worker")
        .font(.system(size: TypeScale.title, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Text("Pick a worker from the deck to inspect its report, status, and recent activity without losing the conversation.")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.7))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.panelBorder.opacity(0.35), lineWidth: 1)
        )
    )
    .padding(.horizontal, Spacing.md)
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
