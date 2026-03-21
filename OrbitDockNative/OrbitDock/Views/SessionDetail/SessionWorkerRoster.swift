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

  struct RelatedWorker: Identifiable {
    let id: String
    let title: String
    let relationshipLabel: String
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
  let relatedWorkers: [RelatedWorker]
  let latestConversationEventID: String?
}

@MainActor
enum SessionWorkerRosterPlanner {
  private struct WorkerTimelineSummary {
    let assignmentPreview: String?
    let reportPreview: String?
    let conversationEvents: [SessionWorkerDetailPresentation.ConversationEvent]
  }

  private static let iso8601Formatter = ISO8601DateFormatter()

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
    messagesByWorker: [String: [ServerConversationRowEntry]],
    timelineEntries: [ServerConversationRowEntry]
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
    let timelineSummary = workerTimelineSummary(
      for: subagent.id,
      subagent: subagent,
      timelineEntries: timelineEntries
    )
    let relatedWorkers = relatedWorkers(
      for: subagent,
      among: subagents
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
      assignmentPreview: timelineSummary.assignmentPreview,
      reportPreview: timelineSummary.reportPreview,
      detailLines: detailLines(for: subagent),
      tools: Array(tools),
      threadEntries: threadEntries,
      conversationEvents: timelineSummary.conversationEvents,
      relatedWorkers: relatedWorkers,
      latestConversationEventID: timelineSummary.conversationEvents.last?.id
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

  private static func statusPresentation(_ status: ServerSubagentStatus?)
    -> (label: String, color: Color, isActive: Bool, narrative: String)
  {
    switch status {
      case .pending:
        ("Pending", .feedbackCaution, true, "Queued up and waiting for a turn.")
      case .running:
        ("Running", .statusWorking, true, "Actively working through its assignment.")
      case .completed:
        ("Complete", .feedbackPositive, false, "Finished cleanly and reported back.")
      case .failed:
        ("Failed", .feedbackNegative, false, "Stopped with an error and may need attention.")
      case .cancelled:
        ("Cancelled", .feedbackWarning, false, "Cancelled before it could finish.")
      case .shutdown:
        ("Stopped", .textSecondary, false, "Closed down after the run ended.")
      case .notFound:
        ("Unavailable", .feedbackNegative, false, "Could not be found when OrbitDock checked in.")
      case nil:
        ("Known", .textSecondary, false, "Known to the session, but still waiting on more detail.")
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
    return iso8601Formatter.date(from: value)
  }

  private static func formattedDate(_ value: String?) -> String? {
    guard let date = parseDate(value) else { return nil }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func visuals(for agentType: String) -> (label: String, iconName: String) {
    switch agentType.lowercased() {
      case "explore", "explorer":
        ("Explorer", "binoculars.fill")
      case "plan", "planner":
        ("Planner", "map.fill")
      case "worker":
        ("Worker", "person.crop.circle.badge.gearshape.fill")
      case "reviewer":
        ("Reviewer", "checklist.checked")
      case "researcher":
        ("Researcher", "magnifyingglass.circle.fill")
      case "general-purpose":
        ("General", "cpu.fill")
      default:
        (agentType.replacingOccurrences(of: "-", with: " ").capitalized, "person.crop.circle.fill")
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
    for entries: [ServerConversationRowEntry]
  ) -> [SessionWorkerDetailPresentation.ThreadEntry] {
    entries
      .compactMap(threadEntryPresentation)
      .suffix(8)
      .map { $0 }
  }

  private static func threadEntryPresentation(
    _ entry: ServerConversationRowEntry
  ) -> SessionWorkerDetailPresentation.ThreadEntry? {
    guard let body = threadEntryBody(for: entry) else { return nil }
    let timestampLabel = formattedEventTime(entryTimestamp(entry))

    let title: String
    let iconName: String
    let tint: Color

    switch entry.row {
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
      case let .tool(tool):
        let toolName = tool.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = toolName.nilIfEmpty.map(Self.toolDisplayName) ?? "Tool activity"
        iconName = ToolCardStyle.icon(for: toolName.nilIfEmpty ?? tool.kind.rawValue)
        tint = ToolCardStyle.color(for: toolName.nilIfEmpty ?? tool.kind.rawValue)
      case let .activityGroup(group):
        title = group.title
        iconName = "square.stack.3d.up.fill"
        tint = .statusWorking
      case .shellCommand:
        title = "Shell"
        iconName = "terminal.fill"
        tint = .feedbackWarning
      case .context:
        title = "Context"
        iconName = "info.circle.fill"
        tint = .textSecondary
      case .notice:
        title = "Notice"
        iconName = "exclamationmark.bubble.fill"
        tint = .feedbackWarning
      case .task:
        title = "Task"
        iconName = "list.bullet.rectangle.portrait.fill"
        tint = .statusReply
      case .system:
        title = "System"
        iconName = "info.circle.fill"
        tint = .textSecondary
      case .question:
        title = "Question"
        iconName = "questionmark.bubble.fill"
        tint = .statusQuestion
      case .approval:
        title = "Approval"
        iconName = "checkmark.shield.fill"
        tint = .feedbackWarning
      case .worker:
        title = "Worker update"
        iconName = "person.crop.circle.badge.gearshape.fill"
        tint = .statusWorking
      case .plan:
        title = "Plan"
        iconName = "map.fill"
        tint = .statusReply
      case .hook:
        title = "Hook"
        iconName = "bolt.horizontal.fill"
        tint = .accent
      case .handoff:
        title = "Handoff"
        iconName = "arrow.left.arrow.right.circle.fill"
        tint = .statusReply
    }

    return .init(
      id: entry.id,
      iconName: iconName,
      title: title,
      body: body,
      timestampLabel: timestampLabel,
      tint: tint
    )
  }

  private static func threadEntryBody(for entry: ServerConversationRowEntry) -> String? {
    let body: String? = switch entry.row {
      case let .user(message),
           let .assistant(message),
           let .thinking(message),
           let .system(message):
        message.content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .context(context):
        context.body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? context.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? context.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .notice(notice):
        notice.body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? notice.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? notice.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .shellCommand(shellCommand):
        shellCommand.stdout?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? shellCommand.stderr?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? shellCommand.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? shellCommand.command?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? shellCommand.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .task(task):
        task.resultText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? task.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? task.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .tool(tool):
        tool.toolDisplay.outputDisplay?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? tool.toolDisplay.outputPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? tool.toolDisplay.liveOutputPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? tool.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? tool.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? tool.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .activityGroup(group):
        group.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? group.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? group.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .question(question):
        question.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? question.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? question.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .approval(approval):
        approval.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? approval.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? approval.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .worker(worker):
        worker.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? worker.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? worker.worker.taskSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? worker.worker.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? worker.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .plan(plan):
        plan.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? plan.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? plan.payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? plan.payload.explanation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? plan.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .hook(hook):
        hook.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? hook.payload.output?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? hook.payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? hook.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .handoff(handoff):
        handoff.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? handoff.payload.body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? handoff.payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? handoff.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    guard let body else { return nil }
    return truncatedThreadBody(body)
  }

  private static func truncatedThreadBody(_ body: String) -> String {
    if body.count > 260 {
      return String(body.prefix(260)) + "..."
    }
    return body
  }

  private static func workerTimelineSummary(
    for subagentID: String,
    subagent: ServerSubagentInfo,
    timelineEntries: [ServerConversationRowEntry]
  ) -> WorkerTimelineSummary {
    let taskSummary = subagent.taskSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    var derivedAssignmentPreview: String?
    var derivedReportPreview: String?
    var matchedEntries: [ServerConversationRowEntry] = []
    matchedEntries.reserveCapacity(8)

    for entry in timelineEntries {
      guard matchesWorker(entry, workerID: subagentID) else { continue }

      if derivedAssignmentPreview == nil {
        derivedAssignmentPreview = assignmentPreview(for: entry)
      }

      if let preview = reportPreview(for: entry) {
        derivedReportPreview = cleanedReportPreview(preview)
      }

      matchedEntries.append(entry)
      if matchedEntries.count > 8 {
        matchedEntries.removeFirst(matchedEntries.count - 8)
      }
    }

    return WorkerTimelineSummary(
      assignmentPreview: taskSummary ?? derivedAssignmentPreview,
      reportPreview: derivedReportPreview,
      conversationEvents: matchedEntries.map(conversationEventPresentation)
    )
  }

  private static func relatedWorkers(
    for subagent: ServerSubagentInfo,
    among subagents: [ServerSubagentInfo]
  ) -> [SessionWorkerDetailPresentation.RelatedWorker] {
    var related: [SessionWorkerDetailPresentation.RelatedWorker] = []

    if let parentID = subagent.parentSubagentId,
       let parent = subagents.first(where: { $0.id == parentID })
    {
      let status = statusPresentation(parent.status)
      related.append(
        .init(
          id: parent.id,
          title: parent.label ?? visuals(for: parent.agentType).label,
          relationshipLabel: "Parent worker",
          statusLabel: status.label,
          statusColor: status.color
        )
      )
    }

    let children = subagents
      .filter { $0.parentSubagentId == subagent.id }
      .sorted(by: workerSort)

    for child in children {
      let status = statusPresentation(child.status)
      related.append(
        .init(
          id: child.id,
          title: child.label ?? visuals(for: child.agentType).label,
          relationshipLabel: "Child worker",
          statusLabel: status.label,
          statusColor: status.color
        )
      )
    }

    return related
  }

  private static func conversationEventPresentation(
    _ entry: ServerConversationRowEntry
  ) -> SessionWorkerDetailPresentation.ConversationEvent {
    let title = workerEventTitle(for: entry)
    let summary = workerEventSummary(for: entry) ?? "Worker activity updated."
    let status = eventStatusPresentation(for: entry)

    return .init(
      id: entry.id,
      iconName: workerEventIcon(for: entry),
      title: title,
      summary: summary,
      timestampLabel: formattedEventTime(entryTimestamp(entry)),
      statusLabel: status.label,
      statusColor: status.color
    )
  }

  private static func matchesWorker(_ entry: ServerConversationRowEntry, workerID: String) -> Bool {
    switch entry.row {
      case let .worker(worker):
        worker.worker.id == workerID
      case let .tool(tool):
        linkedWorkerID(for: tool) == workerID
      case let .activityGroup(group):
        group.children.contains { linkedWorkerID(for: $0) == workerID }
      default:
        false
    }
  }

  private static func workerEventTitle(for entry: ServerConversationRowEntry) -> String {
    switch entry.row {
      case let .worker(worker):
        worker.operation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? worker.title
      case let .tool(tool):
        toolDisplayName(tool.title)
      case let .activityGroup(group):
        group.title
      case .assistant:
        "Assistant Update"
      case .thinking:
        "Reasoning"
      case .shellCommand:
        "Shell"
      case .plan:
        "Plan"
      case .hook:
        "Hook"
      case .handoff:
        "Handoff"
      case .system, .context, .notice, .task, .approval, .question:
        "System"
      case .user:
        "User"
    }
  }

  private static func workerEventSummary(for entry: ServerConversationRowEntry) -> String? {
    reportPreview(for: entry)
      ?? assignmentPreview(for: entry)
      ?? threadEntryBody(for: entry)
  }

  private static func toolDisplayName(_ toolName: String) -> String {
    let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
      case "bash": return "Bash"
      case "read": return "Read"
      case "edit": return "Edit"
      case "write": return "Write"
      case "glob": return "Glob"
      case "grep": return "Grep"
      case "task", "agent", "spawn_agent": return "Agent"
      case "webfetch": return "Fetch"
      case "websearch": return "Search"
      default: return toolName
    }
  }

  private static func linkedWorkerID(for tool: ServerConversationToolRow) -> String? {
    guard let inputDisplay = tool.toolDisplay.inputDisplay else { return nil }
    if let data = inputDisplay.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      if let subagentID = json["subagent_id"] as? String,
         !subagentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return subagentID
      }
      if let receiverThreadID = json["receiver_thread_id"] as? String,
         !receiverThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return receiverThreadID
      }
    }
    return nil
  }

  private static func workerEventIcon(for entry: ServerConversationRowEntry) -> String {
    switch entry.row {
      case let .tool(tool):
        ToolCardStyle.icon(for: tool.title)
      case let .activityGroup(group):
        group.children.first.map { ToolCardStyle.icon(for: $0.title) } ?? "square.stack.3d.up.fill"
      case let .worker(worker):
        visuals(for: worker.worker.agentType ?? "worker").iconName
      case .assistant:
        "bubble.left.and.text.bubble.right.fill"
      case .thinking:
        "brain"
      case .shellCommand:
        "terminal"
      case .system, .context, .notice, .task, .approval, .question:
        "gearshape.2.fill"
      case .user:
        "person.fill"
      case .plan:
        "map.fill"
      case .hook:
        "bolt.horizontal.fill"
      case .handoff:
        "arrow.left.arrow.right.circle.fill"
    }
  }

  private static func eventStatusPresentation(
    for entry: ServerConversationRowEntry
  ) -> (label: String, color: Color) {
    switch entry.row {
      case let .worker(worker):
        switch worker.worker.status {
          case .failed, .blocked:
            ("Error", .feedbackNegative)
          case .running, .pending, .needsInput:
            ("Live", .statusWorking)
          case .completed:
            ("Captured", .feedbackPositive)
          case .cancelled:
            ("Cancelled", .feedbackWarning)
        }
      case let .tool(tool):
        switch tool.status {
          case .failed, .blocked:
            ("Error", .feedbackNegative)
          case .running, .pending, .needsInput:
            ("Live", .statusWorking)
          case .completed:
            ("Captured", .textSecondary)
          case .cancelled:
            ("Cancelled", .feedbackWarning)
        }
      case let .activityGroup(group):
        switch group.status {
          case .failed, .blocked:
            ("Error", .feedbackNegative)
          case .running, .pending, .needsInput:
            ("Live", .statusWorking)
          case .completed:
            ("Captured", .textSecondary)
          case .cancelled:
            ("Cancelled", .feedbackWarning)
        }
      case .thinking:
        ("Reasoning", .statusQuestion)
      default:
        ("Captured", .textSecondary)
    }
  }

  private static func formattedEventTime(_ date: Date?) -> String? {
    guard let date else { return nil }
    return date.formatted(date: .omitted, time: .shortened)
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

  private static func assignmentPreview(for entry: ServerConversationRowEntry) -> String? {
    switch entry.row {
      case let .worker(worker):
        worker.worker.taskSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? worker.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? worker.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .tool(tool):
        parsedStringValue(
          from: tool.toolDisplay.inputDisplay,
          keys: ["description", "task_description", "prompt", "task_prompt", "message", "input"]
        )
          ?? tool.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? tool.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .activityGroup(group):
        group.children.lazy.compactMap { assignmentPreview(for: $0) }.first
          ?? group.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      default:
        nil
    }
  }

  private static func assignmentPreview(for tool: ServerConversationToolRow) -> String? {
    parsedStringValue(
      from: tool.toolDisplay.inputDisplay,
      keys: ["description", "task_description", "prompt", "task_prompt", "message", "input"]
    )
      ?? tool.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? tool.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private static func reportPreview(for entry: ServerConversationRowEntry) -> String? {
    switch entry.row {
      case let .worker(worker):
        worker.worker.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? worker.worker.errorSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? worker.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .tool(tool):
        tool.toolDisplay.outputDisplay?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? tool.toolDisplay.outputPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? tool.toolDisplay.liveOutputPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .activityGroup(group):
        group.children.lazy.compactMap { reportPreview(for: $0) }.first
      case let .task(task):
        task.resultText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? task.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      default:
        nil
    }
  }

  private static func reportPreview(for tool: ServerConversationToolRow) -> String? {
    tool.toolDisplay.outputDisplay?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? tool.toolDisplay.outputPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? tool.toolDisplay.liveOutputPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private static func parsedStringValue(from jsonString: String?, keys: [String]) -> String? {
    guard let jsonString,
          let data = jsonString.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    for key in keys {
      if let value = json[key] as? String,
         let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      {
        return trimmed
      }
    }

    return nil
  }

  private static func entryTimestamp(_ entry: ServerConversationRowEntry) -> Date? {
    switch entry.row {
      case let .user(message),
           let .assistant(message),
           let .thinking(message),
           let .system(message):
        parseDate(message.timestamp)
      case let .tool(tool):
        parseDate(tool.startedAt) ?? parseDate(tool.endedAt)
      case let .worker(worker):
        parseDate(worker.worker.lastActivityAt)
          ?? parseDate(worker.worker.startedAt)
          ?? parseDate(worker.worker.endedAt)
      case .shellCommand:
        nil
      case .activityGroup, .context, .notice, .task, .question, .approval, .plan, .hook, .handoff:
        nil
    }
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
  let onRevealConversationEvent: (String) -> Void

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
            SessionWorkerDetailView(
              presentation: detailPresentation,
              onSelectWorker: onSelectWorker,
              onRevealConversationEvent: onRevealConversationEvent
            )
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
  let onSelectWorker: (String) -> Void
  let onRevealConversationEvent: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      workerHero

      if presentation.latestConversationEventID != nil || !presentation.relatedWorkers.isEmpty {
        workerActionRail
      }

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
              .background(
                Color.backgroundSecondary.opacity(0.72),
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              )
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
              .background(
                Color.backgroundSecondary.opacity(0.62),
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              )
            }
          }
        }
      }

      if !presentation.relatedWorkers.isEmpty {
        activitySection(
          title: "Related Workers",
          eyebrow: "Graph",
          icon: "point.3.connected.trianglepath.dotted",
          accent: Color.accent
        ) {
          VStack(spacing: Spacing.sm) {
            ForEach(presentation.relatedWorkers) { worker in
              Button {
                onSelectWorker(worker.id)
              } label: {
                HStack(spacing: Spacing.sm) {
                  VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(worker.relationshipLabel)
                      .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
                      .foregroundStyle(Color.textQuaternary)

                    Text(worker.title)
                      .font(.system(size: TypeScale.meta, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)
                      .lineLimit(1)
                  }

                  Spacer(minLength: 0)

                  compactStatus(label: worker.statusLabel, color: worker.statusColor)

                  Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Color.accent)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                  Color.backgroundSecondary.opacity(0.62),
                  in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                )
              }
              .buttonStyle(.plain)
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
              Button {
                onRevealConversationEvent(event.id)
              } label: {
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

                  Spacer(minLength: 0)

                  Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: TypeScale.mini, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                  Color.backgroundSecondary.opacity(0.62),
                  in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                )
              }
              .buttonStyle(.plain)
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

  private var workerActionRail: some View {
    HStack(spacing: Spacing.sm) {
      if let latestConversationEventID = presentation.latestConversationEventID {
        Button {
          onRevealConversationEvent(latestConversationEventID)
        } label: {
          Label("Reveal Latest Moment", systemImage: "arrow.up.forward.app")
            .font(.system(size: TypeScale.meta, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.accent)
      }

      if let activeRelated = presentation.relatedWorkers.first {
        Button {
          onSelectWorker(activeRelated.id)
        } label: {
          Label(activeRelated.title, systemImage: "point.3.connected.trianglepath.dotted")
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(activeRelated.statusColor)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.xs)
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
          MarkdownContentView(content: reportPreview, style: .standard)
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
          .background(
            Color.backgroundSecondary.opacity(0.68),
            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          )
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
        GridItem(.adaptive(minimum: 128), alignment: .leading),
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
        .background(
          Color.backgroundTertiary.opacity(0.62),
          in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
      }
    }
  }

  private func activitySection(
    title: String,
    eyebrow: String,
    icon: String,
    accent: Color,
    @ViewBuilder content: () -> some View
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

      Text(
        "Pick a worker from the deck to inspect its report, status, and recent activity without losing the conversation."
      )
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
