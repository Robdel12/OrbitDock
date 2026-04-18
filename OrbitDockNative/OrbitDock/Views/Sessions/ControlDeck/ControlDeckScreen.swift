import SwiftUI
import UniformTypeIdentifiers

struct ControlDeckScreen: View {
  @Environment(\.horizontalSizeClass) var horizontalSizeClass

  let sessionId: String
  let interaction: SessionInteractionModel
  var chromeStyle: ControlDeckChromeStyle = .standalone
  var terminalTitle: String?
  var sessionDisplayStatus: SessionDisplayStatus = .ended
  var currentTool: String?
  var onFocusStateChange: ((Bool) -> Void)?
  var onToggleTerminal: (() -> Void)?

  @State var composer = ControlDeckComposerModel()
  @AppStorage("localDictationEnabled") var localDictationEnabled = true

  var bindingIdentity: String {
    "\(sessionId):\(ObjectIdentifier(interaction))"
  }

  var isWaitingForParentDetailPayload: Bool {
    interaction.snapshot == nil
  }

  var body: some View {
    Group {
      if (interaction.isLoading || isWaitingForParentDetailPayload), interaction.snapshot == nil {
        loadingView
      } else if let error = interaction.lastError, interaction.snapshot == nil {
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
    }
    .onChange(of: composer.draft) { _, _ in
      composer.persistDraft(for: sessionId)
    }
    .onChange(of: interaction.skills) { _, _ in
      composer.syncSelectedSkillsFromText(composer.draft.text, availableSkills: interaction.skills)
    }
    .onChange(of: interaction.pendingApproval) { old, new in
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
