import SwiftUI
import UniformTypeIdentifiers

enum ControlDeckChromeStyle {
  case standalone
  case embedded
}

struct ControlDeckView: View {
  let composer: ControlDeckComposerModel
  let isSubmitting: Bool
  let isResuming: Bool
  let isInputEnabled: Bool
  let canSubmit: Bool
  let isShellMode: Bool
  let supportsSessionShell: Bool
  let sessionShellAvailable: Bool
  let presentation: ControlDeckPresentation?
  let pendingApproval: ControlDeckApproval?
  let errorMessage: String?
  var chromeStyle: ControlDeckChromeStyle = .standalone

  // Compose callbacks
  let onTextChange: (String) -> Void
  let onKeyCommand: (ControlDeckTextAreaKeyCommand) -> Bool
  let onFocusEvent: (ControlDeckTextAreaFocusEvent) -> Void
  let onPasteImage: () -> Bool
  let canPasteImage: () -> Bool
  let onAddImage: () -> Void
  let onRemoveAttachment: (String) -> Void
  let onDropImages: ([NSItemProvider]) -> Bool
  let onSubmit: () -> Void
  let onToggleShellMode: () -> Void
  let onResume: (() -> Void)?

  // Approval callbacks
  var onApprove: (() -> Void)?
  var onApproveForSession: (() -> Void)?
  var onApproveAlwaysForHost: ((String) -> Void)?
  var onDeny: (() -> Void)?
  var onAnswer: ((String, String?) -> Void)?
  var onSubmitAllAnswers: (([String: [String]]) -> Void)?
  var onGrantPermission: (() -> Void)?
  var onGrantPermissionForSession: (() -> Void)?
  var onDenyPermission: (() -> Void)?

  // Terminal integration
  var terminalTitle: String?
  var currentTool: String?
  var onToggleTerminal: (() -> Void)?
  var onModuleAction: ((ControlDeckStatusModule, String) -> Void)?
  var onApprovalReviewerAction: ((ServerCodexApprovalsReviewer) -> Void)?
  var onSandboxPolicyAction: ((ServerCodexSandboxPolicy) -> Void)?
  var isDictating: Bool = false
  var onDictation: (() -> Void)?
  var onInterrupt: (() -> Void)?
  var onTurnControlAction: ((String) -> Void)?

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var currentMode: ControlDeckMode {
    presentation?.mode ?? .disabled
  }

  private var isApprovalMode: Bool {
    currentMode == .approval && pendingApproval != nil
  }

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  private var horizontalContentPadding: CGFloat {
    isCompact ? Spacing.sm : Spacing.md
  }

  var body: some View {
    @Bindable var composer = composer

    VStack(alignment: .leading, spacing: 0) {
      if isApprovalMode, let approval = pendingApproval {
        // Approval takeover replaces the entire control deck surface
        ControlDeckApprovalTakeover(
          approval: approval,
          onApprove: onApprove,
          onApproveForSession: onApproveForSession,
          onApproveAlwaysForHost: onApproveAlwaysForHost,
          onDeny: onDeny,
          onAnswer: { answer, promptId in onAnswer?(answer, promptId) },
          onSubmitAllAnswers: { answers in onSubmitAllAnswers?(answers) },
          onGrantPermission: onGrantPermission,
          onGrantPermissionForSession: onGrantPermissionForSession,
          onDenyPermission: onDenyPermission
        )
      } else {
        composeContent

        // Status bar only visible in compose/steer/disabled
        if let presentation {
          ControlDeckStatusBar(
            modules: presentation.statusModules,
            onModuleAction: onModuleAction,
            onApprovalReviewerAction: onApprovalReviewerAction,
            onSandboxPolicyAction: onSandboxPolicyAction,
            supportsImages: isInputEnabled && presentation.supportsImages && !isShellMode,
            canPasteImage: isInputEnabled && canPasteImage(),
            canSubmit: canSubmit,
            canResume: presentation.canResume,
            isSubmitting: isSubmitting,
            isResuming: isResuming,
            sendTint: isShellMode ? "composerShell" : presentation.sendTint,
            isShellMode: isShellMode,
            supportsSessionShell: supportsSessionShell,
            sessionShellAvailable: sessionShellAvailable,
            onAddImage: onAddImage,
            onPasteImage: { _ = onPasteImage() },
            onSubmit: onSubmit,
            onToggleShellMode: onToggleShellMode,
            onResume: onResume,
            isDictating: isDictating,
            canInterruptSession: presentation.canInterrupt,
            onDictation: onDictation,
            onInterrupt: onInterrupt,
            onTurnControlAction: onTurnControlAction
          )
          .padding(.horizontal, horizontalContentPadding)
          .padding(.bottom, Spacing.sm)
          .padding(.top, Spacing.xs)
        }
      }
    }
    .background(containerBackground)
    .overlay(containerOverlay)
  }

