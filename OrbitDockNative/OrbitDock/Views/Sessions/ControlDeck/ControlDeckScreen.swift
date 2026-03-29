import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
  import AppKit
#endif
#if os(iOS)
  import UIKit
#endif

struct ControlDeckScreen: View {
  let sessionId: String
  let sessionStore: SessionStore
  var chromeStyle: ControlDeckChromeStyle = .standalone

  // Terminal integration — passed from SessionDetailView
  var terminalTitle: String?
  var sessionDisplayStatus: SessionDisplayStatus = .ended
  var currentTool: String?
  var onToggleTerminal: (() -> Void)?

  @State private var viewModel = ControlDeckViewModel()
  @State private var draft = ControlDeckDraft()
  @State private var completionState = ControlDeckCompletionState()
  @State private var focusState = ComposerFocusState()
  @State private var isSubmitting = false
  @State private var uploadedImageIds: [String: String] = [:]
  @State private var isImportingAttachments = false
  @State private var dictationController = LocalDictationController()
  @State private var dictationDraftBase: String?
  @AppStorage("localDictationEnabled") private var localDictationEnabled = true

  private var canSubmit: Bool {
    let mode = viewModel.presentation?.mode ?? .disabled
    let modeAllowsInput = mode == .compose || mode == .steer
    return modeAllowsInput && draft.hasContent && !isSubmitting
  }

  private var shouldShowDictation: Bool {
    localDictationEnabled && LocalDictationAvailabilityResolver.current == .available
  }

  private var isDictationActive: Bool {
    dictationController.state == .recording ||
      dictationController.state == .requestingPermission ||
      dictationController.state == .transcribing
  }

  private var dictationAction: (() -> Void)? {
    shouldShowDictation ? { toggleDictation() } : nil
  }

  private var isSessionWorking: Bool {
    sessionStore.session(sessionId).workStatus == .working
  }

  var body: some View {
    Group {
      if viewModel.isLoading, viewModel.snapshot == nil {
        loadingView
      } else if let error = viewModel.lastError, viewModel.snapshot == nil {
        errorView(error)
      } else {
        ControlDeckView(
          draft: $draft,
          focusState: $focusState,
          completionState: $completionState,
          isSubmitting: isSubmitting,
          canSubmit: canSubmit,
          presentation: viewModel.presentation,
          pendingApproval: viewModel.pendingApproval,
          completionSuggestions: currentSuggestions,
          errorMessage: viewModel.lastError,
          chromeStyle: chromeStyle,
          onTextChange: handleTextChange,
          onKeyCommand: handleKeyCommand,
          onFocusEvent: handleFocusEvent,
          onPasteImage: pasteImageFromClipboard,
          canPasteImage: { supportsImageClipboardPaste },
          onAddImage: { isImportingAttachments = true },
          onRemoveAttachment: { draft.attachments.remove(id: $0) },
          onDropImages: handleDrop,
          onSelectSuggestion: acceptSuggestion,
          onSubmit: submitDraft,
          onApprove: { Task { await viewModel.approveTool(decision: .approved) } },
          onApproveForSession: { Task { await viewModel.approveTool(decision: .approvedForSession) } },
          onDeny: { Task { await viewModel.approveTool(decision: .denied) } },
          onAnswer: { answer, promptId in
            Task { await viewModel.answerQuestion(answer: answer, questionId: promptId) }
          },
          onGrantPermission: { Task { await viewModel.respondToPermission(grant: true, scope: .turn) } },
          onGrantPermissionForSession: { Task { await viewModel.respondToPermission(grant: true, scope: .session) } },
          onDenyPermission: { Task { await viewModel.respondToPermission(grant: false) } },
          terminalTitle: terminalTitle,
          sessionDisplayStatus: sessionDisplayStatus,
          currentTool: currentTool,
          onToggleTerminal: onToggleTerminal,
          onModuleAction: handleModuleAction,
          isDictating: isDictationActive,
          isSessionWorking: isSessionWorking,
          onDictation: dictationAction,
          onInterrupt: { Task { await viewModel.interruptSession() } }
        )
      }
    }
    .padding(.horizontal, chromeStyle == .embedded ? 0 : Spacing.sm)
    .padding(.bottom, chromeStyle == .embedded ? 0 : Spacing.xs)
    .task(id: sessionId) {
      draft = ControlDeckDraft.restore(for: sessionId)
      viewModel.bind(sessionId: sessionId, sessionStore: sessionStore)
      await viewModel.refresh()
    }
    .onChange(of: draft) { _, newDraft in
      ControlDeckDraft.save(newDraft, for: sessionId)
    }
    .onChange(of: sessionStore.session(sessionId).pendingApproval?.id) { _, _ in
      viewModel.syncApproval()
    }
    .onChange(of: sessionStore.session(sessionId).approvalVersion) { _, _ in
      viewModel.syncApproval()
    }
    .onChange(of: sessionStore.session(sessionId).workStatus) { _, _ in
      viewModel.syncApproval()
    }
    .onChange(of: sessionStore.session(sessionId).acceptsUserInput) { _, _ in
      viewModel.syncApproval()
    }
    .onChange(of: sessionStore.session(sessionId).steerable) { _, _ in
      viewModel.syncApproval()
    }
    .onChange(of: sessionStore.session(sessionId).projectPath) { _, _ in
      viewModel.syncApproval()
    }
    .onChange(of: sessionStore.session(sessionId).currentCwd) { _, _ in
      viewModel.syncApproval()
    }
    .onChange(of: sessionStore.session(sessionId).branch) { _, _ in
      viewModel.syncApproval()
    }
    .onChange(of: dictationController.liveTranscript) { _, transcript in
      guard dictationController.isRecording else { return }
      updateDictationLivePreview(transcript)
    }
    .onChange(of: localDictationEnabled) { _, enabled in
      if !enabled {
        Task { await dictationController.cancel(); dictationDraftBase = nil }
      }
    }
    .task(id: viewModel.snapshot?.state.projectPath ?? "") {
      guard let path = viewModel.snapshot?.state.projectPath, !path.isEmpty else { return }
      await viewModel.projectFileIndex?.loadIfNeeded(path)
    }
    .fileImporter(
      isPresented: $isImportingAttachments,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true,
      onCompletion: handleAttachmentImport
    )
  }

