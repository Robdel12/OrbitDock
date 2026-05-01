import Foundation

enum ControlDeckSubmitEncoder {
  struct SendPayload: Sendable {
    let content: String
    let model: String?
    let effort: String?
    var skills: [ServerSkillInput]
    let images: [ServerImageInput]
    let mentions: [ServerMentionInput]
  }

  static func encode(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String],
    availableSkills: [ControlDeckSkill]
  ) -> SendPayload {
    SendPayload(
      content: draft.trimmedText,
      model: draft.modelOverride,
      effort: draft.effortOverride,
      skills: ControlDeckSkillResolver.resolveSkillRefs(
        content: draft.text,
        selectedSkillPaths: draft.selectedSkillPaths,
        availableSkills: availableSkills
      ),
      images: encodeImages(draft.attachments, uploadedImageIds: uploadedImageIds),
      mentions: encodeMentions(draft.attachments)
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

  private static func encodeImages(
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

  private static func encodeMentions(_ state: ControlDeckAttachmentState) -> [ServerMentionInput] {
    state.mentions.map { mention in
      ServerMentionInput(name: mention.name, path: mention.absolutePath)
    }
  }
}
