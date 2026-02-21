import CoreGraphics
import Foundation
@testable import OrbitDock
import Testing

struct ConversationTimelinePipelineTests {
  @Test func reducerAppliesMessageActionsInOrder() {
    var source = makeSource(messages: [makeMessage(id: "m2", content: "two")])
    var ui = ConversationUIState()

    ConversationTimelineReducer.reduce(
      source: &source,
      ui: &ui,
      action: .prependMessages([makeMessage(id: "m1", content: "one")])
    )
    ConversationTimelineReducer.reduce(
      source: &source,
      ui: &ui,
      action: .appendMessages([makeMessage(id: "m3", content: "three")])
    )

    #expect(source.messages.map(\.id) == ["m1", "m2", "m3"])
  }

  @Test func reducerTogglesUiStateAndTracksWidthBucket() {
    var source = ConversationSourceState()
    var ui = ConversationUIState()

    ConversationTimelineReducer.reduce(source: &source, ui: &ui, action: .toggleToolCard("tool-a"))
    #expect(ui.expandedToolCards == ["tool-a"])

    ConversationTimelineReducer.reduce(source: &source, ui: &ui, action: .toggleToolCard("tool-a"))
    #expect(ui.expandedToolCards.isEmpty)

    ConversationTimelineReducer.reduce(source: &source, ui: &ui, action: .widthChanged(480))
    #expect(ui.widthBucket == ConversationTimelineReducer.widthBucket(for: 480))
  }

  @Test func projectorIsDeterministicForSameInput() {
    let messages = [
      makeMessage(id: "m1", content: "hello"),
      makeMessage(id: "m2", content: "world"),
    ]
    let source = makeSource(messages: messages)
    let ui = ConversationUIState(widthBucket: 12)

    let first = ConversationTimelineProjector.project(source: source, ui: ui)
    let second = ConversationTimelineProjector.project(source: source, ui: ui, previous: first)

    #expect(first.rows == second.rows)
    #expect(second.diff.insertions.isEmpty)
    #expect(second.diff.deletions.isEmpty)
    #expect(second.diff.reloads.isEmpty)
    #expect(second.dirtyRowIDs.isEmpty)
  }

  @Test func projectorProducesStableRowIDsAndAppendDiff() {
    let initialSource = makeSource(messages: [makeMessage(id: "m1", content: "one")])
    let ui = ConversationUIState(widthBucket: 10)
    let initial = ConversationTimelineProjector.project(source: initialSource, ui: ui)

    let appendedSource = makeSource(
      messages: [
        makeMessage(id: "m1", content: "one"),
        makeMessage(id: "m2", content: "two"),
      ]
    )
    let appended = ConversationTimelineProjector.project(source: appendedSource, ui: ui, previous: initial)

    #expect(appended.rows.map(\.id) == [.message("m1"), .message("m2"), .bottomSpacer])
    #expect(appended.diff.insertions == [1])
    #expect(appended.diff.deletions.isEmpty)
  }

  @Test func projectorTracksLayoutHashSeparatelyFromRenderHash() {
    let source = makeSource(
      messages: [
        makeMessage(id: "m1", content: "one"),
        makeMessage(id: "m2", content: "two"),
      ]
    )

    let uiA = ConversationUIState(widthBucket: 8)
    let uiB = ConversationUIState(widthBucket: 9)

    let first = ConversationTimelineProjector.project(source: source, ui: uiA)
    let second = ConversationTimelineProjector.project(source: source, ui: uiB, previous: first)

    #expect(first.rows.map(\.id) == second.rows.map(\.id))
    #expect(first.rows.map(\.renderHash) == second.rows.map(\.renderHash))
    #expect(first.rows.map(\.layoutHash) != second.rows.map(\.layoutHash))
    #expect(second.diff.reloads.isEmpty)
    #expect(second.dirtyRowIDs == Set(second.rows.map(\.id)))
  }

