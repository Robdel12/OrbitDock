import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ConversationTimelineViewModelTests {
  @Test func focusedModeBuildsGroupedProjection() {
    let viewModel = ConversationTimelineViewModel()
    viewModel.bind(sessionId: "session-1")

    viewModel.apply(
      presentation: ConversationTimelinePresentation(
        entries: [
          makeToolEntry(id: "tool-1", sequence: 1, summary: "Read"),
          makeToolEntry(id: "tool-2", sequence: 2, summary: "Edit"),
          makeToolEntry(id: "tool-3", sequence: 3, summary: "Write"),
        ],
        contentRevision: 1,
        structureRevision: 1,
        changedEntries: []
      ),
      viewMode: .focused
    )

    let displayedEntries = viewModel.renderedEntries(limit: viewModel.displayedEntryCount)

    #expect(viewModel.displayedEntryCount == 2)
    #expect(displayedEntries.first?.id == "tool-3")

    guard case let .activityGroup(group)? = displayedEntries.last?.row else {
      Issue.record("Expected focused timeline to build an activity group")
      return
    }

    #expect(group.childCount == 2)
    #expect(group.children.map { $0.id } == ["tool-1", "tool-2"])
  }

  @Test func expandedRowsSurviveContentOnlyUpdates() {
    let viewModel = ConversationTimelineViewModel()
    viewModel.bind(sessionId: "session-1")

    viewModel.apply(
      presentation: ConversationTimelinePresentation(
        entries: [makeToolEntry(id: "tool-1", sequence: 1, summary: "Read")],
        contentRevision: 1,
        structureRevision: 1,
        changedEntries: []
      ),
      viewMode: .verbose
    )

    #expect(viewModel.toggleExpanded("tool-1"))
    #expect(viewModel.isExpanded("tool-1"))

    viewModel.apply(
      presentation: ConversationTimelinePresentation(
        entries: [makeToolEntry(id: "tool-1", sequence: 1, summary: "Read updated")],
        contentRevision: 2,
        structureRevision: 1,
        changedEntries: [makeToolEntry(id: "tool-1", sequence: 1, summary: "Read updated")]
      ),
      viewMode: .verbose
    )

    let displayedEntries = viewModel.renderedEntries(limit: viewModel.displayedEntryCount)

    #expect(viewModel.isExpanded("tool-1"))

    guard case let .tool(tool)? = displayedEntries.first?.row else {
      Issue.record("Expected updated display row to remain a tool row")
      return
    }

    #expect(tool.toolDisplay.summary == "Read updated")
  }

  @Test func bindingNewSessionClearsDurableTimelineState() {
    let viewModel = ConversationTimelineViewModel()
    viewModel.bind(sessionId: "session-1")

    viewModel.apply(
      presentation: ConversationTimelinePresentation(
        entries: [makeToolEntry(id: "tool-1", sequence: 1, summary: "Read")],
        contentRevision: 1,
        structureRevision: 1,
        changedEntries: []
      ),
      viewMode: .verbose
    )
    _ = viewModel.toggleExpanded("tool-1")

    viewModel.bind(sessionId: "session-2")

    #expect(viewModel.displayedEntryCount == 0)
    #expect(viewModel.renderedEntries(limit: viewModel.displayedEntryCount).isEmpty)
    #expect(!viewModel.isExpanded("tool-1"))
  }

  @Test func renderWindowHelpersRevealOlderRowsThroughTheirDisplayAnchor() {
    let viewModel = ConversationTimelineViewModel()
    viewModel.bind(sessionId: "session-1")

    viewModel.apply(
      presentation: ConversationTimelinePresentation(
        entries: [
          makeToolEntry(id: "tool-1", sequence: 1, summary: "Read"),
          makeToolEntry(id: "tool-2", sequence: 2, summary: "Edit"),
          makeToolEntry(id: "tool-3", sequence: 3, summary: "Write"),
        ],
        contentRevision: 1,
        structureRevision: 1,
        changedEntries: []
      ),
      viewMode: .focused
    )

    #expect(viewModel.displayAnchorID(for: "tool-1") == "group:tool-1")
    #expect(viewModel.renderWindowRequiredToReveal(rowId: "tool-1") == 1)
    #expect(viewModel.displayAnchorID(for: "tool-3") == "tool-3")
    #expect(viewModel.renderWindowRequiredToReveal(rowId: "tool-3") == 2)
  }

  @Test func focusedModePreservesFailedCommandExecutionStatusInsideArchivedGroups() throws {
    let viewModel = ConversationTimelineViewModel()
    viewModel.bind(sessionId: "session-1")

    viewModel.apply(
      presentation: ConversationTimelinePresentation(
        entries: [
          makeCommandExecutionEntry(
            id: "command-1",
            sequence: 1,
            status: .failed,
            command: "cat missing.txt",
            output: "No such file or directory"
          ),
          makeToolEntry(id: "tool-2", sequence: 2, summary: "Read"),
        ],
        contentRevision: 1,
        structureRevision: 1,
        changedEntries: []
      ),
      viewMode: .focused
    )

    let displayedEntries = viewModel.renderedEntries(limit: viewModel.displayedEntryCount)
    let group = try #require(
      displayedEntries.last.flatMap { entry in
        if case let .activityGroup(group) = entry.row {
          group
        } else {
          nil
        }
      }
    )

    #expect(group.status == .failed)
  }

  private func makeToolEntry(
    id: String,
    sequence: UInt64,
    summary: String
  ) -> ServerConversationRowEntry {
    ServerConversationRowEntry(
      sessionId: "session-1",
      sequence: sequence,
      turnId: nil,
      turnStatus: .active,
      row: .tool(ServerConversationToolRow(
        id: id,
        provider: .codex,
        family: .agent,
        kind: .taskOutput,
        status: .completed,
        title: summary,
        subtitle: nil,
        summary: summary,
        preview: nil,
        startedAt: nil,
        endedAt: nil,
        durationMs: nil,
        groupingKey: nil,
        renderHints: .init(),
        toolDisplay: ServerToolDisplay(
          summary: summary,
          subtitle: nil,
          rightMeta: nil,
          subtitleAbsorbsMeta: false,
          glyphSymbol: "hammer",
          glyphColor: "blue",
          language: nil,
          diffPreview: nil,
          outputPreview: nil,
          liveOutputPreview: nil,
          todoItems: [],
          toolType: "task",
          summaryFont: "system",
          displayTier: "standard",
          inputDisplay: nil,
          outputDisplay: nil,
          diffDisplay: nil
        )
      ))
    )
  }

  private func makeCommandExecutionEntry(
    id: String,
    sequence: UInt64,
    status: ServerConversationCommandExecutionStatus,
    command: String,
    output: String?
  ) -> ServerConversationRowEntry {
    let decoder = JSONDecoder()
    let payload = """
    {
      "id": "\(id)",
      "status": "\(status.rawValue)",
      "command": "\(command)",
      "cwd": "/tmp",
      "process_id": null,
      "command_actions": [
        {
          "type": "unknown",
          "command": "\(command)",
          "name": null,
          "path": null,
          "query": null
        }
      ],
      "live_output_preview": null,
      "aggregated_output": \(jsonString(output)),
      "preview": null,
      "exit_code": 1,
      "duration_ms": 42,
      "render_hints": {
        "can_expand": false,
        "default_expanded": false,
        "emphasized": false,
        "monospace_summary": false,
        "accent_tone": null
      }
    }
    """

    let row = try! decoder.decode(
      ServerConversationCommandExecutionRow.self,
      from: Data(payload.utf8)
    )

    return ServerConversationRowEntry(
      sessionId: "session-1",
      sequence: sequence,
      turnId: nil,
      turnStatus: .active,
      row: .commandExecution(row)
    )
  }

  private func jsonString(_ value: String?) -> String {
    guard let value else { return "null" }
    let encoded = try! JSONEncoder().encode(value)
    return String(decoding: encoded, as: UTF8.self)
  }
}
