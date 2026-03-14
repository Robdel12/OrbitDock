import Foundation

enum ConversationMessageRole: String, Sendable, Equatable {
  case user
  case assistant
  case thinking
  case system
}

struct ConversationMessageSnapshot: Sendable, Equatable {
  let messageID: String
  let role: ConversationMessageRole
  let speaker: String
  let text: String
  let timestamp: Date?
  let contentSignature: Int
}

enum ConversationRowKind: String, Sendable, Equatable {
  case message
  case tool
  case worker
  case approval
  case status
  case spacer
}

enum ConversationRowPayload: Sendable, Equatable {
  case message(ConversationMessageSnapshot)
  case tool(messageID: String)
  case worker(messageID: String, workerID: String?)
  case approval(approvalID: String)
  case status(key: String)
  case spacer
}

struct ConversationRowRecord: Identifiable, Sendable, Equatable {
  let id: String
  let session: ScopedSessionID
  let kind: ConversationRowKind
  let payload: ConversationRowPayload
  let sequence: UInt64?
  let revision: UInt64
  let isStreaming: Bool

  init(
    id: String,
    session: ScopedSessionID,
    kind: ConversationRowKind,
    payload: ConversationRowPayload,
    sequence: UInt64? = nil,
    revision: UInt64 = 0,
    isStreaming: Bool = false
  ) {
    self.id = id
    self.session = session
    self.kind = kind
    self.payload = payload
    self.sequence = sequence
    self.revision = revision
    self.isStreaming = isStreaming
  }
}

extension ConversationMessageSnapshot {
  static func from(_ message: TranscriptMessage, model: String? = nil) -> Self {
    let role: ConversationMessageRole = if message.isUser || message.isShell {
      .user
    } else if message.isThinking {
      .thinking
    } else if message.isAssistant {
      .assistant
    } else {
      .system
    }

    let speaker: String = switch role {
      case .user:
        "You"
      case .assistant:
        model ?? "Assistant"
      case .thinking:
        "Reasoning"
      case .system:
        "System"
    }

    return Self(
      messageID: message.id,
      role: role,
      speaker: speaker,
      text: message.content,
      timestamp: message.timestamp,
      contentSignature: message.contentSignature
    )
  }
}
