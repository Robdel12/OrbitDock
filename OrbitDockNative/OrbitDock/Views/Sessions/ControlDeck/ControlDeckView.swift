import SwiftUI
import UniformTypeIdentifiers

enum ControlDeckChromeStyle {
  case standalone
  case embedded
}

struct ControlDeckView: View {
  // State from parent
  @Binding var draft: ControlDeckDraft
  @Binding var focusState: ControlDeckFocusState
  let isSubmitting: Bool
  let isResuming: Bool
  let isInputEnabled: Bool
  let canSubmit: Bool
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
  let onResume: (() -> Void)?

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

  private var currentMode: ControlDeckMode {
    presentation?.mode ?? .disabled
  }

  private var isApprovalMode: Bool {
    currentMode == .approval && pendingApproval != nil
  }

  private var isCompactIOS: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private var horizontalContentPadding: CGFloat {
    isCompactIOS ? Spacing.sm : Spacing.md
  }

  // MARK: - Approval Cluster Support

  private var approvalClusterMode: ControlDeckStatusBar.ApprovalClusterMode {
    guard isApprovalMode, let approval = pendingApproval else { return .none }
    switch approval.kind {
      case .tool: return .tool
      case .patch: return .patch
      case .permission: return .permission
      case .question: return .none  // Questions have inline answers, not approve/deny
    }
  }

  private var resolvedApproveAction: (() -> Void)? {
    guard isApprovalMode, let approval = pendingApproval else { return nil }
    switch approval.kind {
      case .tool, .patch: return onApprove
      case .permission: return onGrantPermission
      case .question: return nil
    }
  }

  private var resolvedApproveForSessionAction: (() -> Void)? {
    guard isApprovalMode, let approval = pendingApproval else { return nil }
    switch approval.kind {
      case .tool, .patch: return onApproveForSession
      case .permission: return onGrantPermissionForSession
      case .question: return nil
    }
  }

  private var resolvedDenyAction: (() -> Void)? {
    guard isApprovalMode, let approval = pendingApproval else { return nil }
    switch approval.kind {
      case .tool, .patch: return onDeny
      case .permission: return onDenyPermission
      case .question: return nil
    }
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
          supportsImages: !isApprovalMode && isInputEnabled && presentation.supportsImages,
          canPasteImage: !isApprovalMode && isInputEnabled && canPasteImage(),
          canSubmit: !isApprovalMode && canSubmit,
          canResume: !isApprovalMode && (presentation.canResume),
          isSubmitting: isSubmitting,
          isResuming: isResuming,
          sendTint: presentation.sendTint,
          onAddImage: onAddImage,
          onPasteImage: { _ = onPasteImage() },
          onSubmit: onSubmit,
          onResume: onResume,
          isDictating: isDictating,
          isSessionWorking: isSessionWorking,
          onDictation: onDictation,
          onInterrupt: onInterrupt,
          approvalMode: approvalClusterMode,
          onApprove: resolvedApproveAction,
          onApproveForSession: resolvedApproveForSessionAction,
          onDeny: resolvedDenyAction
        )
        .padding(.horizontal, horizontalContentPadding)
        .padding(.bottom, Spacing.sm)
        .padding(.top, Spacing.xs)
      }
    }
    .background(containerBackground)
    .overlay(containerOverlay)
  }

  private var isSteerMode: Bool {
    currentMode == .steer
  }

  private var isWorkingHighlight: Bool {
    isSteerMode || isSessionWorking || sessionDisplayStatus == .working || isSubmitting
  }

  private var hasBorderHighlight: Bool {
    if isApprovalMode { return true }
    if isWorkingHighlight { return true }
    return focusState.isFocused
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
    if isWorkingHighlight { return Color.feedbackWarning.opacity(OpacityTier.vivid) }
    return focusState.isFocused ? Color.accent.opacity(0.5) : Color.panelBorder
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
      if draft.attachments.hasItems {
        ControlDeckAttachmentTray(
          attachments: draft.attachments.items,
          onRemove: onRemoveAttachment
        )
        .padding(.horizontal, horizontalContentPadding)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
      }

      // Text editor
      editorSection
        .padding(.horizontal, horizontalContentPadding)
        .padding(.top, draft.attachments.hasItems ? 0 : Spacing.sm)

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
    ZStack(alignment: .topLeading) {
      if draft.text.isEmpty {
        Text(presentation?.placeholder ?? "Message the session\u{2026}")
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textTertiary)
          .padding(.top, Spacing.xxs)
          .padding(.leading, Spacing.xxs)
          .allowsHitTesting(false)
      }

      ControlDeckTextArea(
        text: $draft.text,
        focusRequestSignal: $focusState.focusRequestSignal,
        blurRequestSignal: $focusState.blurRequestSignal,
        moveCursorToEndSignal: $focusState.moveCursorToEndSignal,
        measuredHeight: $focusState.measuredHeight,
        isEnabled: isInputEnabled,
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

}
