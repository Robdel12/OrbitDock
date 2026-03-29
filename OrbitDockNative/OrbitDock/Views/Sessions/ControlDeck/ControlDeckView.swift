import SwiftUI
import UniformTypeIdentifiers

enum ControlDeckChromeStyle {
  case standalone
  case embedded
}

struct ControlDeckView: View {
  // State from parent
  @Binding var draft: ControlDeckDraft
  @Binding var focusState: ComposerFocusState
  @Binding var completionState: ControlDeckCompletionState
  let isSubmitting: Bool
  let canSubmit: Bool
  let presentation: ControlDeckPresentation?
  let pendingApproval: ControlDeckApproval?
  let completionSuggestions: [ControlDeckCompletionSuggestion]
  let errorMessage: String?
  var chromeStyle: ControlDeckChromeStyle = .standalone

  // Compose callbacks
  let onTextChange: (String) -> Void
  let onKeyCommand: (ComposerTextAreaKeyCommand) -> Bool
  let onFocusEvent: (ComposerTextAreaFocusEvent) -> Void
  let onPasteImage: () -> Bool
  let canPasteImage: () -> Bool
  let onAddImage: () -> Void
  let onRemoveAttachment: (String) -> Void
  let onDropImages: ([NSItemProvider]) -> Bool
  let onSelectSuggestion: (ControlDeckCompletionSuggestion) -> Void
  let onSubmit: () -> Void

  // Approval callbacks
  var onApprove: (() -> Void)?
  var onApproveForSession: (() -> Void)?
  var onDeny: (() -> Void)?
  var onAnswer: ((String, String?) -> Void)?
  var onGrantPermission: (() -> Void)?
  var onGrantPermissionForSession: (() -> Void)?
  var onDenyPermission: (() -> Void)?

  // Terminal integration
  var terminalTitle: String?
  var sessionDisplayStatus: SessionDisplayStatus = .ended
  var currentTool: String?
  var onToggleTerminal: (() -> Void)?
  var onModuleAction: ((ControlDeckStatusModule, String) -> Void)?
  var onApprovalReviewerAction: ((ServerCodexApprovalsReviewer) -> Void)?
  var isDictating: Bool = false
  var isSessionWorking: Bool = false
  var onDictation: (() -> Void)?
  var onInterrupt: (() -> Void)?

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isApprovalMode: Bool {
    presentation?.mode == .approval && pendingApproval != nil
  }

  private var isCompactIOS: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private var shouldOverlayCompletions: Bool {
    isCompactIOS
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if isApprovalMode, let approval = pendingApproval {
        // Approval zone replaces the editor + submit bar
        ControlDeckApprovalZone(
          approval: approval,
          onApprove: { onApprove?() },
          onApproveForSession: { onApproveForSession?() },
          onDeny: { onDeny?() },
          onAnswer: { answer, promptId in onAnswer?(answer, promptId) },
          onGrantPermission: { onGrantPermission?() },
          onGrantPermissionForSession: { onGrantPermissionForSession?() },
          onDenyPermission: { onDenyPermission?() }
        )
      } else {
        composeContent
      }

      // Unified action + status bar — always visible (anchors across mode shifts)
      if let presentation {
        ControlDeckStatusBar(
          modules: presentation.statusModules,
          onModuleAction: onModuleAction,
          onApprovalReviewerAction: onApprovalReviewerAction,
          supportsImages: !isApprovalMode && (presentation.supportsImages),
          canPasteImage: !isApprovalMode && canPasteImage(),
          canSubmit: !isApprovalMode && canSubmit,
          isSubmitting: isSubmitting,
          sendTint: presentation.sendTint,
          onAddImage: onAddImage,
          onPasteImage: { _ = onPasteImage() },
          onSubmit: onSubmit,
          isDictating: isDictating,
          isSessionWorking: isSessionWorking,
          onDictation: onDictation,
          onInterrupt: onInterrupt
        )
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .padding(.top, Spacing.xs)
      }
    }
    .background(backgroundStyle)
    .clipShape(containerShape)
    .overlay(containerOverlay)
    .overlay(alignment: .bottomLeading) {
      if shouldOverlayCompletions, !isApprovalMode, completionState.isActive, !completionSuggestions.isEmpty {
        completionPanel
          .padding(.horizontal, Spacing.md)
          .padding(.bottom, 54)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .shadow(color: shadowColor, radius: shadowRadius, y: 0)
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isApprovalMode)
    .animation(.easeInOut(duration: 0.2), value: focusState.isFocused)
    .animation(.easeInOut(duration: 0.25), value: isSteerMode)
  }

