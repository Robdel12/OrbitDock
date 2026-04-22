import Foundation
import SwiftUI

@MainActor
enum SessionWorkerRosterPlanner {
  private static let maxRecentInactiveWorkers = 4

  private struct WorkerTimelineSummary {
    let assignmentPreview: String?
    let reportPreview: String?
    let conversationEvents: [SessionWorkerDetailPresentation.ConversationEvent]
  }

  private struct RankedWorker {
    let subagent: ServerSubagentInfo
    let isActive: Bool
    let sortDate: Date
  }

  private static let iso8601Formatter = ISO8601DateFormatter()

  static func visibleSubagents(subagents: [ServerSubagentInfo]) -> [ServerSubagentInfo] {
    let ranked = sortedSubagents(subagents)
    let activeWorkers = ranked.filter { isActive($0.status) }
    let inactiveWorkers = ranked.filter { !isActive($0.status) }

    return activeWorkers + inactiveWorkers.prefix(maxRecentInactiveWorkers)
  }

  static func presentation(subagents: [ServerSubagentInfo]) -> SessionWorkerRosterPresentation? {
    let workers = visibleSubagents(subagents: subagents).map(workerPresentation)

    guard !workers.isEmpty else { return nil }

    let activeCount = subagents.filter { isActive($0.status) }.count
    let completedCount = subagents.filter { $0.status == .completed }.count
    let stalledCount = subagents.count - activeCount - completedCount
    let archivedCount = max(subagents.count - workers.count, 0)
    let title = "Workers"
    let summary = workerSummary(
      activeCount: activeCount,
      completedCount: completedCount,
      stalledCount: stalledCount,
      archivedCount: archivedCount
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
    let visibleWorkerIDs = Set(visibleSubagents(subagents: subagents).map(\.id))

    if let currentSelectionID,
       visibleWorkerIDs.contains(currentSelectionID)
    {
      return currentSelectionID
    }

    return visibleSubagents(subagents: subagents).first?.id
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

  private static func sortedSubagents(_ subagents: [ServerSubagentInfo]) -> [ServerSubagentInfo] {
    subagents
      .map {
        RankedWorker(
          subagent: $0,
          isActive: isActive($0.status),
          sortDate: sortDate(for: $0)
        )
      }
      .sorted(by: rankedWorkerSort)
      .map(\.subagent)
  }

  private static func rankedWorkerSort(lhs: RankedWorker, rhs: RankedWorker) -> Bool {
    if lhs.isActive != rhs.isActive {
      return lhs.isActive && !rhs.isActive
    }

    return lhs.sortDate > rhs.sortDate
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
    stalledCount: Int,
    archivedCount: Int
  ) -> String {
    let parts = [
      activeCount > 0 ? "\(activeCount) active" : nil,
      completedCount > 0 ? "\(completedCount) complete" : nil,
      stalledCount > 0 ? "\(stalledCount) needs review" : nil,
      archivedCount > 0 ? "\(archivedCount) archived" : nil,
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
      case .interrupted:
        ("Interrupted", .feedbackWarning, true, "Paused mid-flight and ready to be resumed or inspected.")
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
    status == .pending || status == .running || status == .interrupted
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
      case .steer:
        title = "Worker steer"
        iconName = "arrow.up.circle.badge.clock"
        tint = .composerSteer
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
           let .steer(message),
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
        shellCommandPreviewBody(for: shellCommand)
          ?? shellCommand.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? shellCommand.command?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? shellCommand.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .task(task):
        task.resultText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? task.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? task.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      case let .tool(tool):
        threadEntryToolBody(for: tool)
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

  private static func threadEntryToolBody(for tool: ServerConversationToolRow) -> String? {
    shellPreview(for: tool)
      ?? trimmed(tool.toolDisplay.outputDisplay)
      ?? trimmed(tool.toolDisplay.outputPreview)
      ?? trimmed(tool.toolDisplay.liveOutputPreview)
      ?? trimmed(tool.summary)
      ?? trimmed(tool.subtitle)
      ?? trimmed(tool.title)
  }

  private static func shellPreview(for tool: ServerConversationToolRow) -> String? {
    trimmed(tool.shellExecution?.liveOutputPreview)
      ?? trimmed(tool.shellExecution?.command)
  }

  private static func trimmed(_ value: String?) -> String? {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private static func shellCommandPreviewBody(
    for shellCommand: ServerConversationShellCommandRow
  ) -> String? {
    let outputPreview =
      shellCommand.outputPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    if outputPreview != nil,
       shellCommand.stdout?.nilIfEmpty != nil,
       shellCommand.stderr?.nilIfEmpty != nil
    {
      return outputPreview
    }

    let stdout = shellCommand.stdout?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let stderr = shellCommand.stderr?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    if let stdout, let stderr {
      return "\(stdout)\n\(stderr)".nilIfEmpty
    }
    return outputPreview ?? stdout ?? stderr
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

    let children = sortedSubagents(
      subagents.filter { $0.parentSubagentId == subagent.id }
    )

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
      case .steer:
        "Steer"
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

  private static func linkedWorkerID(for child: ServerConversationActivityGroupChild) -> String? {
    switch child {
      case let .tool(tool):
        linkedWorkerID(for: tool)
    }
  }

  private static func childTitle(for child: ServerConversationActivityGroupChild) -> String {
    switch child {
      case let .tool(tool):
        tool.title
    }
  }

  private static func workerEventIcon(for entry: ServerConversationRowEntry) -> String {
    switch entry.row {
      case let .tool(tool):
        ToolCardStyle.icon(for: tool.title)
      case let .activityGroup(group):
        group.children.first.map { child in
          switch child {
            case let .tool(tool):
              ToolCardStyle.icon(for: tool.title)
          }
        } ?? "square.stack.3d.up.fill"
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
      case .steer:
        "arrow.up.circle.fill"
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
          ?? trimmed(tool.shellExecution?.command)
          ?? trimmed(tool.summary)
          ?? trimmed(tool.subtitle)
      case let .activityGroup(group):
        group.children.lazy.compactMap { assignmentPreview(for: $0) }.first
          ?? trimmed(group.summary)
      default:
        nil
    }
  }

  private static func assignmentPreview(for tool: ServerConversationToolRow) -> String? {
    parsedStringValue(
      from: tool.toolDisplay.inputDisplay,
      keys: ["description", "task_description", "prompt", "task_prompt", "message", "input"]
    )
      ?? trimmed(tool.summary)
      ?? trimmed(tool.subtitle)
  }

  private static func assignmentPreview(for child: ServerConversationActivityGroupChild) -> String? {
    switch child {
      case let .tool(tool):
        assignmentPreview(for: tool)
    }
  }

  private static func reportPreview(for entry: ServerConversationRowEntry) -> String? {
    switch entry.row {
      case let .worker(worker):
        trimmed(worker.worker.resultSummary)
          ?? trimmed(worker.worker.errorSummary)
          ?? trimmed(worker.summary)
      case let .tool(tool):
        reportPreview(for: tool)
      case let .activityGroup(group):
        group.children.lazy.compactMap { reportPreview(for: $0) }.first
      case let .task(task):
        trimmed(task.resultText)
          ?? trimmed(task.summary)
      default:
        nil
    }
  }

  private static func reportPreview(for tool: ServerConversationToolRow) -> String? {
    trimmed(tool.shellExecution?.liveOutputPreview)
      ?? trimmed(tool.toolDisplay.outputDisplay)
      ?? trimmed(tool.toolDisplay.outputPreview)
      ?? trimmed(tool.toolDisplay.liveOutputPreview)
  }

  private static func reportPreview(for child: ServerConversationActivityGroupChild) -> String? {
    switch child {
      case let .tool(tool):
        return reportPreview(for: tool)
    }
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
           let .steer(message),
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
