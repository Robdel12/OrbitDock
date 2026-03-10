import Foundation

func sanitizedConversationMessages(
  _ messages: [TranscriptMessage],
  sessionId: String?,
  source: String
) -> [TranscriptMessage] {
  guard !messages.isEmpty else { return messages }

  var seenIDs = Set<String>()
  seenIDs.reserveCapacity(messages.count)

  for message in messages {
    let trimmedID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedID.isEmpty || !seenIDs.insert(trimmedID).inserted {
      return ConversationRenderMessageNormalizer.normalize(messages, sessionId: sessionId, source: source)
    }
  }

  return messages
}