  // MARK: - Loading / Error

  private var loadingView: some View {
    ProgressView()
      .controlSize(.small)
      .frame(maxWidth: .infinity, minHeight: 60)
      .background(Color.backgroundSecondary)
      .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      )
  }

  private func errorView(_ error: String) -> some View {
    VStack(spacing: Spacing.sm) {
      Text(error)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.statusPermission)
        .lineLimit(3)
      Button("Retry") { Task { await viewModel.refresh() } }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity)
    .background(Color.backgroundSecondary)
    .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .strokeBorder(Color.panelBorder, lineWidth: 1)
    )
  }

  // MARK: - Text Change → Completions

  private func handleTextChange(_ text: String) {
    if let query = mentionQuery(in: text) {
      completionState.activate(.mention(query: query))
      return
    }

    if let query = skillQuery(in: text) {
      if viewModel.skills.isEmpty {
        Task { await viewModel.loadSkills() }
      }
      completionState.activate(.skill(query: query))
      return
    }

    completionState.dismiss()
  }

  private var currentSuggestions: [ControlDeckCompletionSuggestion] {
    switch completionState.mode {
      case .inactive:
        return []
      case let .mention(query):
        let files = viewModel.projectFileIndex?.search(query, in: viewModel.projectPath ?? "") ?? []
        return files.prefix(8).map { file in
          ControlDeckCompletionSuggestion(id: file.id, kind: .file, title: file.name, subtitle: file.relativePath)
        }
      case let .skill(query):
        let normalizedQuery = query.lowercased()
        let matching = viewModel.skills.filter { skill in
          normalizedQuery.isEmpty || skill.name.lowercased().contains(normalizedQuery)
        }
        return matching.prefix(8).map { skill in
          ControlDeckCompletionSuggestion(
            id: skill.id,
            kind: .skill,
            title: skill.name,
            subtitle: skill.shortDescription ?? skill.description
          )
        }
      case .command:
        return []
    }
  }

  // MARK: - Keyboard Commands

  private func handleKeyCommand(_ command: ComposerTextAreaKeyCommand) -> Bool {
    if completionState.isActive {
      let suggestions = currentSuggestions
      switch command {
        case .escape:
          completionState.dismiss()
          return true
        case .upArrow, .controlP:
          completionState.moveUp()
          return true
        case .downArrow, .controlN:
          completionState.moveDown(itemCount: suggestions.count)
          return true
        case .tab, .returnKey:
          guard suggestions.indices.contains(completionState.selectedIndex) else { return false }
          acceptSuggestion(suggestions[completionState.selectedIndex])
          return true
        default:
          return false
      }
    }

    if command == .returnKey, canSubmit {
      submitDraft()
      return true
    }

    return false
  }

  // MARK: - Focus

  private func handleFocusEvent(_ event: ComposerTextAreaFocusEvent) {
    switch event {
      case .began:
        focusState.isFocused = true
      case .ended:
        focusState.isFocused = false
    }
  }

  // MARK: - Module Actions

  private func handleModuleAction(_ module: ControlDeckStatusModule, _ value: String) {
    Task {
      switch module {
        case .model:
          await viewModel.updateModel(value)
        case .effort:
          await viewModel.updateEffort(value)
        case .autonomy:
          await viewModel.updatePermissionMode(value)
        case .approvalMode:
          await viewModel.updateApprovalPolicy(value)
        case .collaborationMode:
          await viewModel.updateCollaborationMode(value)
        case .autoReview:
          await viewModel.updateAutoReview(value)
        default:
          break
      }
    }
  }

  // MARK: - Suggestion Acceptance

  private func acceptSuggestion(_ suggestion: ControlDeckCompletionSuggestion) {
    switch suggestion.kind {
      case .file:
        acceptFileSuggestion(suggestion)
      case .skill:
        acceptSkillSuggestion(suggestion)
      case .command:
        break
    }
  }

  private func acceptFileSuggestion(_ suggestion: ControlDeckCompletionSuggestion) {
    guard let projectPath = viewModel.projectPath,
          let file = viewModel.projectFileIndex?.files(for: projectPath).first(where: { $0.id == suggestion.id })
    else { return }

    draft.text = replaceTrailingToken(in: draft.text, prefix: "@", with: "@\(file.name) ")
    let absolutePath = (projectPath as NSString).appendingPathComponent(file.relativePath)
    draft.attachments.appendMention(ControlDeckMentionDraft(
      fileId: file.id,
      name: file.name,
      absolutePath: absolutePath,
      relativePath: file.relativePath,
      kind: .file
    ))
    completionState.dismiss()
    focusState.requestFocus()
    focusState.moveCursorToEnd()
  }

  private func acceptSkillSuggestion(_ suggestion: ControlDeckCompletionSuggestion) {
    guard let skill = viewModel.skills.first(where: { $0.id == suggestion.id }) else { return }

    draft.text = replaceTrailingToken(in: draft.text, prefix: "$", with: "$\(skill.name) ")
    draft.selectedSkillPaths.insert(skill.path)
    completionState.dismiss()
    focusState.requestFocus()
    focusState.moveCursorToEnd()
  }

  // MARK: - Submit

  private func submitDraft() {
    guard draft.hasContent, !isSubmitting else { return }

    let shouldSteer = viewModel.presentation?.mode == .steer || isSessionWorking
    isSubmitting = true
    let currentDraft = draft

    Task {
      defer { isSubmitting = false }
      do {
        // Upload images first so both compose and steer can reference the same server attachment IDs.
        var imageIds = uploadedImageIds
        for image in currentDraft.attachments.images {
          if imageIds[image.localId] == nil {
            let attachmentId = try await viewModel.uploadImage(
              data: image.uploadData,
              mimeType: image.uploadMimeType,
              displayName: image.displayName,
              pixelWidth: image.pixelWidth,
              pixelHeight: image.pixelHeight
            )
            imageIds[image.localId] = attachmentId
          }
        }

        if shouldSteer {
          try await viewModel.steerTurn(draft: currentDraft, uploadedImageIds: imageIds)
          uploadedImageIds = [:]
        } else {
          try await viewModel.submitTurn(draft: currentDraft, uploadedImageIds: imageIds)
          uploadedImageIds = [:]
        }

        draft.clearAfterSubmit()
        ControlDeckDraft.clear(for: sessionId)
        completionState.dismiss()
        viewModel.lastError = nil
        focusState.requestFocus()
        await viewModel.refresh()
      } catch {
        viewModel.lastError = String(describing: error)
      }
    }
  }

  // MARK: - Token Parsing

  private func mentionQuery(in text: String) -> String? {
    guard let range = trailingTokenRange(in: text, prefix: "@") else { return nil }
    let idx = text.index(after: range.lowerBound)
    guard idx < range.upperBound || idx == text.endIndex else { return nil }
    return String(text[idx ..< range.upperBound])
  }

  private func skillQuery(in text: String) -> String? {
    guard let range = trailingTokenRange(in: text, prefix: "$") else { return nil }
    return String(text[text.index(after: range.lowerBound) ..< range.upperBound])
  }

  private func trailingTokenRange(in text: String, prefix: Character) -> Range<String.Index>? {
    guard let idx = text.lastIndex(of: prefix) else { return nil }
    if prefix == "@", idx != text.startIndex {
      let before = text[text.index(before: idx)]
      guard before.isWhitespace else { return nil }
    }
    let after = text[text.index(after: idx)...]
    guard !after.contains(where: \.isWhitespace) else { return nil }
    return idx ..< text.endIndex
  }

  private func replaceTrailingToken(in text: String, prefix: Character, with replacement: String) -> String {
    guard let range = trailingTokenRange(in: text, prefix: prefix) else {
      return text + replacement
    }
    var updated = text
    updated.replaceSubrange(range, with: replacement)
    return updated
  }

  // MARK: - Image Handling

  private func handleAttachmentImport(_ result: Result<[URL], Error>) {
    guard case let .success(urls) = result, !urls.isEmpty else {
      if case let .failure(error) = result {
        viewModel.lastError = String(describing: error)
      }
      return
    }

    for url in urls {
      do {
        if let imagePayload = try Self.makeImagePayloadIfNeeded(from: url) {
          draft.attachments.appendImage(imagePayload)
        } else {
          try appendFileMention(from: url)
        }
      } catch {
        viewModel.lastError = String(describing: error)
      }
    }
  }

  private func appendFileMention(from url: URL) throws {
    let requiresScope = url.startAccessingSecurityScopedResource()
    defer { if requiresScope { url.stopAccessingSecurityScopedResource() } }

    let standardizedURL = url.standardizedFileURL
    let absolutePath = standardizedURL.path
    guard !absolutePath.isEmpty else { return }

    let projectPath = viewModel.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    let relativePath: String?
    if let projectPath, !projectPath.isEmpty, absolutePath.hasPrefix(projectPath + "/") {
      relativePath = String(absolutePath.dropFirst(projectPath.count + 1))
    } else {
      relativePath = nil
    }

    _ = draft.attachments.appendMention(ControlDeckMentionDraft(
      fileId: absolutePath,
      name: standardizedURL.lastPathComponent,
      absolutePath: absolutePath,
      relativePath: relativePath,
      kind: .file
    ))
  }

  private static func makeImagePayloadIfNeeded(from url: URL) throws -> ControlDeckImageDraft? {
    let utType = UTType(filenameExtension: url.pathExtension.lowercased())
    guard utType?.conforms(to: .image) == true else { return nil }

    let requiresScope = url.startAccessingSecurityScopedResource()
    defer { if requiresScope { url.stopAccessingSecurityScopedResource() } }

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

  private static func imageDimensions(from data: Data) -> (width: Int?, height: Int?) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return (nil, nil) }
    return (props[kCGImagePropertyPixelWidth] as? Int, props[kCGImagePropertyPixelHeight] as? Int)
  }

  // MARK: - Dictation

  private func toggleDictation() {
    guard shouldShowDictation else { return }
    Task { @MainActor in
      if dictationController.isRecording {
        if let dictated = await dictationController.stop() {
          let normalized = DictationTextFormatter.normalizeTranscription(dictated)
          // Replace only the live preview portion, keeping user edits intact
          if let base = dictationDraftBase {
            // Remove the live preview suffix and apply final transcript
            let currentWithoutPreview = removeLivePreviewSuffix(from: draft.text, base: base)
            draft.text = DictationTextFormatter.merge(existing: currentWithoutPreview, dictated: normalized)
          } else {
            draft.text = DictationTextFormatter.merge(existing: draft.text, dictated: normalized)
          }
        }
        dictationDraftBase = nil
        focusState.moveCursorToEnd()
        Platform.services.playHaptic(.action)
      } else {
        // Snapshot current text as the base — live preview appends after this
        dictationDraftBase = draft.text
        await dictationController.start()
        if dictationController.isRecording {
          Platform.services.playHaptic(.action)
        } else {
          dictationDraftBase = nil
          if dictationController.errorMessage != nil {
            viewModel.lastError = dictationController.errorMessage
            Platform.services.playHaptic(.error)
          }
        }
      }
    }
  }

  private func updateDictationLivePreview(_ transcript: String) {
    guard let base = dictationDraftBase else { return }
    let normalized = DictationTextFormatter.normalizeTranscription(transcript)
    // Always merge against the snapshot base so user edits before dictation are preserved
    let merged = DictationTextFormatter.merge(existing: base, dictated: normalized)
    guard merged != draft.text else { return }
    draft.text = merged
    focusState.moveCursorToEnd()
  }

  private func removeLivePreviewSuffix(from current: String, base: String) -> String {
    // If the current text starts with the base, return just the base
    // (user edits during dictation are in the base region)
    current.hasPrefix(base) ? base : current
  }
}

