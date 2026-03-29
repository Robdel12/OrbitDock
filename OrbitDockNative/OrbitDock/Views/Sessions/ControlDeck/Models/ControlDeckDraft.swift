import Foundation

struct ControlDeckDraft: Equatable {
  var text: String = ""
  var attachments = ControlDeckAttachmentState()
  var selectedSkillPaths: Set<String> = []
  var modelOverride: String?
  var effortOverride: String?

  var trimmedText: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var hasContent: Bool {
    !trimmedText.isEmpty || attachments.hasItems
  }

  mutating func clearAfterSubmit() {
    text = ""
    attachments.clearAll()
    selectedSkillPaths = []
    modelOverride = nil
    effortOverride = nil
  }

  // MARK: - Draft Persistence (survives navigation)

  private static var cache: [String: ControlDeckDraft] = [:]

  static func restore(for sessionId: String) -> ControlDeckDraft {
    cache[sessionId] ?? ControlDeckDraft()
  }

  static func save(_ draft: ControlDeckDraft, for sessionId: String) {
    if draft.hasContent {
      cache[sessionId] = draft
    } else {
      cache.removeValue(forKey: sessionId)
    }
  }

  static func clear(for sessionId: String) {
    cache.removeValue(forKey: sessionId)
  }
}
