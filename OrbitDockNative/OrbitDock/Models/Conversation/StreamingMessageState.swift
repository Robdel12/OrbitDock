import Foundation

struct StreamingMessageState: Sendable, Equatable, Identifiable {
  let id: String
  let session: ScopedSessionID
  let messageID: String
  let content: String
  let revision: UInt64
  let invalidatesHeight: Bool
  let isFinal: Bool

  init(
    session: ScopedSessionID,
    messageID: String,
    content: String,
    revision: UInt64 = 0,
    invalidatesHeight: Bool = false,
    isFinal: Bool = false
  ) {
    self.id = "\(session.scopedID):\(messageID)"
    self.session = session
    self.messageID = messageID
    self.content = content
    self.revision = revision
    self.invalidatesHeight = invalidatesHeight
    self.isFinal = isFinal
  }
}
