import Foundation

enum ControlDeckSubmitEncoder {
  static func encode(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String],
    availableSkills: [ControlDeckSkill]
  ) -> ServerControlDeckSubmitTurnRequest {
    ServerControlDeckSubmitTurnRequest(
      text: draft.trimmedText,
      attachments: encodeAttachments(draft.attachments, uploadedImageIds: uploadedImageIds),
      skills: encodeSkills(selectedPaths: draft.selectedSkillPaths, availableSkills: availableSkills),
      overrides: encodeOverrides(model: draft.modelOverride, effort: draft.effortOverride)
    )
  }

  // MARK: - Attachments

  static func encodeSteerImages(
    _ state: ControlDeckAttachmentState,
    uploadedImageIds: [String: String]
  ) -> [ServerImageInput] {
    state.images.compactMap { image in
      guard let serverId = uploadedImageIds[image.localId] else { return nil }
      return ServerImageInput(
        inputType: "attachment",
        value: serverId,
        displayName: image.displayName,
        pixelWidth: image.pixelWidth,
        pixelHeight: image.pixelHeight
      )
    }
  }

  static func encodeSteerMentions(_ state: ControlDeckAttachmentState) -> [ServerMentionInput] {
    state.mentions.map { mention in
      ServerMentionInput(name: mention.name, path: mention.absolutePath)
    }
  }

  private static func encodeAttachments(
    _ state: ControlDeckAttachmentState,
    uploadedImageIds: [String: String]
  ) -> [ServerControlDeckAttachmentRef] {
    state.items.compactMap { item in
      switch item.kind {
        case let .image(image):
          guard let serverId = uploadedImageIds[image.localId] else { return nil }
          return .image(ServerControlDeckImageAttachmentRef(
            attachmentId: serverId,
            displayName: image.displayName
          ))
        case let .mention(mention):
          return .mention(ServerControlDeckMentionRef(
            mentionId: mention.fileId,
            kind: encodeMentionKind(mention.kind),
            name: mention.name,
            path: mention.absolutePath,
            relativePath: mention.relativePath
          ))
      }
    }
  }

  // MARK: - Skills

  private static func encodeSkills(
    selectedPaths: Set<String>,
    availableSkills: [ControlDeckSkill]
  ) -> [ServerControlDeckSkillRef] {
    availableSkills
      .filter { selectedPaths.contains($0.path) }
      .map { ServerControlDeckSkillRef(name: $0.name, path: $0.path) }
  }

  // MARK: - Overrides

  private static func encodeOverrides(model: String?, effort: String?) -> ServerControlDeckTurnOverrides? {
    guard model != nil || effort != nil else { return nil }
    return ServerControlDeckTurnOverrides(model: model, effort: effort)
  }

  // MARK: - Mention Kind

  private static func encodeMentionKind(_ kind: ControlDeckMentionKind) -> ServerControlDeckMentionKind {
    switch kind {
      case .file: .file
      case .mcpResource: .mcpResource
      case .url: .url
      case .symbol: .symbol
      case .generic: .generic
    }
  }
}