  private var isSteerMode: Bool {
    currentMode == .steer
  }

  private var isWorkingHighlight: Bool {
    isSteerMode || presentation?.activityStatus.isWorking == true || isSubmitting
  }

  private var hasBorderHighlight: Bool {
    if isApprovalMode { return true }
    if isWorkingHighlight { return true }
    return composer.focusState.isFocused
  }

  private var borderColor: Color {
    if isApprovalMode {
      switch pendingApproval?.kind {
        case .tool: return Color.feedbackCaution.opacity(0.5)
        case .patch: return Color.toolWrite.opacity(0.5)
        case .permission: return Color.statusPermission.opacity(0.5)
        case .question: return Color.statusQuestion.opacity(0.5)
        case .none: return Color.panelBorder
      }
    }
    if isShellMode { return Color.composerShell.opacity(0.5) }
    if isWorkingHighlight { return Color.feedbackWarning.opacity(OpacityTier.vivid) }
    return composer.focusState.isFocused ? Color.accent.opacity(0.5) : Color.panelBorder
  }

  private var backgroundStyle: Color {
    chromeStyle == .embedded ? .clear : Color.backgroundSecondary
  }

  private var containerBackground: some View {
    containerShape.fill(backgroundStyle)
  }

  private var containerShape: some Shape {
    RoundedRectangle(cornerRadius: chromeStyle == .embedded ? Radius.lg : Radius.xl, style: .continuous)
  }

  @ViewBuilder
  private var containerOverlay: some View {
    if chromeStyle == .embedded {
      EmptyView()
    } else {
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .strokeBorder(
          borderColor,
          lineWidth: isWorkingHighlight ? 1.25 : (hasBorderHighlight ? 1.25 : 1)
        )
    }
  }

  // MARK: - Compose Content

  private var composeContent: some View {
    Group {
      // Attachment chips
      if composer.draft.attachments.hasItems {
        ControlDeckAttachmentTray(
          attachments: composer.draft.attachments.items,
          onRemove: onRemoveAttachment
        )
        .padding(.horizontal, horizontalContentPadding)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
      }

      // Text editor
      editorSection
        .padding(.horizontal, horizontalContentPadding)
        .padding(.top, composer.draft.attachments.hasItems ? 0 : Spacing.sm)

      // Error
      if let errorMessage, !errorMessage.isEmpty {
        Text(errorMessage)
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.statusPermission)
          .textSelection(.enabled)
          .lineLimit(2)
          .padding(.horizontal, horizontalContentPadding)
          .padding(.top, Spacing.xs)
      }
    }
  }

  // MARK: - Editor

  private var editorSection: some View {
    @Bindable var composer = composer

    return VStack(alignment: .leading, spacing: Spacing.xs) {
      ZStack(alignment: .topLeading) {
        if composer.draft.text.isEmpty {
          Text(editorPlaceholder)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textTertiary)
            .padding(.top, Spacing.xxs)
            .padding(.leading, Spacing.xxs)
            .allowsHitTesting(false)
        }

        ControlDeckTextArea(
          text: $composer.draft.text,
          focusRequestSignal: $composer.focusState.focusRequestSignal,
          blurRequestSignal: $composer.focusState.blurRequestSignal,
          moveCursorToEndSignal: $composer.focusState.moveCursorToEndSignal,
          measuredHeight: $composer.focusState.measuredHeight,
          isEnabled: isInputEnabled,
          minLines: 1,
          maxLines: 8,
          onPasteImage: { isShellMode ? false : onPasteImage() },
          canPasteImage: { !isShellMode && canPasteImage() },
          onKeyCommand: onKeyCommand,
          onFocusEvent: onFocusEvent
        )
      }
      .frame(height: max(composer.focusState.measuredHeight, 20))
    }
    .onDrop(
      of: [.image, .fileURL],
      isTargeted: nil,
      perform: { providers in
        isShellMode ? false : onDropImages(providers)
      }
    )
    .onChange(of: composer.draft.text) { _, newValue in
      onTextChange(newValue)
    }
  }

  private var editorPlaceholder: String {
    if isShellMode {
      return "Run a command in this session\u{2026}"
    }
    return presentation?.placeholder ?? "Message the session\u{2026}"
  }
}
