import Foundation

struct DirectSessionComposerResolvedAttachments: Equatable {
  let expandedContent: String
  let mentionInputs: [ServerMentionInput]
  let images: [AttachedImage]

  var hasImages: Bool {
    !images.isEmpty
  }

  var hasMentions: Bool {
    !mentionInputs.isEmpty
  }

  static func == (
    lhs: DirectSessionComposerResolvedAttachments,
    rhs: DirectSessionComposerResolvedAttachments
  ) -> Bool {
    let mentionsMatch = lhs.mentionInputs.elementsEqual(rhs.mentionInputs, by: { left, right in
      left.name == right.name && left.path == right.path
    })
    return lhs.expandedContent == rhs.expandedContent
      && mentionsMatch
      && lhs.images.map(\.id) == rhs.images.map(\.id)
  }
}

enum DirectSessionComposerAttachmentPlanner {
  static func buildMention(
    file: ProjectFileIndex.ProjectFile,
    projectPath: String?
  ) -> AttachedMention {
    let absolutePath = if let projectPath {
      (projectPath as NSString).appendingPathComponent(file.relativePath)
    } else {
      file.relativePath
    }

    return AttachedMention(id: file.id, name: file.name, path: absolutePath)
  }

  static func resolveForSend(
    message: String,
    attachments: DirectSessionComposerAttachmentState
  ) -> DirectSessionComposerResolvedAttachments {
    let expandedContent = attachments.mentions.reduce(into: message) { result, mention in
      result = result.replacingOccurrences(of: "@\(mention.name)", with: mention.path)
    }

    let mentionInputs = attachments.mentions.map {
      ServerMentionInput(name: $0.name, path: $0.path)
    }

    return DirectSessionComposerResolvedAttachments(
      expandedContent: expandedContent,
      mentionInputs: mentionInputs,
      images: attachments.images
    )
  }

  static func imageAppendResult(
    existingImages: [AttachedImage],
    candidate: AttachedImage
  ) -> ComposerImageAttachmentPolicy.Validation {
    let isDuplicate = existingImages.contains {
      $0.uploadMimeType == candidate.uploadMimeType
        && $0.uploadData == candidate.uploadData
    }
    guard !isDuplicate else { return .allowed }

    let usedRawBytes = ComposerImageAttachmentPolicy.usedRawBytes(
      existingImages.map(\.uploadData.count)
    )
    return ComposerImageAttachmentPolicy.validateAddition(
      existingCount: existingImages.count,
      usedRawBytes: usedRawBytes,
      candidateRawBytes: candidate.uploadData.count
    )
  }
}
