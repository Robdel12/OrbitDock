import Foundation

struct DirectSessionComposerPreparedSteerRequest: Equatable {
  let content: String
  let mentions: [ServerMentionInput]
  let localImages: [AttachedImage]

  static func == (
    lhs: DirectSessionComposerPreparedSteerRequest,
    rhs: DirectSessionComposerPreparedSteerRequest
  ) -> Bool {
    lhs.content == rhs.content
      && mentionsEqual(lhs.mentions, rhs.mentions)
      && lhs.localImages.map(\.id) == rhs.localImages.map(\.id)
  }
}

struct DirectSessionComposerPreparedSendRequest: Equatable {
  let content: String
  let model: String?
  let effort: String
  let skills: [ServerSkillInput]
  let mentions: [ServerMentionInput]
  let localImages: [AttachedImage]

  static func == (
    lhs: DirectSessionComposerPreparedSendRequest,
    rhs: DirectSessionComposerPreparedSendRequest
  ) -> Bool {
    lhs.content == rhs.content
      && lhs.model == rhs.model
      && lhs.effort == rhs.effort
      && skillsEqual(lhs.skills, rhs.skills)
      && mentionsEqual(lhs.mentions, rhs.mentions)
      && lhs.localImages.map(\.id) == rhs.localImages.map(\.id)
  }
}

enum DirectSessionComposerPreparedAction: Equatable {
  case blocked
  case executeShell(command: String, exitsShellMode: Bool)
  case steer(DirectSessionComposerPreparedSteerRequest)
  case send(DirectSessionComposerPreparedSendRequest)
}

enum DirectSessionComposerExecutionPlanner {
  static func prepare(
    sendPlan: DirectSessionComposerSendPlan,
    message: String,
    attachments: DirectSessionComposerAttachmentState,
    shellContext: String?,
    selectedSkillPaths: Set<String>,
    availableSkills: [ServerSkillMetadata]
  ) -> DirectSessionComposerPreparedAction {
    switch sendPlan {
      case .blocked, .offlineShell, .missingModel:
        return .blocked

      case let .executeShell(command, exitsShellMode):
        return .executeShell(command: command, exitsShellMode: exitsShellMode)

      case .steer:
        let resolvedAttachments = DirectSessionComposerAttachmentPlanner.resolveForSend(
          message: message,
          attachments: attachments
        )
        return .steer(
          DirectSessionComposerPreparedSteerRequest(
            content: resolvedAttachments.expandedContent,
            mentions: resolvedAttachments.mentionInputs,
            localImages: resolvedAttachments.images
          )
        )

      case let .send(_, model, effort):
        let resolvedAttachments = DirectSessionComposerAttachmentPlanner.resolveForSend(
          message: message,
          attachments: attachments
        )
        let content = applyShellContext(
          shellContext,
          to: resolvedAttachments.expandedContent
        )
        let skills = DirectSessionComposerSkillPlanner.resolveSkillInputs(
          content: content,
          selectedSkillPaths: selectedSkillPaths,
          availableSkills: availableSkills
        )
        return .send(
          DirectSessionComposerPreparedSendRequest(
            content: content,
            model: model,
            effort: effort,
            skills: skills,
            mentions: resolvedAttachments.mentionInputs,
            localImages: resolvedAttachments.images
          )
        )
    }
  }

  static func applyShellContext(_ shellContext: String?, to content: String) -> String {
    guard let shellContext, !shellContext.isEmpty else { return content }
    guard !content.isEmpty else { return shellContext }
    return "\(shellContext)\n\n\(content)"
  }
}

private func skillsEqual(_ lhs: [ServerSkillInput], _ rhs: [ServerSkillInput]) -> Bool {
  lhs.count == rhs.count
    && zip(lhs, rhs).allSatisfy { left, right in
      left.name == right.name && left.path == right.path
    }
}

private func mentionsEqual(_ lhs: [ServerMentionInput], _ rhs: [ServerMentionInput]) -> Bool {
  lhs.count == rhs.count
    && zip(lhs, rhs).allSatisfy { left, right in
      left.name == right.name && left.path == right.path
    }
}
