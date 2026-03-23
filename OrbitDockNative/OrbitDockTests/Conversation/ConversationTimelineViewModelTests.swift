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

    #expect(viewModel.displayedEntries.count == 2)
    #expect(viewModel.displayedEntries.first?.id == "tool-3")

    guard case let .activityGroup(group)? = viewModel.displayedEntries.last?.row else {
      Issue.record("Expected focused timeline to build an activity group")
      return
    }

    #expect(group.childCount == 2)
    #expect(group.children.map(\.id) == ["tool-1", "tool-2"])
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

    #expect(viewModel.isExpanded("tool-1"))

    guard case let .tool(tool)? = viewModel.displayedEntries.first?.row else {
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

    #expect(viewModel.displayedEntries.isEmpty)
    #expect(!viewModel.isExpanded("tool-1"))
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
}