  @Test func projectorFlattensFocusedTurnsAndUsesRollupState() {
    let messages = [
      makeMessage(id: "u1", type: .user, content: "prompt"),
      makeMessage(id: "t1", type: .tool, content: "tool 1", toolName: "read"),
      makeMessage(id: "t2", type: .tool, content: "tool 2", toolName: "read"),
      makeMessage(id: "t3", type: .tool, content: "tool 3", toolName: "read"),
      makeMessage(id: "a1", type: .assistant, content: "response"),
    ]
    let turn = makeTurn(id: "turn-synth-1", number: 1, messages: messages)
    let source = makeSource(messages: messages, turns: [turn], chatViewMode: .focused)
    let collapsedUI = ConversationUIState(widthBucket: 12)
    let collapsed = ConversationTimelineProjector.project(source: source, ui: collapsedUI)

    // Rollup IDs are now constructed as turnRollupKey + group index
    let rollupID = "\(TimelineRowID.turnRollupKey(turn.id)):g0"
    #expect(collapsed.rows.map(\.kind) == [
      .turnHeader,
      .message,
      .rollupSummary,
      .tool,
      .tool,
      .message,
      .bottomSpacer,
    ])
    #expect(collapsed.rows.contains(where: { $0.id == .rollupSummary(rollupID) }))

    let visibleToolIDs = collapsed.rows.filter { $0.kind == .tool }.map(\.id)
    #expect(visibleToolIDs == [.tool("t2"), .tool("t3")])

    let expandedUI = ConversationUIState(expandedRollups: [rollupID], widthBucket: 12)
    let expanded = ConversationTimelineProjector.project(source: source, ui: expandedUI, previous: collapsed)

    let expandedToolIDs = expanded.rows.filter { $0.kind == .tool }.map(\.id)
    #expect(expandedToolIDs == [.tool("t1"), .tool("t2"), .tool("t3")])
    #expect(expanded.rows.contains(where: { $0.id == .rollupSummary(rollupID) }))
    #expect(expanded.diff.insertions == [3])
    #expect(expanded.diff.deletions.isEmpty)
    let rollupSummaryID = TimelineRowID.rollupSummary(rollupID)
    #expect(expanded.dirtyRowIDs.contains(rollupSummaryID))
  }

  @Test func projectorMarksToolRowDirtyWhenToolExpansionChanges() {
    let messages = [
      makeMessage(id: "u1", type: .user, content: "prompt"),
      makeMessage(id: "t1", type: .tool, content: "tool 1", toolName: "bash"),
      makeMessage(id: "a1", type: .assistant, content: "response"),
    ]
    let turn = makeTurn(id: "turn-synth-1", number: 1, messages: messages)
    let source = makeSource(messages: messages, turns: [turn], chatViewMode: .focused)

    let collapsed = ConversationTimelineProjector.project(source: source, ui: ConversationUIState(widthBucket: 12))
    let expandedUI = ConversationUIState(expandedToolCards: ["t1"], widthBucket: 12)
    let expanded = ConversationTimelineProjector.project(source: source, ui: expandedUI, previous: collapsed)

    #expect(expanded.rows.map(\.kind) == [.turnHeader, .message, .tool, .message, .bottomSpacer])
    #expect(expanded.diff.reloads == [2])
    #expect(expanded.dirtyRowIDs.contains(.tool("t1")))
  }

  @Test func heightCacheKeyHashesDeterministically() {
    let keyA = HeightCacheKey(rowID: .message("m1"), widthBucket: 8, layoutHash: 111)
    let keyB = HeightCacheKey(rowID: .message("m1"), widthBucket: 8, layoutHash: 111)
    let keyC = HeightCacheKey(rowID: .message("m1"), widthBucket: 8, layoutHash: 222)

    #expect(keyA == keyB)
    #expect(keyA != keyC)
    #expect(Set([keyA, keyB, keyC]).count == 2)
  }

  @MainActor
  @Test func heightEngineEvictsStaleKeysForSameRowID() {
    let engine = ConversationHeightEngine()
    let rowID = TimelineRowID.message("m1")
    let oldKey = HeightCacheKey(rowID: rowID, widthBucket: 8, layoutHash: 111)
    let newKey = HeightCacheKey(rowID: rowID, widthBucket: 8, layoutHash: 222)

    engine.store(64, for: oldKey)
    engine.store(72, for: newKey)

    #expect(engine.height(for: oldKey) == nil)
    #expect(engine.height(for: newKey) == 72)

    engine.invalidate(rowID: rowID)
    #expect(engine.height(for: newKey) == nil)
  }

  @Test func scrollAnchorMathDetectsPrependAndRestoresViewport() {
    let oldIDs: [TimelineRowID] = [.message("m2"), .bottomSpacer]
    let newIDs: [TimelineRowID] = [.message("m1"), .message("m2"), .bottomSpacer]

    #expect(ConversationScrollAnchorMath.isPrependTransition(from: oldIDs, to: newIDs))
    #expect(!ConversationScrollAnchorMath.isPrependTransition(from: newIDs, to: oldIDs))

    let delta = ConversationScrollAnchorMath.captureDelta(viewportTopY: 212, rowTopY: 200)
    #expect(delta == 12)

    let restored = ConversationScrollAnchorMath.restoredViewportTop(
      rowTopY: 320,
      deltaFromRowTop: delta,
      contentHeight: 1_000,
      viewportHeight: 300
    )
    #expect(restored == 332)

    let clamped = ConversationScrollAnchorMath.restoredViewportTop(
      rowTopY: 480,
      deltaFromRowTop: 40,
      contentHeight: 500,
      viewportHeight: 300
    )
    #expect(clamped == 200)
  }

  private func makeSource(
    messages: [TranscriptMessage],
    turns: [TurnSummary] = [],
    chatViewMode: ChatViewMode = .verbose
  ) -> ConversationSourceState {
    ConversationSourceState(
      messages: messages,
      turns: turns,
      metadata: .init(
        chatViewMode: chatViewMode,
        isSessionActive: false,
        workStatus: .unknown,
        currentTool: nil,
        pendingToolName: nil,
        pendingToolInput: nil,
        currentPrompt: nil,
        messageCount: messages.count,
        remainingLoadCount: 0,
        hasMoreMessages: false
      )
    )
  }

  private func makeTurn(id: String, number: Int, messages: [TranscriptMessage], status: TurnStatus = .completed)
    -> TurnSummary
  {
    TurnSummary(
      id: id,
      turnNumber: number,
      startTimestamp: messages.first?.timestamp,
      endTimestamp: messages.last?.timestamp,
      messages: messages,
      toolsUsed: messages.filter { $0.type == .tool }.compactMap(\.toolName),
      changedFiles: [],
      status: status,
      diff: nil,
      tokenUsage: nil,
      tokenDelta: nil
    )
  }

  private func makeMessage(
    id: String,
    type: TranscriptMessage.MessageType = .assistant,
    content: String,
    toolName: String? = nil
  ) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      type: type,
      content: content,
      timestamp: Date(timeIntervalSince1970: 1),
      toolName: toolName,
      toolInput: nil,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )
  }
}
