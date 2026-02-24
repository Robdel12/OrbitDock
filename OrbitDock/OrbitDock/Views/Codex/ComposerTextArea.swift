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

struct ComposerTextArea: View {
  @Binding var text: String
  let placeholder: String
  @Binding var isFocused: Bool
  @Binding var measuredHeight: CGFloat
  let isEnabled: Bool
  let minLines: Int
  let maxLines: Int
  let onPasteImage: () -> Bool
  let canPasteImage: () -> Bool
  let onKeyCommand: (ComposerTextAreaKeyCommand) -> Bool

  init(
    text: Binding<String>,
    placeholder: String,
    isFocused: Binding<Bool>,
    measuredHeight: Binding<CGFloat>,
    isEnabled: Bool,
    minLines: Int = 1,
    maxLines: Int = 5,
    onPasteImage: @escaping () -> Bool,
    canPasteImage: @escaping () -> Bool,
    onKeyCommand: @escaping (ComposerTextAreaKeyCommand) -> Bool
  ) {
    _text = text
    self.placeholder = placeholder
    _isFocused = isFocused
    _measuredHeight = measuredHeight
    self.isEnabled = isEnabled
    self.minLines = minLines
    self.maxLines = maxLines
    self.onPasteImage = onPasteImage
    self.canPasteImage = canPasteImage
    self.onKeyCommand = onKeyCommand
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholder)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textTertiary)
          .padding(.top, 2)
          .padding(.leading, 2)
          .allowsHitTesting(false)
      }

      PlatformComposerTextArea(
        text: $text,
        isFocused: $isFocused,
        measuredHeight: $measuredHeight,
        isEnabled: isEnabled,
        minLines: minLines,
        maxLines: maxLines,
        onPasteImage: onPasteImage,
        canPasteImage: canPasteImage,
        onKeyCommand: onKeyCommand
      )
    }
  }
}

