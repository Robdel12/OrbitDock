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

  @Test func projectorMarksMessageRowDirtyWhenHeaderVisibilityChanges() {
    let initialSource = makeSource(messages: [makeMessage(id: "a1", type: .assistant, content: "first")])
    let ui = ConversationUIState(widthBucket: 12)
    let initial = ConversationTimelineProjector.project(source: initialSource, ui: ui)

    let appendedSource = makeSource(messages: [
      makeMessage(id: "a0", type: .assistant, content: "previous"),
      makeMessage(id: "a1", type: .assistant, content: "first"),
    ])
    let appended = ConversationTimelineProjector.project(source: appendedSource, ui: ui, previous: initial)

    #expect(appended.diff.insertions == [0])
    #expect(appended.diff.reloads == [1])
    #expect(appended.dirtyRowIDs.contains(.message("a0")))
    #expect(appended.dirtyRowIDs.contains(.message("a1")))

    guard appended.rows.count >= 2 else {
      Issue.record("Expected two message rows before bottom spacer")
      return
    }

    guard case let .message(firstID, firstShowHeader) = appended.rows[0].payload else {
      Issue.record("Expected first projected row to be a message payload")
      return
    }
    #expect(firstID == "a0")
    #expect(firstShowHeader)

    guard case let .message(secondID, secondShowHeader) = appended.rows[1].payload else {
      Issue.record("Expected second projected row to be a message payload")
      return
    }
    #expect(secondID == "a1")
    #expect(!secondShowHeader)
  }

  @Test func projectorEncodesHeaderVisibilityInMessagePayload() {
    let source = makeSource(
      messages: [
        makeMessage(id: "a1", content: "first"),
        makeMessage(id: "a2", content: "second"),
      ]
    )

    let projected = ConversationTimelineProjector.project(source: source, ui: ConversationUIState(widthBucket: 12))

    guard projected.rows.count >= 2 else {
      Issue.record("Expected two message rows")
      return
    }

    if case let .message(id, showHeader) = projected.rows[0].payload {
      #expect(id == "a1")
      #expect(showHeader)
    } else {
      Issue.record("Expected first row to be a message payload")
    }

    if case let .message(id, showHeader) = projected.rows[1].payload {
      #expect(id == "a2")
      #expect(!showHeader)
    } else {
      Issue.record("Expected second row to be a message payload")
    }
  }

  @Test func projectorReloadsNeighborRowWhenHeaderVisibilityChanges() {
    let initialSource = makeSource(
      messages: [
        makeMessage(id: "m1", content: "assistant"),
        makeMessage(id: "m2", content: "follow-up"),
      ]
    )
    let ui = ConversationUIState(widthBucket: 12)
    let initial = ConversationTimelineProjector.project(source: initialSource, ui: ui)

    let updatedSource = makeSource(
      messages: [
        makeMessage(id: "m1", type: .user, content: "user prompt"),
        makeMessage(id: "m2", content: "follow-up"),
      ]
    )
    let updated = ConversationTimelineProjector.project(source: updatedSource, ui: ui, previous: initial)

    #expect(updated.diff.reloads == [0, 1])

    guard updated.rows.count >= 2 else {
      Issue.record("Expected two message rows")
      return
    }

    if case let .message(id, showHeader) = updated.rows[1].payload {
      #expect(id == "m2")
      #expect(showHeader)
    } else {
      Issue.record("Expected second row to be a message payload")
    }
  }

  @Test func projectorMarksImageRowDirtyWhenAttachmentSourceResolves() {
    let attachment = ServerAttachmentImageReference(
      endpointId: nil,
      sessionId: "session-1",
      attachmentId: "attachment-1"
    )
    let unresolvedImage = MessageImage(
      id: "image-1",
      source: .serverAttachment(attachment),
      mimeType: "image/png",
      byteCount: 48_000,
      pixelWidth: 1200,
      pixelHeight: 800
    )
    let resolvedImage = MessageImage(
      id: "image-1",
      source: .filePath("/tmp/session-1/attachment-1.png"),
      mimeType: "image/png",
      byteCount: 48_000,
      pixelWidth: 1200,
      pixelHeight: 800
    )

    let initialSource = makeSource(messages: [
      makeMessage(id: "m1", content: "image", images: [unresolvedImage]),
    ])
    let ui = ConversationUIState(widthBucket: 12)
    let initial = ConversationTimelineProjector.project(source: initialSource, ui: ui)

    let resolvedSource = makeSource(messages: [
      makeMessage(id: "m1", content: "image", images: [resolvedImage]),
    ])
    let resolved = ConversationTimelineProjector.project(source: resolvedSource, ui: ui, previous: initial)

    #expect(resolved.diff.reloads == [0])
    #expect(resolved.dirtyRowIDs.contains(.message("m1")))
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

  @Test func projectorShowsEveryMessageInFocusedTurns() {
    let messages = [
      makeMessage(id: "u1", type: .user, content: "prompt"),
      makeMessage(id: "a1", type: .assistant, content: "planning"),
      makeMessage(id: "t1", type: .tool, content: "tool 1", toolName: "read"),
      makeMessage(id: "t2", type: .tool, content: "tool 2", toolName: "read"),
      makeMessage(id: "a2", type: .assistant, content: "response"),
    ]
    let turn = makeTurn(id: "turn-synth-1", number: 1, messages: messages)
    let source = makeSource(messages: messages, turns: [turn], chatViewMode: .focused)
    let projected = ConversationTimelineProjector.project(source: source, ui: ConversationUIState(widthBucket: 12))

    #expect(projected.rows.map(\.kind) == [
      .turnHeader,
      .message,
      .message,
      .tool,
      .tool,
      .message,
      .bottomSpacer,
    ])
    #expect(projected.rows.map(\.id) == [
      .turnHeader(turn.id),
      .message("u1"),
      .message("a1"),
      .tool("t1"),
      .tool("t2"),
      .message("a2"),
      .bottomSpacer,
    ])
  }

  @Test func projectorKeepsToolHeavyHistoricalTurnsReadableInFocusedMode() {
    let messages = [
      makeMessage(id: "u1", type: .user, content: "Let’s try a few different designs"),
      makeMessage(id: "a1", type: .assistant, content: "Good feedback — the latch is everything."),
      makeMessage(id: "t1", type: .tool, content: "", toolName: "Write", toolOutput: "ok"),
      makeMessage(id: "t2", type: .tool, content: "", toolName: "Bash", toolOutput: "ok"),
      makeMessage(id: "t3", type: .tool, content: "", toolName: "Read", toolOutput: "ok"),
      makeMessage(id: "a2", type: .assistant, content: "Here are the three designs."),
      makeMessage(id: "u2", type: .user, content: "If we can, it’d be cool to produce them all"),
      makeMessage(id: "a3", type: .assistant, content: "Let me export all three as STLs."),
      makeMessage(id: "t4", type: .tool, content: "", toolName: "Bash", toolOutput: "ok"),
      makeMessage(id: "a4", type: .assistant, content: "All three are manifold, no errors."),
    ]
    let turns = [
      makeTurn(id: "turn-synth-1", number: 1, messages: Array(messages[0...5])),
      makeTurn(id: "turn-synth-2", number: 2, messages: Array(messages[6...9])),
    ]
    let source = makeSource(messages: messages, turns: turns, chatViewMode: .focused)

    let projected = ConversationTimelineProjector.project(source: source, ui: ConversationUIState(widthBucket: 12))

    let kinds = projected.rows.map(\.kind)
    #expect(kinds == [
      .turnHeader, .message, .message, .rollupSummary, .tool, .tool, .message,
      .turnHeader, .message, .message, .tool, .message,
      .bottomSpacer,
    ])

    let rowIDs = projected.rows.map(\.id)
    #expect(rowIDs.contains(.message("a1")))
    #expect(rowIDs.contains(.message("a2")))
    #expect(rowIDs.contains(.message("a3")))
    #expect(rowIDs.contains(.message("a4")))
    #expect(rowIDs.contains(.tool("t2")))
    #expect(rowIDs.contains(.tool("t3")))
    #expect(rowIDs.contains(.tool("t4")))
    #expect(rowIDs.contains(.rollupSummary("timeline:turn-rollup:turn-synth-1:0")))
    #expect(!rowIDs.contains(.tool("t1")))
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

  @Test func projectorTreatsShellMessagesAsToolRows() {
    let messages = [
      makeMessage(id: "u1", type: .user, content: "run it"),
      makeMessage(id: "s1", type: .shell, content: "pwd"),
      makeMessage(id: "a1", type: .assistant, content: "done"),
    ]
    let source = makeSource(messages: messages, chatViewMode: .verbose)

    let projected = ConversationTimelineProjector.project(source: source, ui: ConversationUIState(widthBucket: 12))
    #expect(projected.rows.map(\.id) == [.message("u1"), .tool("s1"), .message("a1"), .bottomSpacer])
  }

  @Test func projectorSuppressesRedundantEscalatedApprovalNarrationWhenCardIsVisible() {
    let pendingWrapped = "/bin/zsh -lc xcodebuild -project OrbitDock.xcodeproj -scheme OrbitDock -showdestinations"
    let narration = """
    # Requesting escalated command execution

    ```bash
    xcodebuild -project OrbitDock.xcodeproj -scheme OrbitDock -showdestinations
    ```
    """
    let followup = makeMessage(id: "a2", type: .assistant, content: "Waiting for approval.")
    let metadata = ConversationSourceState.SessionMetadata(
      chatViewMode: .verbose,
      isSessionActive: true,
      workStatus: .permission,
      currentTool: nil,
      pendingToolName: "Bash",
      pendingApprovalCommand: pendingWrapped,
      pendingPermissionDetail: nil,
      currentPrompt: nil,
      messageCount: 2,
      remainingLoadCount: 0,
      hasMoreMessages: false,
      needsApprovalCard: true,
      approvalMode: .permission,
      pendingQuestion: nil,
      pendingApprovalId: "req-1",
      isDirectSession: true,
      isDirectCodexSession: true,
      supportsRichToolingCards: true,
      sessionId: "session-1",
      projectPath: "/tmp/project"
    )

    let source = ConversationSourceState(
      messages: [
        makeMessage(id: "a1", type: .assistant, content: narration),
        followup,
      ],
      turns: [],
      metadata: metadata
    )

    let projected = ConversationTimelineProjector.project(source: source, ui: ConversationUIState(widthBucket: 12))
    let rowIDs: [TimelineRowID] = projected.rows.map(\.id)

    #expect(!rowIDs.contains(TimelineRowID.message("a1")))
    #expect(rowIDs.contains(TimelineRowID.message("a2")))
    #expect(rowIDs.contains(TimelineRowID.approvalCard))
  }

  @Test func projectorSuppressesDuplicatePendingBashToolRowWhenApprovalCardIsVisible() {
    let wrappedCommand = "/bin/zsh -lc xcodebuild -project OrbitDock.xcodeproj -scheme OrbitDock -showdestinations"
    let pendingTool = TranscriptMessage(
      id: "t-approval",
      type: .tool,
      content: wrappedCommand,
      timestamp: Date(timeIntervalSince1970: 1),
      toolName: "Bash",
      toolInput: ["command": wrappedCommand],
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )
    let metadata = ConversationSourceState.SessionMetadata(
      chatViewMode: .verbose,
      isSessionActive: true,
      workStatus: .permission,
      currentTool: nil,
      pendingToolName: "Bash",
      pendingApprovalCommand: wrappedCommand,
      pendingPermissionDetail: nil,
      currentPrompt: nil,
      messageCount: 1,
      remainingLoadCount: 0,
      hasMoreMessages: false,
      needsApprovalCard: true,
      approvalMode: .permission,
      pendingQuestion: nil,
      pendingApprovalId: "req-2",
      isDirectSession: true,
      isDirectCodexSession: true,
      supportsRichToolingCards: true,
      sessionId: "session-1",
      projectPath: "/tmp/project"
    )
    let source = ConversationSourceState(messages: [pendingTool], turns: [], metadata: metadata)

    let projected = ConversationTimelineProjector.project(source: source, ui: ConversationUIState(widthBucket: 12))
    let rowIDs: [TimelineRowID] = projected.rows.map(\.id)

    #expect(!rowIDs.contains(TimelineRowID.tool("t-approval")))
    #expect(rowIDs.contains(TimelineRowID.approvalCard))
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

  @Test func renderMessageNormalizerDeduplicatesIDsWithoutReorderingTimeline() {
    let duplicate = makeMessage(id: "m1", content: "newest")
    let original = makeMessage(id: "m1", content: "original")
    let other = makeMessage(id: "m2", content: "second")

    let result = ConversationRenderMessageNormalizer.normalize(
      [original, other, duplicate],
      sessionId: "session-1",
      source: "test"
    )

    #expect(result.map(\.id) == ["m1", "m2"])
    #expect(result[0].content == "newest")
    #expect(result[1].content == "second")
  }

  @Test func renderMessageNormalizerSynthesizesStableIDsForEmptyMessages() {
    let first = makeMessage(id: " ", content: "first")
    let second = makeMessage(id: "", content: "second")

    let result = ConversationRenderMessageNormalizer.normalize(
      [first, second],
      sessionId: "session-2",
      source: "test"
    )

    #expect(result.count == 2)
    #expect(result.allSatisfy { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(Set(result.map(\.id)).count == 2)
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
        pendingApprovalCommand: nil,
        pendingPermissionDetail: nil,
        currentPrompt: nil,
        messageCount: messages.count,
        remainingLoadCount: 0,
        hasMoreMessages: false,
        needsApprovalCard: false,
        approvalMode: .none,
        pendingQuestion: nil,
        pendingApprovalId: nil,
        isDirectSession: false,
        isDirectCodexSession: false,
        supportsRichToolingCards: false,
        sessionId: nil,
        projectPath: nil
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
    toolName: String? = nil,
    toolOutput: String? = nil,
    images: [MessageImage] = []
  ) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      type: type,
      content: content,
      timestamp: Date(timeIntervalSince1970: 1),
      toolName: toolName,
      toolInput: nil,
      toolOutput: toolOutput,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil,
      images: images
    )
  }
}
