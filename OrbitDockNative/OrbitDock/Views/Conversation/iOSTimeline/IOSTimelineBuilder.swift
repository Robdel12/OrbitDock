import Foundation

#if os(iOS)

  enum IOSTimelineBuilder {
    static func build(
      renderStore: ConversationRenderStore,
      messagesByID: [String: TranscriptMessage],
      hasMoreMessages: Bool,
      chatViewMode: ChatViewMode,
      expansionState: ConversationTimelineExpansionState = .init()
    ) -> [TimelineRow] {
      ConversationSemanticTimelineBuilder.build(
        renderStore: renderStore,
        messagesByID: messagesByID,
        hasMoreMessages: hasMoreMessages,
        chatViewMode: chatViewMode,
        expansionState: expansionState
      )
    }
  }

#endif