  private var isSteerMode: Bool {
    presentation?.mode == .steer
  }

  private var hasBorderHighlight: Bool {
    if isApprovalMode { return true }
    if isSteerMode { return true }
    return focusState.isFocused
  }

  private var borderColor: Color {
    if isApprovalMode {
      switch pendingApproval?.kind {
        case .tool: return Color.feedbackCaution.opacity(0.5)
        case .permission: return Color.statusPermission.opacity(0.5)
        case .question: return Color.accent.opacity(0.5)
        case .none: return Color.panelBorder
      }
    }
    if isSteerMode { return Color.statusWorking.opacity(0.5) }
    return focusState.isFocused ? Color.accent.opacity(0.5) : Color.panelBorder
  }

  private var borderGlowColor: Color {
    if isApprovalMode { return .clear }
    if isSteerMode { return Color.statusWorking.opacity(0.12) }
    if focusState.isFocused { return Color.accent.opacity(0.12) }
    return .clear
  }

  private var backgroundStyle: Color {
    chromeStyle == .embedded ? .clear : Color.backgroundSecondary
  }

  private var containerShape: some Shape {
    RoundedRectangle(cornerRadius: chromeStyle == .embedded ? Radius.lg : Radius.xl, style: .continuous)
  }

  @ViewBuilder
  private var containerOverlay: some View {
    if chromeStyle == .standalone {
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .strokeBorder(
          borderColor,
          lineWidth: hasBorderHighlight ? 1.5 : 1
        )
    } else {
      EmptyView()
    }
  }

  private var shadowColor: Color {
    chromeStyle == .embedded ? .clear : borderGlowColor
  }

  private var shadowRadius: CGFloat {
    chromeStyle == .embedded ? 0 : 16
  }

  // MARK: - Compose Content

  private var composeContent: some View {
    Group {
      // Attachment chips
      if draft.attachments.hasItems {
        ControlDeckAttachmentTray(
          attachments: draft.attachments.items,
          onRemove: onRemoveAttachment
        )
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
      }

      // Text editor
      editorSection
        .padding(.horizontal, Spacing.md)
        .padding(.top, draft.attachments.hasItems ? 0 : Spacing.sm)

      // Completion panel
      if !shouldOverlayCompletions, completionState.isActive, !completionSuggestions.isEmpty {
        completionPanel
          .padding(.horizontal, Spacing.md)
          .padding(.top, Spacing.xs)
      }

      // Error
      if let errorMessage, !errorMessage.isEmpty {
        Text(errorMessage)
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.statusPermission)
          .textSelection(.enabled)
          .lineLimit(2)
          .padding(.horizontal, Spacing.lg)
          .padding(.top, Spacing.xs)
      }
    }
  }

  // MARK: - Editor

  private var editorSection: some View {
    ZStack(alignment: .topLeading) {
      if draft.text.isEmpty {
        Text(presentation?.placeholder ?? "Message the session\u{2026}")
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textTertiary)
          .padding(.top, Spacing.xxs)
          .padding(.leading, Spacing.xxs)
          .allowsHitTesting(false)
      }

      ComposerTextArea(
        text: $draft.text,
        placeholder: "",
        focusRequestSignal: $focusState.focusRequestSignal,
        blurRequestSignal: $focusState.blurRequestSignal,
        moveCursorToEndSignal: $focusState.moveCursorToEndSignal,
        measuredHeight: $focusState.measuredHeight,
        isEnabled: !isSubmitting,
        minLines: 1,
        maxLines: 8,
        onPasteImage: onPasteImage,
        canPasteImage: canPasteImage,
        onKeyCommand: onKeyCommand,
        onFocusEvent: onFocusEvent
      )
    }
    .frame(height: max(focusState.measuredHeight, 20))
    .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: onDropImages)
    .onChange(of: draft.text) { _, newValue in
      onTextChange(newValue)
    }
  }

  private var completionPanel: some View {
    ControlDeckCompletionPanel(
      mode: completionState.mode,
      suggestions: completionSuggestions,
      selectedIndex: completionState.selectedIndex,
      onSelect: onSelectSuggestion
    )
  }
}
