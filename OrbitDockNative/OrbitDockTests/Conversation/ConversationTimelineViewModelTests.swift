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

  @Test func focusedModePreservesFailedShellToolStatusInsideArchivedGroups() throws {
    let viewModel = ConversationTimelineViewModel()
    viewModel.bind(sessionId: "session-1")

    viewModel.apply(
      presentation: ConversationTimelinePresentation(
        entries: [
          makeToolEntry(
            id: "tool-1",
            sequence: 1,
            status: .failed,
            summary: "cat missing.txt",
            family: .shell,
            kind: .bash,
            toolType: "bash",
            shellExecution: ServerShellExecutionPayload(
              command: "cat missing.txt",
              cwd: "/tmp",
              actions: [
                ServerShellAction(
                  type: .unknown,
                  command: "cat missing.txt",
                  name: nil,
                  path: nil,
                  query: nil
                )
              ],
              liveOutputPreview: "No such file or directory",
              exitCode: 1
            )
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

  @Test func bootstrapMergePreservesLoadedHistoryOutsideLatestWindow() {
    let existingRows = (0..<100).map { makeToolEntry(id: "tool-\($0)", sequence: UInt64($0), summary: "Row \($0)") }
    let bootstrapRows = Array(existingRows.suffix(50))

    let merged = ConversationHistoryPaging.mergeBootstrap(
      existingRows: existingRows,
      existingHasMoreBefore: false,
      existingTotalRowCount: 100,
      bootstrapRows: bootstrapRows,
      bootstrapHasMoreBefore: true,
      bootstrapTotalRowCount: 100
    )

    #expect(merged.rows.count == 100)
    #expect(merged.rows.first?.sequence == 0)
    #expect(merged.rows.last?.sequence == 99)
    #expect(merged.hasMoreBefore == false)
  }

  @Test func bootstrapMergeDropsRetainedHistoryWhenConversationShrinks() {
    let existingRows = (0..<100).map { makeToolEntry(id: "tool-\($0)", sequence: UInt64($0), summary: "Row \($0)") }
    let bootstrapRows = Array(existingRows.suffix(40))

    let merged = ConversationHistoryPaging.mergeBootstrap(
      existingRows: existingRows,
      existingHasMoreBefore: false,
      existingTotalRowCount: 100,
      bootstrapRows: bootstrapRows,
      bootstrapHasMoreBefore: false,
      bootstrapTotalRowCount: 40
    )

    #expect(merged.rows.count == 40)
    #expect(merged.rows.first?.sequence == 60)
    #expect(merged.rows.last?.sequence == 99)
    #expect(merged.hasMoreBefore == false)
  }

  @Test func bootstrapMergePreservesNewerLocalRowsWhenBootstrapIsStale() {
    let existingRows = (0..<101).map { makeToolEntry(id: "tool-\($0)", sequence: UInt64($0), summary: "Row \($0)") }
    let bootstrapRows = Array(existingRows.dropLast().suffix(50))

    let merged = ConversationHistoryPaging.mergeBootstrap(
      existingRows: existingRows,
      existingHasMoreBefore: false,
      existingTotalRowCount: 101,
      bootstrapRows: bootstrapRows,
      bootstrapHasMoreBefore: true,
      bootstrapTotalRowCount: 100
    )

    #expect(merged.rows.count == 101)
    #expect(merged.rows.last?.sequence == 100)
    #expect(merged.totalRowCount == 101)
  }

  @Test func olderPageMergeKeepsRowsSortedWithoutDuplicates() {
    let existingRows = (50..<100).map { makeToolEntry(id: "tool-\($0)", sequence: UInt64($0), summary: "Row \($0)") }
    let page = ServerConversationHistoryPage(
      rows: (0..<60).map { makeToolEntry(id: "tool-\($0)", sequence: UInt64($0), summary: "Row \($0)") },
      totalRowCount: 100,
      hasMoreBefore: false,
      oldestSequence: 0,
      newestSequence: 59
    )

    let merged = ConversationHistoryPaging.mergeOlderPage(
      existingRows: existingRows,
      page: page
    )

    #expect(merged.rows.count == 100)
    #expect(merged.rows.first?.sequence == 0)
    #expect(merged.rows.last?.sequence == 99)
    #expect(merged.hasMoreBefore == false)
  }

  private func makeToolEntry(
    id: String,
    sequence: UInt64,
    status: ServerConversationToolStatus = .completed,
    summary: String,
    family: ServerConversationToolFamily = .agent,
    kind: ServerConversationToolKind = .taskOutput,
    toolType: String = "task",
    shellExecution: ServerShellExecutionPayload? = nil
  ) -> ServerConversationRowEntry {
    ServerConversationRowEntry(
      sessionId: "session-1",
      sequence: sequence,
      turnId: nil,
      turnStatus: .active,
      row: .tool(ServerConversationToolRow(
        id: id,
        provider: .codex,
        family: family,
        kind: kind,
        status: status,
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
          toolType: toolType,
          summaryFont: "system",
          displayTier: "standard",
          inputDisplay: nil,
          outputDisplay: nil,
          diffDisplay: nil,
          planExplanation: nil
        ),
        shellExecution: shellExecution
      ))
    )
  }
}
