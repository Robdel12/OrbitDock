import Foundation

struct DirectSessionComposerAttachmentState: Equatable {
  var images: [AttachedImage] = []
  var mentions: [AttachedMention] = []
  var isImageDropTargeted = false

  var hasAttachments: Bool {
    hasImages || hasMentions
  }

  var hasImages: Bool {
    !images.isEmpty
  }

  var hasMentions: Bool {
    !mentions.isEmpty
  }

  mutating func appendMention(_ mention: AttachedMention) -> Bool {
    guard !mentions.contains(where: { $0.id == mention.id }) else { return false }
    mentions.append(mention)
    return true
  }

  mutating func removeImage(id: String) {
    images.removeAll { $0.id == id }
  }

  mutating func removeMention(id: String) {
    mentions.removeAll { $0.id == id }
  }

  mutating func clearAfterSend() {
    images = []
    mentions = []
  }
}
