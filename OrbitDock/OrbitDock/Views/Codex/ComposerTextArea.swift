//
//  ComposerTextArea.swift
//  OrbitDock
//
//  Cross-platform multiline composer input backed by UITextView/NSTextView.
//

import SwiftUI

enum ComposerTextAreaKeyCommand {
  case escape
  case upArrow
  case downArrow
  case tab
  case returnKey
  case shiftReturn
  case controlN
  case controlP
  case commandShiftT
}

enum ComposerTextAreaFocusEvent {
  case began
  case ended(userInitiated: Bool)
}

struct ComposerTextArea: View {
  @Binding var text: String
  let placeholder: String
  @Binding var focusRequestSignal: Int
  @Binding var blurRequestSignal: Int
  @Binding var moveCursorToEndSignal: Int
  @Binding var measuredHeight: CGFloat
  let isEnabled: Bool
  let minLines: Int
  let maxLines: Int
  let onPasteImage: () -> Bool
  let canPasteImage: () -> Bool
  let onKeyCommand: (ComposerTextAreaKeyCommand) -> Bool
  let onFocusEvent: (ComposerTextAreaFocusEvent) -> Void

  init(
    text: Binding<String>,
    placeholder: String,
    focusRequestSignal: Binding<Int>,
    blurRequestSignal: Binding<Int>,
    moveCursorToEndSignal: Binding<Int>,
    measuredHeight: Binding<CGFloat>,
    isEnabled: Bool,
    minLines: Int = 1,
    maxLines: Int = 5,
    onPasteImage: @escaping () -> Bool,
    canPasteImage: @escaping () -> Bool,
    onKeyCommand: @escaping (ComposerTextAreaKeyCommand) -> Bool,
    onFocusEvent: @escaping (ComposerTextAreaFocusEvent) -> Void
  ) {
    _text = text
    self.placeholder = placeholder
    _focusRequestSignal = focusRequestSignal
    _blurRequestSignal = blurRequestSignal
    _moveCursorToEndSignal = moveCursorToEndSignal
    _measuredHeight = measuredHeight
    self.isEnabled = isEnabled
    self.minLines = minLines
    self.maxLines = maxLines
    self.onPasteImage = onPasteImage
    self.canPasteImage = canPasteImage
    self.onKeyCommand = onKeyCommand
    self.onFocusEvent = onFocusEvent
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholder)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textTertiary)
          .padding(.top, Spacing.xxs)
          .padding(.leading, Spacing.xxs)
          .allowsHitTesting(false)
      }

      PlatformComposerTextArea(
        text: $text,
        focusRequestSignal: $focusRequestSignal,
        blurRequestSignal: $blurRequestSignal,
        moveCursorToEndSignal: $moveCursorToEndSignal,
        measuredHeight: $measuredHeight,
        isEnabled: isEnabled,
        minLines: minLines,
        maxLines: maxLines,
        onPasteImage: onPasteImage,
        canPasteImage: canPasteImage,
        onKeyCommand: onKeyCommand,
        onFocusEvent: onFocusEvent
      )
    }
  }
}

private func clampedSelection(_ selection: NSRange, maxLength: Int) -> NSRange {
  let safeLocation = max(0, min(selection.location, maxLength))
  let remaining = max(0, maxLength - safeLocation)
  let safeLength = max(0, min(selection.length, remaining))
  return NSRange(location: safeLocation, length: safeLength)
}

