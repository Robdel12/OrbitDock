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
          .padding(.top, 6)
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
      textView.textContainer.lineFragmentPadding = 0
      textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
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
        DispatchQueue.main.async { [weak self] in
          self?.parent.isFocused = true
        }
      }

      func textViewDidEndEditing(_ textView: UITextView) {
        guard parent.isFocused else { return }
        DispatchQueue.main.async { [weak self] in
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
          DispatchQueue.main.async { [weak self] in
            self?.parent.measuredHeight = clamped
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
      textView.textContainer?.widthTracksTextView = true
      textView.textContainer?.lineFragmentPadding = 0
      textView.textContainerInset = NSSize(width: 0, height: 6)
      textView.onPasteImage = onPasteImage
      textView.canPasteImage = canPasteImage
      textView.onKeyCommand = onKeyCommand

      scrollView.documentView = textView
      context.coordinator.textView = textView
      return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
      context.coordinator.parent = self
      guard let textView = context.coordinator.textView else { return }

      if textView.string != text {
        textView.string = text
      }

      textView.isEditable = isEnabled
      textView.isSelectable = isEnabled
      textView.onPasteImage = onPasteImage
      textView.canPasteImage = canPasteImage
      textView.onKeyCommand = onKeyCommand

      context.coordinator.recalculateHeight(for: textView)

      if isFocused {
        if nsView.window?.firstResponder !== textView {
          nsView.window?.makeFirstResponder(textView)
        }
      } else if nsView.window?.firstResponder === textView {
        nsView.window?.makeFirstResponder(nil)
      }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
      var parent: ComposerTextAreaMacOS
      weak var textView: ComposerNSTextView?

      init(parent: ComposerTextAreaMacOS) {
        self.parent = parent
      }

      func textDidBeginEditing(_ notification: Notification) {
        guard !parent.isFocused else { return }
        DispatchQueue.main.async { [weak self] in
          self?.parent.isFocused = true
        }
      }

      func textDidEndEditing(_ notification: Notification) {
        guard parent.isFocused else { return }
        DispatchQueue.main.async { [weak self] in
          self?.parent.isFocused = false
        }
      }

      func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        let updated = textView.string
        if parent.text != updated {
          parent.text = updated
        }
        recalculateHeight(for: textView)
      }

      func recalculateHeight(for textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        textContainer.containerSize = NSSize(
          width: max(textView.bounds.width, 1),
          height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)

        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let font = textView.font ?? NSFont.systemFont(ofSize: TypeScale.body)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let verticalInsets = textView.textContainerInset.height * 2
        let minHeight = ceil(lineHeight * CGFloat(parent.minLines) + verticalInsets)
        let maxHeight = ceil(lineHeight * CGFloat(parent.maxLines) + verticalInsets)
        let fitting = ceil(max(usedHeight + verticalInsets, minHeight))
        let clamped = min(fitting, maxHeight)
        let shouldScroll = fitting > maxHeight + 0.5

        if abs(parent.measuredHeight - clamped) > 0.5 {
          DispatchQueue.main.async { [weak self] in
            self?.parent.measuredHeight = clamped
          }
        }

        textView.enclosingScrollView?.hasVerticalScroller = shouldScroll
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
