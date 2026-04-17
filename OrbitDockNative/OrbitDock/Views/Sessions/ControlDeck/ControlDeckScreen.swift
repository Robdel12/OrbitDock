import SwiftUI
import UniformTypeIdentifiers

struct ControlDeckScreen: View {
  @Environment(\.horizontalSizeClass) var horizontalSizeClass

  let sessionId: String
  let session: ServerSessionContext
  var chromeStyle: ControlDeckChromeStyle = .standalone
  var detailPayload: ServerSessionDetailSnapshotPayload?
  var terminalTitle: String?
  var sessionDisplayStatus: SessionDisplayStatus = .ended
  var currentTool: String?
  var onDetailPayloadChange: ((ServerSessionDetailSnapshotPayload) -> Void)?
  var onFocusStateChange: ((Bool) -> Void)?
  var onToggleTerminal: (() -> Void)?

  @State var sessionModel = ControlDeckSessionModel()
  @State var composer = ControlDeckComposerModel()
  @AppStorage("localDictationEnabled") var localDictationEnabled = true

  var bindingIdentity: String {
    "\(session.endpointId.uuidString):\(sessionId):\(ObjectIdentifier(session))"
  }

  var isWaitingForParentDetailPayload: Bool {
    detailPayload == nil && sessionModel.snapshot == nil
  }

  var body: some View {
    Group {
      if (sessionModel.isLoading || isWaitingForParentDetailPayload), sessionModel.snapshot == nil {
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
      sessionModel.bind(
        sessionId: sessionId,
        session: session,
        detailSnapshotSink: onDetailPayloadChange
      )
      await sessionModel.bootstrap(detailPayload: detailPayload)
    }
    .onChange(of: detailPayload?.revision) { _, _ in
      guard let detailPayload else { return }
      Task {
        await sessionModel.applyExternalDetailSnapshot(detailPayload)
      }
    }
    .onChange(of: composer.draft) { _, _ in
      composer.persistDraft(for: sessionId)
    }
    .onChange(of: sessionModel.skills) { _, _ in
      composer.syncSelectedSkillsFromText(composer.draft.text, availableSkills: sessionModel.skills)
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