#if os(iOS)
  import UIKit

  private typealias PlatformComposerTextArea = ComposerTextAreaIOS

  private struct ComposerTextAreaIOS: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let isEnabled: Bool
    let minLines: Int
    let maxLines: Int
    let onPasteImage: () -> Bool
    let canPasteImage: () -> Bool
    let onKeyCommand: (ComposerTextAreaKeyCommand) -> Bool

    func makeCoordinator() -> Coordinator {
      Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ComposerUITextView {
      let textView = ComposerUITextView(frame: .zero)
      textView.backgroundColor = .clear
      textView.font = .systemFont(ofSize: TypeScale.body)
      textView.textColor = .label
      textView.autocorrectionType = .yes
      textView.spellCheckingType = .yes
      textView.smartQuotesType = .yes
      textView.smartDashesType = .yes
      textView.keyboardDismissMode = .interactive
      textView.textContainer.widthTracksTextView = true
      textView.textContainer.lineBreakMode = .byWordWrapping
      textView.textContainer.lineFragmentPadding = 0
      textView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
      textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
      textView.isScrollEnabled = false
      textView.delegate = context.coordinator
      return textView
    }

    func updateUIView(_ uiView: ComposerUITextView, context: Context) {
      context.coordinator.parent = self

      if uiView.text != text {
        uiView.text = text
      }

      uiView.isEditable = isEnabled
      uiView.isSelectable = isEnabled
      uiView.onPasteImage = onPasteImage
      uiView.canPasteImage = canPasteImage
      uiView.onKeyCommand = onKeyCommand

      context.coordinator.recalculateHeight(for: uiView)

      if isFocused {
        if uiView.window != nil, !uiView.isFirstResponder {
          uiView.becomeFirstResponder()
        }
      } else if uiView.isFirstResponder {
        uiView.resignFirstResponder()
      }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
      var parent: ComposerTextAreaIOS

      init(parent: ComposerTextAreaIOS) {
        self.parent = parent
      }

      func textViewDidBeginEditing(_ textView: UITextView) {
        guard !parent.isFocused else { return }
        Task { @MainActor [weak self] in
          self?.parent.isFocused = true
        }
      }

      func textViewDidEndEditing(_ textView: UITextView) {
        guard parent.isFocused else { return }
        Task { @MainActor [weak self] in
          self?.parent.isFocused = false
        }
      }

      func textViewDidChange(_ textView: UITextView) {
        let updated = textView.text ?? ""
        if parent.text != updated {
          parent.text = updated
        }
        recalculateHeight(for: textView)
      }

      func recalculateHeight(for textView: UITextView) {
        let width = max(textView.bounds.width, 1)
        let fittingSize = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = textView.font?.lineHeight ?? UIFont.systemFont(ofSize: TypeScale.body).lineHeight
        let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let minHeight = ceil(lineHeight * CGFloat(parent.minLines) + verticalInsets)
        let maxHeight = ceil(lineHeight * CGFloat(parent.maxLines) + verticalInsets)
        let clamped = min(max(fittingSize.height, minHeight), maxHeight)
        let shouldScroll = fittingSize.height > maxHeight + 0.5

        if abs(parent.measuredHeight - clamped) > 0.5 {
          Task { @MainActor [weak self] in
            guard let self else { return }
            guard abs(self.parent.measuredHeight - clamped) > 0.5 else { return }
            self.parent.measuredHeight = clamped
          }
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
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let isEnabled: Bool
    let minLines: Int
    let maxLines: Int
    let onPasteImage: () -> Bool
    let canPasteImage: () -> Bool
    let onKeyCommand: (ComposerTextAreaKeyCommand) -> Bool

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
      textView.delegate = context.coordinator
      textView.isRichText = false
      textView.importsGraphics = false
      textView.drawsBackground = false
      textView.font = .systemFont(ofSize: TypeScale.body)
      textView.textColor = .labelColor
      textView.insertionPointColor = .labelColor
      textView.isContinuousSpellCheckingEnabled = true
      textView.isAutomaticQuoteSubstitutionEnabled = true
      textView.isAutomaticDashSubstitutionEnabled = true
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
      textView.onPasteImage = onPasteImage
      textView.canPasteImage = canPasteImage
      textView.onKeyCommand = onKeyCommand

      scrollView.documentView = textView
      context.coordinator.textView = textView
      context.coordinator.needsInitialMeasurement = true
      return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
      context.coordinator.parent = self
      guard let textView = context.coordinator.textView else { return }

      let didUpdateText = textView.string != text
      if didUpdateText {
        textView.string = text
      }

      if textView.isEditable != isEnabled {
        textView.isEditable = isEnabled
      }
      if !textView.isSelectable {
        textView.isSelectable = true
      }
      textView.onPasteImage = onPasteImage
      textView.canPasteImage = canPasteImage
      textView.onKeyCommand = onKeyCommand

      let widthChanged = context.coordinator.captureMeasuredWidth(max(textView.bounds.width, 1))
      if didUpdateText || widthChanged || context.coordinator.needsInitialMeasurement {
        context.coordinator.scheduleHeightMeasurement(for: textView)
      }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
      var parent: ComposerTextAreaMacOS
      weak var textView: ComposerNSTextView?
      private var heightMeasurementTask: Task<Void, Never>?
      private var lastMeasuredWidth: CGFloat = 0
      var needsInitialMeasurement = false

      init(parent: ComposerTextAreaMacOS) {
        self.parent = parent
      }

      deinit {
        heightMeasurementTask?.cancel()
      }

      func captureMeasuredWidth(_ width: CGFloat) -> Bool {
        guard width > 1 else { return false }
        if abs(lastMeasuredWidth - width) > 0.5 {
          lastMeasuredWidth = width
          return true
        }
        return false
      }

      func scheduleHeightMeasurement(for textView: NSTextView) {
        heightMeasurementTask?.cancel()
        heightMeasurementTask = Task { @MainActor [weak self, weak textView] in
          guard let self, let textView else { return }
          defer { self.heightMeasurementTask = nil }
          await Task.yield()
          guard !Task.isCancelled else { return }
          self.recalculateHeight(for: textView)
          self.needsInitialMeasurement = false
        }
      }

      func textDidBeginEditing(_ notification: Notification) {
      }

      func textDidEndEditing(_ notification: Notification) {
      }

      func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        let updated = textView.string
        if parent.text != updated {
          parent.text = updated
        }
        scheduleHeightMeasurement(for: textView)
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
    }
  }

  private final class ComposerNSTextView: NSTextView {
    var onPasteImage: (() -> Bool)?
    var canPasteImage: (() -> Bool)?
    var onKeyCommand: ((ComposerTextAreaKeyCommand) -> Bool)?

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
