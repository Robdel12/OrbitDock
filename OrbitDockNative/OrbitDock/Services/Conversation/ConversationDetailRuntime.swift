import Foundation
import Observation

@MainActor
@Observable
final class ConversationRenderStore {
  private(set) var session: ScopedSessionID
  private(set) var rows: [ConversationRowRecord] = []
  private(set) var metadata: ConversationMetadataSnapshot
  private(set) var streamingMessages: [String: StreamingMessageState] = [:]
  private(set) var isPinnedToBottom = true
  private(set) var unreadCount = 0

  init(session: ScopedSessionID, provider: Provider = .claude, model: String? = nil) {
    self.session = session
    self.metadata = ConversationMetadataSnapshot(session: session, provider: provider, model: model)
  }

  func applyStructure(_ snapshot: ConversationStructureSnapshot) {
    rows = snapshot.rows
  }

  func applyMetadata(_ snapshot: ConversationMetadataSnapshot) {
    metadata = snapshot
  }

  func applyStreaming(_ states: [StreamingMessageState]) {
    for state in states {
      if state.isFinal {
        streamingMessages.removeValue(forKey: state.messageID)
      } else {
        streamingMessages[state.messageID] = state
      }
    }
  }

  func setPinnedToBottom(_ pinned: Bool) {
    isPinnedToBottom = pinned
    if pinned {
      unreadCount = 0
    }
  }

  func appendUnread(_ count: Int) {
    guard !isPinnedToBottom else { return }
    unreadCount += count
  }
}

@MainActor
final class ConversationDetailRuntime {
  let session: ScopedSessionID
  let clients: ServerClients
  let renderStore: ConversationRenderStore

  private(set) var structureStore: ConversationStructureStore
  private(set) var metadataStore: ConversationMetadataStore
  private(set) var streamingRegistry: StreamingMessageRegistry

  init(session: ScopedSessionID, clients: ServerClients, provider: Provider = .claude, model: String? = nil) {
    self.session = session
    self.clients = clients
    renderStore = ConversationRenderStore(session: session, provider: provider, model: model)
    structureStore = ConversationStructureStore(session: session)
    metadataStore = ConversationMetadataStore(session: session, provider: provider, model: model)
    streamingRegistry = StreamingMessageRegistry(session: session)
  }

  func applyStructure(_ event: ConversationStructureEvent) {
    structureStore.apply(event)
    renderStore.applyStructure(structureStore.snapshot)
  }

  func hydrateStructure(
    messages: [TranscriptMessage],
    oldestLoadedSequence: UInt64?,
    newestLoadedSequence: UInt64?,
    hasMoreHistoryBefore: Bool
  ) {
    applyStructure(.bootstrap(
      rows: messages.map { message in
        ConversationRowRecord(
          id: message.id,
          session: session,
          kind: .message,
          payload: .message(.from(message, model: renderStore.metadata.model)),
          sequence: message.sequence,
          revision: UInt64(bitPattern: Int64(message.contentSignature)),
          isStreaming: message.isInProgress
        )
      },
      oldestLoadedSequence: oldestLoadedSequence,
      newestLoadedSequence: newestLoadedSequence,
      hasMoreHistoryBefore: hasMoreHistoryBefore
    ))
  }

  func applyMetadata(_ event: ConversationMetadataEvent) {
    metadataStore.apply(event)
    renderStore.applyMetadata(metadataStore.snapshot)
  }

  func hydrateMetadata(_ input: ConversationMetadataInput) {
    applyMetadata(.hydrate(input))
  }

  func applyStreaming(_ event: StreamingMessageEvent) {
    streamingRegistry.apply(event)
    renderStore.applyStreaming(streamingRegistry.drainPendingPatches())
  }

  func selectWorker(_ workerID: String?) {
    applyMetadata(.selectWorker(workerID))
  }
}
