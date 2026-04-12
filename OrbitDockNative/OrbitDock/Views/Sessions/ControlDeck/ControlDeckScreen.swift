import SwiftUI
import UniformTypeIdentifiers

struct ControlDeckScreen: View {
  @Environment(\.horizontalSizeClass) var horizontalSizeClass

  let sessionId: String
  let sessionStore: SessionStore
  var chromeStyle: ControlDeckChromeStyle = .standalone
  var terminalTitle: String?
  var sessionDisplayStatus: SessionDisplayStatus = .ended
  var currentTool: String?
  var onFocusStateChange: ((Bool) -> Void)?
  var onToggleTerminal: (() -> Void)?

  @State var sessionModel = ControlDeckSessionModel()
  @State var composer = ControlDeckComposerModel()
  @AppStorage("localDictationEnabled") var localDictationEnabled = true

  var bindingIdentity: String {
    "\(sessionStore.endpointId.uuidString):\(sessionId):\(ObjectIdentifier(sessionStore))"
  }

  var body: some View {
    Group {
      if sessionModel.isLoading, sessionModel.snapshot == nil {
        loadingView
      } else if let error = sessionModel.lastError, sessionModel.snapshot == nil {
        errorView(error)
      } else {
        controlDeckBody
      }
    }
    .padding(.horizontal, chromeStyle == .embedded ? Spacing.xs : Spacing.sm)
    .padding(.top, chromeStyle == .embedded ? Spacing.xxs : 0)
    .padding(.bottom, Spacing.xs)
    .task(id: bindingIdentity) {
      composer.restoreDraft(for: sessionId)
      sessionModel.bind(sessionId: sessionId, sessionStore: sessionStore)
      await sessionModel.refresh()
    }
    .onChange(of: composer.draft) { _, _ in
      composer.persistDraft(for: sessionId)
    }
    .onChange(of: sessionModel.skills) { _, _ in
      composer.syncSelectedSkillsFromText(composer.draft.text, availableSkills: sessionModel.skills)
    }
    .task(id: bindingIdentity + ":ws") {
      let (stream, _) = sessionStore.controlDeckRefreshRequests(for: sessionId)
      for await _ in stream {
        guard !Task.isCancelled else { break }
        netLog(.debug, cat: .store, "ControlDeckScreen refresh signal", sid: sessionId)
        await sessionModel.refresh()
      }
    }
    .onChange(of: sessionModel.pendingApproval) { old, new in
      if old == nil, new != nil {
        Platform.services.playHaptic(.warning)
      }
    }
    .onChange(of: composer.dictationController.liveTranscript) { _, transcript in
      guard composer.dictationController.isRecording else { return }
      composer.updateDictationLivePreview(transcript)
    }
    .onChange(of: localDictationEnabled) { _, enabled in
      if !enabled {
        Task { await composer.cancelDictation() }
      }
    }
    .task(id: sessionModel.snapshot?.state.projectPath ?? "") {
      guard let path = sessionModel.snapshot?.state.projectPath, !path.isEmpty else { return }
      await sessionModel.projectFileIndex?.loadIfNeeded(path)
    }
    .fileImporter(
      isPresented: Binding(
        get: { composer.isImportingAttachments },
        set: { composer.isImportingAttachments = $0 }
      ),
      allowedContentTypes: [.item],
      allowsMultipleSelection: true,
      onCompletion: handleAttachmentImport
    )
  }
}
