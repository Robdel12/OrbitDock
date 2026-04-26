import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ControlDeckKeyCommandResult {
  case ignored
  case handled
  case submit
  case accept(ControlDeckCompletionSuggestion)
}

@MainActor
@Observable
final class ControlDeckComposerModel {
  var draft = ControlDeckDraft()
  var completionState = ControlDeckCompletionState()
  var focusState = ControlDeckFocusState()
  var isSubmitting = false
  var uploadedImageIds: [String: String] = [:]
  var isImportingAttachments = false
  var dictationController = LocalDictationController()
  var dictationDraftBase: String?
  var controlDeckWidth: CGFloat = 0
  var completionPanelHeight: CGFloat = 0

  func restoreDraft(for sessionId: String) {
    draft = ControlDeckDraft.restore(for: sessionId)
  }

  func persistDraft(for sessionId: String) {
    ControlDeckDraft.save(draft, for: sessionId)
  }

  func clearDraft(for sessionId: String) {
    draft.clearAfterSubmit()
    uploadedImageIds = [:]
    completionState.dismiss()
    ControlDeckDraft.clear(for: sessionId)
    focusState.requestFocus()
  }

  @discardableResult
  func handleTextChange(
    _ text: String,
    availableSkills: [ControlDeckSkill],
    allowsAutocomplete: Bool
  ) -> Bool {
    if allowsAutocomplete {
      syncSelectedSkillsFromText(text, availableSkills: availableSkills)
    } else {
      completionState.dismiss()
    }

    guard allowsAutocomplete else {
      return false
    }

    let nextMode = ControlDeckAutocompletePlanner.completionMode(for: text)
    switch nextMode {
    case .skill:
      completionState.activate(nextMode)
      return availableSkills.isEmpty
    case .mention:
      completionState.activate(nextMode)
      return false
    case .inactive, .command:
      completionState.dismiss()
      return false
    }
  }

  func currentSuggestions(
    availableSkills: [ControlDeckSkill],
    projectPath: String?,
    projectFileIndex: ProjectFileIndex?
  ) -> [ControlDeckCompletionSuggestion] {
    switch completionState.mode {
    case .inactive:
      return []
    case let .mention(query):
      guard let projectPath else { return [] }
      let files = projectFileIndex?.search(query, in: projectPath) ?? []
      return files.prefix(ControlDeckAutocompletePlanner.maxSuggestionCount).map { file in
        ControlDeckCompletionSuggestion(
          id: file.id,
          kind: .file,
          title: file.name,
          subtitle: file.relativePath
        )
      }
    case let .skill(query):
      return ControlDeckAutocompletePlanner.skillSuggestions(for: query, skills: availableSkills)
    case .command:
      return []
    }
  }

  func handleKeyCommand(
    _ command: ControlDeckTextAreaKeyCommand,
    suggestions: [ControlDeckCompletionSuggestion],
    canSubmit: Bool
  ) -> ControlDeckKeyCommandResult {
    if completionState.isActive {
      switch command {
      case .escape:
        completionState.dismiss()
        return .handled
      case .upArrow, .controlP:
        completionState.moveUp()
        return .handled
      case .downArrow, .controlN:
        completionState.moveDown(itemCount: suggestions.count)
        return .handled
      case .tab, .returnKey:
        guard suggestions.indices.contains(completionState.selectedIndex) else {
          return .ignored
        }
        return .accept(suggestions[completionState.selectedIndex])
      default:
        return .ignored
      }
    }

    if command == .returnKey, canSubmit {
      return .submit
    }

    return .ignored
  }

  func handleFocusEvent(_ event: ControlDeckTextAreaFocusEvent) -> Bool {
    switch event {
    case .began:
      focusState.isFocused = true
      return true
    case .ended(userInitiated: _):
      focusState.isFocused = false
      return false
    }
  }

  func acceptSuggestion(
    _ suggestion: ControlDeckCompletionSuggestion,
    availableSkills: [ControlDeckSkill],
    projectPath: String?,
    projectFileIndex: ProjectFileIndex?
  ) {
    switch suggestion.kind {
    case .file:
      acceptFileSuggestion(
        suggestion,
        projectPath: projectPath,
        projectFileIndex: projectFileIndex
      )
    case .skill:
      acceptSkillSuggestion(suggestion, availableSkills: availableSkills)
    case .command:
      break
    }
  }

  func handleAttachmentImport(
    _ result: Result<[URL], Error>,
    projectPath: String?
  ) -> String? {
    guard case let .success(urls) = result, !urls.isEmpty else {
      if case let .failure(error) = result {
        return String(describing: error)
      }
      return nil
    }

    for url in urls {
      do {
        if let imagePayload = try Self.makeImagePayloadIfNeeded(from: url) {
          draft.attachments.appendImage(imagePayload)
        } else {
          try appendFileMention(from: url, projectPath: projectPath)
        }
      } catch {
        return String(describing: error)
      }
    }

    return nil
  }

  func appendDroppedImage(_ payload: ControlDeckImageDraft) {
    draft.attachments.appendImage(payload)
  }

  func updateDictationLivePreview(_ transcript: String) {
    guard let base = dictationDraftBase else { return }
    let normalized = DictationTextFormatter.normalizeTranscription(transcript)
    let merged = DictationTextFormatter.merge(existing: base, dictated: normalized)
    guard merged != draft.text else { return }
    draft.text = merged
    focusState.moveCursorToEnd()
  }