// MARK: - Platform Clipboard + Drop

#if os(macOS)
  extension ControlDeckScreen {
    var supportsImageClipboardPaste: Bool {
      NSPasteboard.general.availableType(from: [.tiff, .png]) != nil
    }

    @discardableResult
    func pasteImageFromClipboard() -> Bool {
      let pb = NSPasteboard.general
      guard let imageType = pb.availableType(from: [.tiff, .png]),
            let data = pb.data(forType: imageType),
            let normalized = Self.normalizedPNG(from: data)
      else { return false }

      let dims = Self.imageDimensions(from: normalized)
      draft.attachments.appendImage(ControlDeckImageDraft(
        localId: UUID().uuidString,
        thumbnailData: normalized.count < 500_000 ? normalized : nil,
        uploadData: normalized,
        uploadMimeType: "image/png",
        displayName: "Clipboard Image",
        pixelWidth: dims.width,
        pixelHeight: dims.height
      ))
      return true
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
      var handled = false
      for provider in providers {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
          provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = Self.droppedFileURL(from: item),
                  url.isFileURL,
                  UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                  let payload = try? Self.makeImagePayloadIfNeeded(from: url)
            else { return }
            Task { @MainActor in draft.attachments.appendImage(payload) }
          }
          handled = true
        }
      }
      return handled
    }

    private static func normalizedPNG(from data: Data) -> Data? {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }
      let out = NSMutableData()
      guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(dest, cgImage, nil)
      guard CGImageDestinationFinalize(dest) else { return nil }
      return out as Data
    }

    private static func droppedFileURL(from item: NSSecureCoding?) -> URL? {
      (item as? URL) ?? (item as? NSURL) as URL? ?? (item as? Data).flatMap { URL(
        dataRepresentation: $0,
        relativeTo: nil
      ) }
    }
  }
