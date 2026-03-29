import Foundation

// MARK: - Attachment State

struct ControlDeckAttachmentState: Equatable {
  var items: [ControlDeckAttachmentItem] = []

  var hasItems: Bool {
    !items.isEmpty
  }

  var images: [ControlDeckImageDraft] {
    items.compactMap { item in
      if case let .image(draft) = item.kind { return draft }
      return nil
    }
  }

  var mentions: [ControlDeckMentionDraft] {
    items.compactMap { item in
      if case let .mention(draft) = item.kind { return draft }
      return nil
    }
  }

  mutating func appendImage(_ image: ControlDeckImageDraft) {
    items.append(ControlDeckAttachmentItem(
      id: image.localId,
      kind: .image(image)
    ))
  }

  @discardableResult
  mutating func appendMention(_ mention: ControlDeckMentionDraft) -> Bool {
    let alreadyAttached = mentions.contains { $0.absolutePath == mention.absolutePath }
    guard !alreadyAttached else { return false }
    items.append(ControlDeckAttachmentItem(
      id: mention.fileId,
      kind: .mention(mention)
    ))
    return true
  }

  mutating func remove(id: String) {
    items.removeAll { $0.id == id }
  }

  mutating func clearAll() {
    items = []
  }
}

// MARK: - Attachment Item

struct ControlDeckAttachmentItem: Identifiable, Equatable {
  let id: String
  let kind: Kind

  enum Kind: Equatable {
    case image(ControlDeckImageDraft)
    case mention(ControlDeckMentionDraft)
  }
}

// MARK: - Image Draft

struct ControlDeckImageDraft: Equatable {
  let localId: String
  let thumbnailData: Data?
  let uploadData: Data
  let uploadMimeType: String
  let displayName: String
  let pixelWidth: Int?
  let pixelHeight: Int?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.localId == rhs.localId
  }
}

// MARK: - Mention Draft

struct ControlDeckMentionDraft: Equatable {
  let fileId: String
  let name: String
  let absolutePath: String
  let relativePath: String?
  let kind: ControlDeckMentionKind
}

enum ControlDeckMentionKind: String, Sendable {
  case file
  case mcpResource
  case url
  case symbol
  case generic
}