  func toggleDictation(localDictationEnabled: Bool) async -> String? {
    guard localDictationEnabled else { return nil }

    if dictationController.isRecording {
      if let dictated = await dictationController.stop() {
        let normalized = DictationTextFormatter.normalizeTranscription(dictated)
        if let base = dictationDraftBase {
          let currentWithoutPreview = removeLivePreviewSuffix(from: draft.text, base: base)
          draft.text = DictationTextFormatter.merge(existing: currentWithoutPreview, dictated: normalized)
        } else {
          draft.text = DictationTextFormatter.merge(existing: draft.text, dictated: normalized)
        }
      }
      dictationDraftBase = nil
      focusState.moveCursorToEnd()
      Platform.services.playHaptic(.action)
      return nil
    }

    dictationDraftBase = draft.text
    await dictationController.start()
    if dictationController.isRecording {
      Platform.services.playHaptic(.action)
      return nil
    }

    dictationDraftBase = nil
    if let message = dictationController.errorMessage {
      Platform.services.playHaptic(.error)
      return message
    }

    return nil
  }

  func cancelDictation() async {
    await dictationController.cancel()
    dictationDraftBase = nil
  }

  func syncSelectedSkillsFromText(_ text: String, availableSkills: [ControlDeckSkill]) {
    guard !availableSkills.isEmpty else { return }
    let matched = ControlDeckSkillResolver.matchedSkillPaths(
      in: text,
      availableSkills: availableSkills
    )
    guard matched != draft.selectedSkillPaths else { return }
    draft.selectedSkillPaths = matched
  }

  private func acceptFileSuggestion(
    _ suggestion: ControlDeckCompletionSuggestion,
    projectPath: String?,
    projectFileIndex: ProjectFileIndex?
  ) {
    guard let projectPath,
      let file = projectFileIndex?.files(for: projectPath).first(where: { $0.id == suggestion.id })
    else { return }

    draft.text = ControlDeckTextEditing.replacingTrailingToken(
      in: draft.text,
      prefix: "@",
      with: "@\(file.name) "
    )
    let absolutePath = (projectPath as NSString).appendingPathComponent(file.relativePath)
    draft.attachments.appendMention(
      ControlDeckMentionDraft(
        fileId: file.id,
        name: file.name,
        absolutePath: absolutePath,
        relativePath: file.relativePath,
        kind: .file
      )
    )
    completionState.dismiss()
    focusState.requestFocus()
    focusState.moveCursorToEnd()
  }

  private func acceptSkillSuggestion(
    _ suggestion: ControlDeckCompletionSuggestion,
    availableSkills: [ControlDeckSkill]
  ) {
    guard let skill = availableSkills.first(where: { $0.id == suggestion.id }) else { return }

    draft.text = ControlDeckTextEditing.replacingTrailingToken(
      in: draft.text,
      prefix: "$",
      with: "$\(skill.name) "
    )
    draft.selectedSkillPaths.insert(skill.path)
    completionState.dismiss()
    focusState.requestFocus()
    focusState.moveCursorToEnd()
  }

  private func appendFileMention(from url: URL, projectPath: String?) throws {
    let requiresScope = url.startAccessingSecurityScopedResource()
    defer {
      if requiresScope {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let standardizedURL = url.standardizedFileURL
    let absolutePath = standardizedURL.path
    guard !absolutePath.isEmpty else { return }

    let trimmedProjectPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    let relativePath: String?
    if let trimmedProjectPath, !trimmedProjectPath.isEmpty, absolutePath.hasPrefix(trimmedProjectPath + "/") {
      relativePath = String(absolutePath.dropFirst(trimmedProjectPath.count + 1))
    } else {
      relativePath = nil
    }

    _ = draft.attachments.appendMention(
      ControlDeckMentionDraft(
        fileId: absolutePath,
        name: standardizedURL.lastPathComponent,
        absolutePath: absolutePath,
        relativePath: relativePath,
        kind: .file
      )
    )
  }

  private func removeLivePreviewSuffix(from current: String, base: String) -> String {
    current.hasPrefix(base) ? base : current
  }

  nonisolated static func makeImagePayloadIfNeeded(from url: URL) throws -> ControlDeckImageDraft? {
    let utType = UTType(filenameExtension: url.pathExtension.lowercased())
    guard utType?.conforms(to: .image) == true else { return nil }

    let requiresScope = url.startAccessingSecurityScopedResource()
    defer {
      if requiresScope {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let data = try Data(contentsOf: url)
    let dims = imageDimensions(from: data)
    return ControlDeckImageDraft(
      localId: UUID().uuidString,
      thumbnailData: data.count < 500_000 ? data : nil,
      uploadData: data,
      uploadMimeType: utType?.preferredMIMEType ?? "image/png",
      displayName: url.lastPathComponent,
      pixelWidth: dims.width,
      pixelHeight: dims.height
    )
  }

  nonisolated static func imageDimensions(from data: Data) -> (width: Int?, height: Int?) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return (nil, nil)
    }

    return (
      props[kCGImagePropertyPixelWidth] as? Int,
      props[kCGImagePropertyPixelHeight] as? Int
    )
  }
}