#endif

#if os(iOS)
  extension ControlDeckScreen {
    var supportsImageClipboardPaste: Bool {
      UIPasteboard.general.hasImages
    }

    @discardableResult
    func pasteImageFromClipboard() -> Bool {
      guard let image = UIPasteboard.general.image, let data = image.pngData() else { return false }
      let dims = Self.imageDimensions(from: data)
      draft.attachments.appendImage(ControlDeckImageDraft(
        localId: UUID().uuidString,
        thumbnailData: data.count < 500_000 ? data : nil,
        uploadData: data,
        uploadMimeType: "image/png",
        displayName: "Clipboard Image",
        pixelWidth: dims.width,
        pixelHeight: dims.height
      ))
      return true
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
      var handled = false
      for provider in providers {
        if provider.canLoadObject(ofClass: UIImage.self) {
          provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage, let data = image.pngData() else { return }
            let dims = Self.imageDimensions(from: data)
            let payload = ControlDeckImageDraft(
              localId: UUID().uuidString,
              thumbnailData: data.count < 500_000 ? data : nil,
              uploadData: data,
              uploadMimeType: "image/png",
              displayName: "Dropped Image",
              pixelWidth: dims.width,
              pixelHeight: dims.height
            )
            Task { @MainActor in draft.attachments.appendImage(payload) }
          }
          handled = true
        }
      }
      return handled
    }
  }
#endif