#if os(iOS)
  import UIKit

  private typealias PlatformComposerTextArea = ComposerTextAreaIOS

  private struct ComposerTextAreaIOS: UIViewRepresentable {
    @Binding var text: String
    @Binding var focusRequestSignal: Int
    @Binding var blurRequestSignal: Int
    @Binding var moveCursorToEndSignal: Int
    @Binding var measuredHeight: CGFloat
    let isEnabled: Bool
    let minLines: Int
    let maxLines: Int
    let onPasteImage: () -> Bool
    let canPasteImage: () -> Bool
    let onKeyCommand: (ComposerTextAreaKeyCommand) -> Bool
    let onFocusEvent: (ComposerTextAreaFocusEvent) -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ComposerUITextView {
      let textView = ComposerUITextView(frame: .zero)
      let coordinator = context.coordinator

      textView.backgroundColor = .clear
      textView.font = .systemFont(ofSize: TypeScale.body)
      textView.textColor = .label
      textView.autocorrectionType = .no
      textView.spellCheckingType = .no
      textView.smartQuotesType = .no
      textView.smartDashesType = .no
      textView.keyboardDismissMode = .interactive
      textView.textContainer.widthTracksTextView = true
      textView.textContainer.lineBreakMode = .byWordWrapping
      textView.textContainer.lineFragmentPadding = 0
      textView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
      textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
      textView.isScrollEnabled = false
      textView.delegate = coordinator
      textView.text = text
      textView.onBoundsWidthChange = { [weak coordinator, weak textView] in
        guard let coordinator, let textView else { return }
        coordinator.recalculateHeight(for: textView)
      }
      coordinator.textView = textView
      return textView
    }

    func updateUIView(_ uiView: ComposerUITextView, context: Context) {
      let coordinator = context.coordinator
      coordinator.parent = self
      coordinator.textView = uiView

      uiView.isEditable = isEnabled
      uiView.isSelectable = isEnabled
      uiView.onPasteImage = onPasteImage
      uiView.canPasteImage = canPasteImage
      uiView.onKeyCommand = onKeyCommand

      if coordinator.syncTextFromSwiftUI(in: uiView) {
        coordinator.recalculateHeight(for: uiView)
      }

      coordinator.applyFocusRequestIfNeeded(in: uiView)
      coordinator.applyBlurRequestIfNeeded(in: uiView)
      coordinator.applyCursorRequestIfNeeded(in: uiView)
    }

    static func dismantleUIView(_ uiView: ComposerUITextView, coordinator: Coordinator) {
      uiView.delegate = nil
      uiView.onPasteImage = nil
      uiView.canPasteImage = nil
      uiView.onKeyCommand = nil
      uiView.onBoundsWidthChange = nil
      coordinator.textView = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
      var parent: ComposerTextAreaIOS
      weak var textView: ComposerUITextView?

      private var isApplyingExternalText = false
      private var lastAppliedFocusRequestSignal: Int
      private var lastAppliedBlurRequestSignal: Int
      private var lastAppliedCursorSignal: Int

      init(parent: ComposerTextAreaIOS) {
        self.parent = parent
        lastAppliedFocusRequestSignal = parent.focusRequestSignal
        lastAppliedBlurRequestSignal = parent.blurRequestSignal
        lastAppliedCursorSignal = parent.moveCursorToEndSignal
      }

      func syncTextFromSwiftUI(in textView: ComposerUITextView) -> Bool {
        let incoming = parent.text
        guard textView.text != incoming else { return false }
        guard textView.markedTextRange == nil else { return false }

        let previousSelection = textView.selectedRange
        let shouldRestoreSelection = textView.isFirstResponder

        isApplyingExternalText = true
        textView.text = incoming
        isApplyingExternalText = false

        if shouldRestoreSelection {
          textView.selectedRange = clampedSelection(previousSelection, maxLength: incoming.utf16.count)
        }

        return true
      }

      func applyFocusRequestIfNeeded(in textView: ComposerUITextView) {
        guard parent.focusRequestSignal != lastAppliedFocusRequestSignal else { return }
        guard textView.window != nil else { return }

        if !textView.isFirstResponder {
          textView.becomeFirstResponder()
        }
        lastAppliedFocusRequestSignal = parent.focusRequestSignal
      }

      func applyBlurRequestIfNeeded(in textView: ComposerUITextView) {
        guard parent.blurRequestSignal != lastAppliedBlurRequestSignal else { return }

        if textView.isFirstResponder {
          textView.resignFirstResponder()
        }
        lastAppliedBlurRequestSignal = parent.blurRequestSignal
      }

      func applyCursorRequestIfNeeded(in textView: ComposerUITextView) {
        guard parent.moveCursorToEndSignal != lastAppliedCursorSignal else { return }
        guard textView.markedTextRange == nil else { return }

        let end = (textView.text ?? "").utf16.count
        textView.selectedRange = NSRange(location: end, length: 0)
        lastAppliedCursorSignal = parent.moveCursorToEndSignal
      }

      func textViewDidBeginEditing(_ textView: UITextView) {
        parent.onFocusEvent(.began)
      }

      func textViewDidEndEditing(_ textView: UITextView) {
        parent.onFocusEvent(.ended(userInitiated: true))
      }

      func textViewDidChange(_ textView: UITextView) {
        guard !isApplyingExternalText else { return }
        let updated = textView.text ?? ""
        if parent.text != updated {
          parent.text = updated
        }
        recalculateHeight(for: textView)
      }

      func recalculateHeight(for textView: UITextView) {
        let width = max(textView.bounds.width, 1)
        guard width > 1 else { return }

        let fittingSize = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = textView.font?.lineHeight ?? UIFont.systemFont(ofSize: TypeScale.body).lineHeight
        let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let minHeight = ceil(lineHeight * CGFloat(parent.minLines) + verticalInsets)
        let maxHeight = ceil(lineHeight * CGFloat(parent.maxLines) + verticalInsets)
        let clamped = min(max(fittingSize.height, minHeight), maxHeight)
        let shouldScroll = fittingSize.height > maxHeight + 0.5

        if abs(parent.measuredHeight - clamped) > 0.5 {
          parent.measuredHeight = clamped
        }

        if textView.isScrollEnabled != shouldScroll {
          textView.isScrollEnabled = shouldScroll
        }
      }
    }
  }

  private final class ComposerUITextView: UITextView {
    var onPasteImage: (() -> Bool)?
    var canPasteImage: (() -> Bool)?
    var onKeyCommand: ((ComposerTextAreaKeyCommand) -> Bool)?
    var onBoundsWidthChange: (() -> Void)?

    private var previousBoundsWidth: CGFloat = 0

    override func layoutSubviews() {
      super.layoutSubviews()
      let width = bounds.width
      if abs(previousBoundsWidth - width) > 0.5 {
        previousBoundsWidth = width
        onBoundsWidthChange?()
      }
    }

    override func paste(_ sender: Any?) {
      if onPasteImage?() == true {
        return
      }
      super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      if action == #selector(paste(_:)), canPasteImage?() == true {
        return true
      }
      return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
      [
        UIKeyCommand(input: "t", modifierFlags: [.command, .shift], action: #selector(handleCommandShiftT)),
      ]
    }

    @objc private func handleCommandShiftT() {
      _ = onKeyCommand?(.commandShiftT)
    }
  }
