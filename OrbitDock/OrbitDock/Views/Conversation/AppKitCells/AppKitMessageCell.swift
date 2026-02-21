//
//  AppKitMessageCell.swift
//  OrbitDock
//
//  macOS-specific NSTableCellView for legacy plain-text message rows
//  (verbose mode fallback). Includes inline code parsing via attributed strings.
//

#if os(macOS)

  import AppKit

  // MARK: - Message Row Model

  struct NativeMessageRowModel {
    let speaker: String
    let body: String
    let speakerColor: NSColor
    let textColor: NSColor
    let bubbleColor: NSColor
  }

  // MARK: - Message Cell

  final class NativeMessageTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeMessageTableCell")

    private let bubbleView = NSView()
    private let speakerField = NSTextField(labelWithString: "")
    private let bodyField = NSTextField(wrappingLabelWithString: "")

    private let speakerFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 13)
    private let outerVerticalPadding: CGFloat = 12
    private let outerHorizontalPadding: CGFloat = 24
    private let bubbleHorizontalPadding: CGFloat = 20
    private let bubbleVerticalPadding: CGFloat = 19
    private let speakerToBodySpacing: CGFloat = 5

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    private func setup() {
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor

      bubbleView.wantsLayer = true
      bubbleView.layer?.masksToBounds = true
      bubbleView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(bubbleView)

      speakerField.translatesAutoresizingMaskIntoConstraints = false
      speakerField.font = speakerFont
      speakerField.lineBreakMode = .byTruncatingTail
      speakerField.maximumNumberOfLines = 1
      speakerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      bubbleView.addSubview(speakerField)

      bodyField.translatesAutoresizingMaskIntoConstraints = false
      bodyField.font = bodyFont
      bodyField.lineBreakMode = .byCharWrapping
      bodyField.maximumNumberOfLines = 0
      bodyField.usesSingleLineMode = false
      bodyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      bodyField.cell?.wraps = true
      bodyField.cell?.isScrollable = false
      bodyField.cell?.lineBreakMode = .byCharWrapping
      bodyField.cell?.truncatesLastVisibleLine = false
      bubbleView.addSubview(bodyField)

      NSLayoutConstraint.activate([
        bubbleView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

        speakerField.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 9),
        speakerField.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
        speakerField.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),

        bodyField.topAnchor.constraint(equalTo: speakerField.bottomAnchor, constant: 5),
        bodyField.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
        bodyField.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),
        bodyField.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10),
      ])
    }

    func configure(model: NativeMessageRowModel) {
      speakerField.stringValue = model.speaker
      speakerField.textColor = model.speakerColor
      bodyField.attributedStringValue = buildAttributedBody(text: model.body, textColor: model.textColor)
      bubbleView.layer?.backgroundColor = model.bubbleColor.cgColor
      bubbleView.layer?.cornerRadius = 9
    }

    func requiredHeight(for width: CGFloat, model: NativeMessageRowModel) -> CGFloat {
      guard width > 1 else { return 1 }
      let textWidth = max(44, width - outerHorizontalPadding - bubbleHorizontalPadding)

      let speakerHeight = ceil(speakerFont.ascender - speakerFont.descender + speakerFont.leading)

      let attrBody = buildAttributedBody(text: model.body, textColor: model.textColor)
      let bodyRect = attrBody.boundingRect(
        with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      )
      let minBodyHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
      let bodyHeight = max(minBodyHeight, ceil(bodyRect.height))

      return max(1, ceil(
        outerVerticalPadding + bubbleVerticalPadding + speakerHeight + speakerToBodySpacing + bodyHeight
      ))
    }

    // MARK: - Inline Code Attributed String Builder

    private let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Parses inline code spans (`` `text` ``) from plain text and returns an
    /// attributed string with monospace font for code segments. Fast path skips
    /// parsing entirely when no backticks are present.
    private func buildAttributedBody(text: String, textColor: NSColor) -> NSAttributedString {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byCharWrapping

      let baseAttrs: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
      ]

      guard text.contains("`") else {
        return NSAttributedString(string: text, attributes: baseAttrs)
      }

      let codeAttrs: [NSAttributedString.Key: Any] = [
        .font: codeFont,
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
      ]

      let result = NSMutableAttributedString()
      var i = text.startIndex

      while i < text.endIndex {
        if text[i] == "`" {
          let afterTick = text.index(after: i)
          guard afterTick < text.endIndex else {
            result.append(NSAttributedString(string: "`", attributes: baseAttrs))
            break
          }
          if let closingTick = text[afterTick...].firstIndex(of: "`") {
            let codeContent = String(text[afterTick ..< closingTick])
            if codeContent.isEmpty {
              i = text.index(after: closingTick)
            } else {
              result.append(NSAttributedString(string: codeContent, attributes: codeAttrs))
              i = text.index(after: closingTick)
            }
          } else {
            // Unmatched backtick — render as literal
            result.append(NSAttributedString(string: "`", attributes: baseAttrs))
            i = afterTick
          }
        } else {
          let nextTick = text[i...].firstIndex(of: "`") ?? text.endIndex
          result.append(NSAttributedString(string: String(text[i ..< nextTick]), attributes: baseAttrs))
          i = nextTick
        }
      }

      return result
    }
  }

#endif
