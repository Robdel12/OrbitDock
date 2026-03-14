import XCTest
@testable import OrbitDock

#if os(macOS)

  @MainActor
  final class MacTimelineViewStateBuilderTests: XCTestCase {
    func testBuilderUsesStreamingPatchContentForVisibleMessageRow() {
      let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-1")
      let store = ConversationRenderStore(session: session, provider: .codex, model: "gpt-5.4")

      store.applyStructure(
        ConversationStructureSnapshot(
          session: session,
          rows: [
            ConversationRowRecord(
              id: "message-1",
              session: session,
              kind: .message,
              payload: .message(
                .init(
                  messageID: "message-1",
                  role: .assistant,
                  speaker: "gpt-5.4",
                  text: "Hello",
                  timestamp: nil,
                  contentSignature: 1
                )
              ),
              sequence: 1,
              isStreaming: true
            )
          ]
        )
      )
      store.applyStreaming([
        StreamingMessageState(session: session, messageID: "message-1", content: "Hello world")
      ])

      let viewState = MacTimelineViewStateBuilder.build(
        renderStore: store,
        messagesByID: [
          "message-1": TranscriptMessage(
            id: "message-1",
            sequence: 1,
            type: .assistant,
            content: "Hello",
            timestamp: Date(),
            isInProgress: true
          )
        ],
        chatViewMode: .verbose,
        expansionState: .init(),
        expandedToolIDs: [],
        loadState: .ready,
        remainingLoadCount: 0,
        isPinnedToBottom: true,
        unreadCount: 0
      )

      guard case let .message(record)? = viewState.rows.first else {
        return XCTFail("expected first row to be a message")
      }

      XCTAssertEqual(record.model.content, "Hello world")
      XCTAssertEqual(record.model.messageType, NativeRichMessageRowModel.MessageType.assistant)
      XCTAssertEqual(record.model.renderMode, NativeRichMessageRowModel.RenderMode.streamingPlainText)
    }

    func testBuilderPrependsLoadMoreWithoutScanningNonMessageRows() {
      let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-2")
      let store = ConversationRenderStore(session: session)

      store.applyStructure(
        ConversationStructureSnapshot(
          session: session,
          rows: [
            ConversationRowRecord(
              id: "worker-1",
              session: session,
              kind: .worker,
              payload: .worker(messageID: "message-1", workerID: "worker-1"),
              sequence: 1
            ),
            ConversationRowRecord(
              id: "message-2",
              session: session,
              kind: .message,
              payload: .message(
                .init(
                  messageID: "message-2",
                  role: .user,
                  speaker: "You",
                  text: "Ship it",
                  timestamp: nil,
                  contentSignature: 2
                )
              ),
              sequence: 2
            )
          ],
          oldestLoadedSequence: 1,
          newestLoadedSequence: 2,
          hasMoreHistoryBefore: true
        )
      )

      let viewState = MacTimelineViewStateBuilder.build(
        renderStore: store,
        messagesByID: [
          "message-2": TranscriptMessage(
            id: "message-2",
            sequence: 2,
            type: .user,
            content: "Ship it",
            timestamp: Date()
          )
        ],
        chatViewMode: .verbose,
        expansionState: .init(),
        expandedToolIDs: [],
        loadState: .ready,
        remainingLoadCount: 12,
        isPinnedToBottom: false,
        unreadCount: 3
      )

      XCTAssertEqual(viewState.rows.count, 3)
      guard case let .loadMore(loadMore)? = viewState.rows.first else {
        return XCTFail("expected load-more row first")
      }
      XCTAssertEqual(loadMore.remainingCount, 12)

      guard case let .message(message)? = viewState.rows.dropLast().last else {
        return XCTFail("expected trailing content row to be a message")
      }
      XCTAssertEqual(message.model.content, "Ship it")
      XCTAssertEqual(message.model.messageType, NativeRichMessageRowModel.MessageType.user)

      guard case .spacer? = viewState.rows.last else {
        return XCTFail("expected bottom spacer row")
      }
    }

    func testBuilderAddsWorkerMetadataStateRowBeforeMessages() {
      let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-3")
      let store = ConversationRenderStore(session: session, provider: .codex, model: "gpt-5.4")

      store.applyStructure(
        ConversationStructureSnapshot(
          session: session,
          rows: [
            ConversationRowRecord(
              id: "message-1",
              session: session,
              kind: .message,
              payload: .message(
                .init(
                  messageID: "message-1",
                  role: .assistant,
                  speaker: "gpt-5.4",
                  text: "Still running tests.",
                  timestamp: nil,
                  contentSignature: 3
                )
              ),
              sequence: 1
            )
          ]
        )
      )

      store.applyMetadata(
        ConversationMetadataSnapshot(
          session: session,
          workStatus: .working,
          currentTool: "Bash",
          workers: [
            ConversationWorkerSnapshot(
              id: "worker-1",
              title: "Descartes",
              subtitle: "Smoke-test the auth flow",
              status: .running,
              agentType: "worker",
              provider: .codex,
              model: "gpt-5.4",
              taskSummary: "Smoke-test the auth flow",
              resultSummary: nil,
              errorSummary: nil,
              startedAt: "2026-03-12T12:00:00Z",
              lastActivityAt: "2026-03-12T12:05:00Z",
              endedAt: nil,
              parentWorkerID: nil
            )
          ],
          activeWorkerIDs: ["worker-1"],
          workerInspector: .init(
            selectedWorkerID: "worker-1",
            selectedWorker: ConversationWorkerSnapshot(
              id: "worker-1",
              title: "Descartes",
              subtitle: "Smoke-test the auth flow",
              status: .running,
              agentType: "worker",
              provider: .codex,
              model: "gpt-5.4",
              taskSummary: "Smoke-test the auth flow",
              resultSummary: nil,
              errorSummary: nil,
              startedAt: "2026-03-12T12:00:00Z",
              lastActivityAt: "2026-03-12T12:05:00Z",
              endedAt: nil,
              parentWorkerID: nil
            ),
            tools: [],
            threadEntries: [],
            childWorkerIDs: []
          ),
          provider: .codex,
          model: "gpt-5.4"
        )
      )

      let viewState = MacTimelineViewStateBuilder.build(
        renderStore: store,
        messagesByID: [
          "message-1": TranscriptMessage(
            id: "message-1",
            sequence: 1,
            type: .assistant,
            content: "Still running tests.",
            timestamp: Date()
          )
        ],
        chatViewMode: .verbose,
        expansionState: .init(),
        expandedToolIDs: [],
        loadState: .ready,
        remainingLoadCount: 0,
        isPinnedToBottom: true,
        unreadCount: 0
      )

      // Workers + live indicator + message + spacer = 4 rows
      XCTAssertEqual(viewState.rows.count, 4)
      guard case let .utility(utility)? = viewState.rows.first else {
        return XCTFail("expected first row to be a metadata utility row")
      }
      XCTAssertEqual(utility.kind, MacTimelineUtilityRecord.Kind.workers)
      XCTAssertEqual(utility.title, "Worker in play")
      XCTAssertEqual(utility.subtitle, "1 active in this turn")
      XCTAssertEqual(utility.spotlight, "Descartes is on it: Smoke-test the auth flow")

      guard case .utility(let liveRow) = viewState.rows[1] else {
        return XCTFail("expected second row to be a live indicator utility row")
      }
      XCTAssertEqual(liveRow.kind, MacTimelineUtilityRecord.Kind.live)

      guard case .spacer? = viewState.rows.last else {
        return XCTFail("expected bottom spacer row")
      }
    }
  }

#endif