#endif

#if os(macOS)
  import AppKit

  private typealias PlatformComposerTextArea = ComposerTextAreaMacOS

  private struct ComposerTextAreaMacOS: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusRequestSignal: Int
    @Binding var blurRequestSignal: Int
    @Binding var moveCursorToEndSignal: Int
    @Binding var measuredHeight: CGFloat
    let isEnabled: Bool
    let minLines: Int
    let maxLines: Int
    let onPasteImage: () -> Bool
    let canPasteImage: () -> Bool
    let onKeyCommand: (ComposerTextAreaKeyCommand) -> Bool
    let onFocusEvent: (ComposerTextAreaFocusEvent) -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
      let scrollView = NSScrollView(frame: .zero)
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      scrollView.hasVerticalScroller = false
      scrollView.hasHorizontalScroller = false
      scrollView.autohidesScrollers = true
      scrollView.verticalScrollElasticity = .none

      let textView = ComposerNSTextView(frame: .zero)
      let coordinator = context.coordinator

      textView.delegate = coordinator
      textView.isRichText = false
      textView.importsGraphics = false
      textView.drawsBackground = false
      textView.font = .systemFont(ofSize: TypeScale.body)
      textView.textColor = .labelColor
      textView.insertionPointColor = .labelColor
      textView.isContinuousSpellCheckingEnabled = false
      textView.isAutomaticSpellingCorrectionEnabled = false
      textView.isAutomaticTextReplacementEnabled = false
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      textView.isVerticallyResizable = true
      textView.isHorizontallyResizable = false
      textView.minSize = NSSize(width: 0, height: 0)
      textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      textView.autoresizingMask = [.width]
      textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
      textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
      textView.textContainer?.widthTracksTextView = true
      textView.textContainer?.lineFragmentPadding = 0
      textView.textContainerInset = NSSize(width: 0, height: 2)
      textView.string = text
      textView.onPasteImage = onPasteImage
      textView.canPasteImage = canPasteImage
      textView.onKeyCommand = onKeyCommand
      textView.onBoundsWidthChange = { [weak coordinator, weak textView] in
        guard let coordinator, let textView else { return }
        coordinator.recalculateHeight(for: textView)
      }

      scrollView.documentView = textView
      coordinator.textView = textView
      return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
      let coordinator = context.coordinator
      coordinator.parent = self

      guard let textView = coordinator.textView ?? (nsView.documentView as? ComposerNSTextView) else { return }
      coordinator.textView = textView

      if textView.isEditable != isEnabled {
        textView.isEditable = isEnabled
      }
      if textView.isSelectable != isEnabled {
        textView.isSelectable = isEnabled
      }
      textView.onPasteImage = onPasteImage
      textView.canPasteImage = canPasteImage
      textView.onKeyCommand = onKeyCommand

      if coordinator.syncTextFromSwiftUI(in: textView) {
        coordinator.recalculateHeight(for: textView)
      }

      coordinator.applyFocusRequestIfNeeded(in: textView)
      coordinator.applyBlurRequestIfNeeded(in: textView)
      coordinator.applyCursorRequestIfNeeded(in: textView)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
      if let textView = nsView.documentView as? ComposerNSTextView {
        textView.delegate = nil
        textView.onPasteImage = nil
        textView.canPasteImage = nil
        textView.onKeyCommand = nil
        textView.onBoundsWidthChange = nil
      }
      coordinator.textView = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
      var parent: ComposerTextAreaMacOS
      weak var textView: ComposerNSTextView?

      private var isApplyingExternalText = false
      private var lastAppliedFocusRequestSignal: Int
      private var lastAppliedBlurRequestSignal: Int
      private var lastAppliedCursorSignal: Int

      init(parent: ComposerTextAreaMacOS) {
        self.parent = parent
        lastAppliedFocusRequestSignal = parent.focusRequestSignal
        lastAppliedBlurRequestSignal = parent.blurRequestSignal
        lastAppliedCursorSignal = parent.moveCursorToEndSignal
      }

      func syncTextFromSwiftUI(in textView: ComposerNSTextView) -> Bool {
        let incoming = parent.text
        guard textView.string != incoming else { return false }
        guard !textView.hasMarkedText() else { return false }

        let previousSelection = currentSelection(in: textView)
        let shouldRestoreSelection = isTextViewFirstResponder(textView)

        isApplyingExternalText = true
        textView.string = incoming
        isApplyingExternalText = false

        if shouldRestoreSelection {
          let clamped = clampedSelection(previousSelection, maxLength: incoming.utf16.count)
          textView.setSelectedRange(clamped)
        }

        return true
      }

      func applyFocusRequestIfNeeded(in textView: ComposerNSTextView) {
        guard parent.focusRequestSignal != lastAppliedFocusRequestSignal else { return }
        guard let window = textView.window else { return }

        if !isTextViewFirstResponder(textView) {
          window.makeFirstResponder(textView)
        }
        lastAppliedFocusRequestSignal = parent.focusRequestSignal
      }

      func applyBlurRequestIfNeeded(in textView: ComposerNSTextView) {
        guard parent.blurRequestSignal != lastAppliedBlurRequestSignal else { return }
        if let window = textView.window, isTextViewFirstResponder(textView) {
          window.makeFirstResponder(nil)
        }
        lastAppliedBlurRequestSignal = parent.blurRequestSignal
      }

      func applyCursorRequestIfNeeded(in textView: ComposerNSTextView) {
        guard parent.moveCursorToEndSignal != lastAppliedCursorSignal else { return }
        guard !textView.hasMarkedText() else { return }

        let end = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: end, length: 0))
        lastAppliedCursorSignal = parent.moveCursorToEndSignal
      }

      func textDidBeginEditing(_ notification: Notification) {
        parent.onFocusEvent(.began)
      }

      func textDidEndEditing(_ notification: Notification) {
        parent.onFocusEvent(.ended(userInitiated: blurWasUserInitiated()))
      }

      func textDidChange(_ notification: Notification) {
        guard !isApplyingExternalText else { return }
        guard let textView = notification.object as? NSTextView else { return }

        let updated = textView.string
        if parent.text != updated {
          parent.text = updated
        }
        recalculateHeight(for: textView)
      }

      func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        guard isTextViewFirstResponder(textView) else { return }
        let selection = currentSelection(in: textView)
        let clamped = clampedSelection(selection, maxLength: textView.string.utf16.count)
        if clamped != selection {
          textView.setSelectedRange(clamped)
        }
      }

      func recalculateHeight(for textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        let width = max(textView.bounds.width, 1)
        guard width > 1 else { return }

        if abs(textContainer.containerSize.width - width) > 0.5 {
          textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }

        layoutManager.ensureLayout(for: textContainer)

        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let font = textView.font ?? NSFont.systemFont(ofSize: TypeScale.body)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let verticalInsets = textView.textContainerInset.height * 2
        let minHeight = ceil(lineHeight * CGFloat(parent.minLines) + verticalInsets)
        let maxHeight = ceil(lineHeight * CGFloat(parent.maxLines) + verticalInsets)
        let fitting = ceil(max(usedHeight + verticalInsets, minHeight))
        let clamped = min(fitting, maxHeight)

        if abs(parent.measuredHeight - clamped) > 0.5 {
          parent.measuredHeight = clamped
        }
      }

      private func isTextViewFirstResponder(_ textView: NSTextView) -> Bool {
        guard let window = textView.window else { return false }
        return window.firstResponder === textView
      }

      private func currentSelection(in textView: NSTextView) -> NSRange {
        if let selected = textView.selectedRanges.first as? NSRange {
          return selected
        }
        let end = textView.string.utf16.count
        return NSRange(location: end, length: 0)
      }

      private func blurWasUserInitiated() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
          case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown:
            return true
          default:
            return false
        }
      }
    }
  }

  private final class ComposerNSTextView: NSTextView {
    var onPasteImage: (() -> Bool)?
    var canPasteImage: (() -> Bool)?
    var onKeyCommand: ((ComposerTextAreaKeyCommand) -> Bool)?
    var onBoundsWidthChange: (() -> Void)?

    private var previousBoundsWidth: CGFloat = 0

    override func layout() {
      super.layout()
      let width = bounds.width
      if abs(previousBoundsWidth - width) > 0.5 {
        previousBoundsWidth = width
        onBoundsWidthChange?()
      }
    }

    override func paste(_ sender: Any?) {
      if onPasteImage?() == true {
        return
      }
      super.paste(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
      if item.action == #selector(paste(_:)), canPasteImage?() == true {
        return true
      }
      return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      if handleKeyEvent(event) {
        return true
      }
      return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
      if handleKeyEvent(event) {
        return
      }
      super.keyDown(with: event)
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
      guard let command = mapCommand(from: event) else { return false }
      return onKeyCommand?(command) ?? false
    }

    private func mapCommand(from event: NSEvent) -> ComposerTextAreaKeyCommand? {
      let modifiers = event.modifierFlags.intersection([.shift, .control, .command, .option])
      let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

      if modifiers.contains(.command), modifiers.contains(.shift), chars == "t" {
        return .commandShiftT
      }

      if modifiers == [.control], chars == "n" {
        return .controlN
      }

      if modifiers == [.control], chars == "p" {
        return .controlP
      }

      switch event.keyCode {
        case 53:
          return .escape
        case 126:
          return .upArrow
        case 125:
          return .downArrow
        case 48:
          return .tab
        case 36, 76:
          return modifiers.contains(.shift) ? .shiftReturn : .returnKey
        default:
          return nil
      }
    }
  }
#endif
