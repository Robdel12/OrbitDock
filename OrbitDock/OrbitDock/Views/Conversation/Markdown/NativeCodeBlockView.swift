//
//  NativeCodeBlockView.swift
//  OrbitDock
//
//  Native replacement for CodeBlockView (SwiftUI).
//  Header with language dot + name + line count + copy button,
//  separator, line numbers column, syntax-highlighted code body,
//  expand/collapse for 15+ lines.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import SwiftUI

final class NativeCodeBlockView: PlatformView {
  // MARK: - Constants

  private static let headerHeight: CGFloat = 36
  private static let separatorHeight: CGFloat = 1
  private static let lineHeight: CGFloat = 21
  private static let verticalPadding: CGFloat = 10
  private static let horizontalPadding: CGFloat = 14
  private static let lineNumberTrailingPad: CGFloat = 14
  private static let lineNumberLeadingPad: CGFloat = 10
  private static let cornerRadius: CGFloat = 8
  private static let collapseThreshold = 15
  private static let collapsedLineCount = 8
  private static let expandButtonHeight: CGFloat = 34

  private static let bgColor = PlatformColor(Color.backgroundCode)
  private static let borderColor = PlatformColor(Color.surfaceBorder)
  private static let lineNumberColor = PlatformColor(Color.textTertiary)
  private static let lineNumberFont = PlatformFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  // MARK: - State

  private var normalizedLanguage: String?
  private var code: String = ""
  private var lines: [String] = []
  private var isExpanded = false
  private var codeScrollHeightConstraint: NSLayoutConstraint?
  private var expandButtonHeightConstraint: NSLayoutConstraint?

  // MARK: - Subviews

  #if os(macOS)
    private let headerContainer = NSView()
    private let languageDot = NSView()
    private let languageLabel = NSTextField(labelWithString: "")
    private let lineCountLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let separator = NSView()
    private let codeScrollView = NSScrollView()
    private let codeContainer = FlippedView()
    private let expandButton = NSButton(title: "", target: nil, action: nil)
  #else
    private let headerContainer = UIView()
    private let languageDot = UIView()
    private let languageLabel = UILabel()
    private let lineCountLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let separator = UIView()
    private let codeScrollView = UIScrollView()
    private let codeContainer = FlippedView()
    private let expandButton = UIButton(type: .system)
  #endif

  // MARK: - Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  // MARK: - Setup

  private func setup() {
    #if os(macOS)
      wantsLayer = true
      layer?.backgroundColor = Self.bgColor.cgColor
      layer?.cornerRadius = Self.cornerRadius
      layer?.masksToBounds = true
      layer?.borderWidth = 1
      layer?.borderColor = Self.borderColor.cgColor
    #else
      backgroundColor = Self.bgColor
      layer.cornerRadius = Self.cornerRadius
      layer.masksToBounds = true
      layer.borderWidth = 1
      layer.borderColor = Self.borderColor.cgColor
    #endif

    // Header
    #if os(macOS)
      headerContainer.wantsLayer = true
      headerContainer.translatesAutoresizingMaskIntoConstraints = false
      addSubview(headerContainer)

      languageDot.wantsLayer = true
      languageDot.layer?.cornerRadius = 4
      languageDot.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.addSubview(languageDot)

      languageLabel.font = PlatformFont.monospacedSystemFont(ofSize: 11, weight: .medium)
      languageLabel.textColor = NSColor.secondaryLabelColor
      languageLabel.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.addSubview(languageLabel)

      lineCountLabel.font = PlatformFont.systemFont(ofSize: 11, weight: .medium)
      lineCountLabel.textColor = NSColor.tertiaryLabelColor
      lineCountLabel.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.addSubview(lineCountLabel)

      copyButton.isBordered = false
      copyButton.font = PlatformFont.systemFont(ofSize: 11, weight: .medium)
      copyButton.contentTintColor = NSColor.secondaryLabelColor
      copyButton.target = self
      copyButton.action = #selector(handleCopy)
      copyButton.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.addSubview(copyButton)
    #else
      headerContainer.translatesAutoresizingMaskIntoConstraints = false
      addSubview(headerContainer)

      languageDot.layer.cornerRadius = 4
      languageDot.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.addSubview(languageDot)

      languageLabel.font = PlatformFont.monospacedSystemFont(ofSize: 11, weight: .medium)
      languageLabel.textColor = .secondaryLabel
      languageLabel.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.addSubview(languageLabel)

      lineCountLabel.font = PlatformFont.systemFont(ofSize: 11, weight: .medium)
      lineCountLabel.textColor = .tertiaryLabel
      lineCountLabel.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.addSubview(lineCountLabel)

      copyButton.setTitle("Copy", for: .normal)
      copyButton.titleLabel?.font = PlatformFont.systemFont(ofSize: 11, weight: .medium)
      copyButton.setTitleColor(.secondaryLabel, for: .normal)
      copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
      copyButton.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.addSubview(copyButton)
    #endif

    // Separator
    #if os(macOS)
      separator.wantsLayer = true
      separator.layer?.backgroundColor = PlatformColor.white.withAlphaComponent(0.06).cgColor
    #else
      separator.backgroundColor = PlatformColor.white.withAlphaComponent(0.06)
    #endif
    separator.translatesAutoresizingMaskIntoConstraints = false
    addSubview(separator)

    // Code scroll view
    #if os(macOS)
      codeScrollView.hasHorizontalScroller = true
      codeScrollView.hasVerticalScroller = false
      codeScrollView.horizontalScrollElasticity = .allowed
      codeScrollView.verticalScrollElasticity = .none
      codeScrollView.drawsBackground = false
      codeScrollView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(codeScrollView)
      codeContainer.translatesAutoresizingMaskIntoConstraints = false
      codeScrollView.documentView = codeContainer
    #else
      codeScrollView.showsHorizontalScrollIndicator = true
      codeScrollView.showsVerticalScrollIndicator = false
      codeScrollView.alwaysBounceHorizontal = true
      codeScrollView.alwaysBounceVertical = false
      codeScrollView.backgroundColor = .clear
      codeScrollView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(codeScrollView)
      codeContainer.translatesAutoresizingMaskIntoConstraints = false
      codeScrollView.addSubview(codeContainer)
    #endif

    // Expand button
    #if os(macOS)
      expandButton.isBordered = false
      expandButton.font = PlatformFont.systemFont(ofSize: 11, weight: .medium)
      expandButton.contentTintColor = NSColor.tertiaryLabelColor
      expandButton.target = self
      expandButton.action = #selector(handleExpandToggle)
      expandButton.translatesAutoresizingMaskIntoConstraints = false
      expandButton.isHidden = true
      addSubview(expandButton)
    #else
      expandButton.titleLabel?.font = PlatformFont.systemFont(ofSize: 11, weight: .medium)
      expandButton.setTitleColor(.tertiaryLabel, for: .normal)
      expandButton.addTarget(self, action: #selector(handleExpandToggle), for: .touchUpInside)
      expandButton.translatesAutoresizingMaskIntoConstraints = false
      expandButton.isHidden = true
      addSubview(expandButton)
    #endif

    let codeScrollHeightConstraint = codeScrollView.heightAnchor.constraint(equalToConstant: 0)
    let expandButtonHeightConstraint = expandButton.heightAnchor.constraint(equalToConstant: 0)
    self.codeScrollHeightConstraint = codeScrollHeightConstraint
    self.expandButtonHeightConstraint = expandButtonHeightConstraint

    NSLayoutConstraint.activate([
      headerContainer.topAnchor.constraint(equalTo: topAnchor),
      headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      headerContainer.heightAnchor.constraint(equalToConstant: Self.headerHeight),

      languageDot.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: Self.horizontalPadding),
      languageDot.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
      languageDot.widthAnchor.constraint(equalToConstant: 8),
      languageDot.heightAnchor.constraint(equalToConstant: 8),

      languageLabel.leadingAnchor.constraint(equalTo: languageDot.trailingAnchor, constant: 5),
      languageLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

      copyButton.trailingAnchor.constraint(
        equalTo: headerContainer.trailingAnchor,
        constant: -Self.horizontalPadding
      ),
      copyButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

      lineCountLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -10),
      lineCountLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

      separator.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      separator.heightAnchor.constraint(equalToConstant: Self.separatorHeight),

      codeScrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
      codeScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      codeScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

      expandButton.topAnchor.constraint(equalTo: codeScrollView.bottomAnchor),
      expandButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      expandButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      expandButtonHeightConstraint,
      expandButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      codeScrollHeightConstraint,
    ])
  }

  // MARK: - Configure

  func configure(language: String?, code: String) {
    normalizedLanguage = MarkdownLanguage.normalize(language)
    self.code = code
    lines = code.components(separatedBy: "\n")
    isExpanded = false

    // Header
    if let lang = normalizedLanguage, !lang.isEmpty {
      languageDot.isHidden = false
      languageLabel.isHidden = false
      #if os(macOS)
        languageDot.layer?.backgroundColor = Self.languageColor(lang).cgColor
        languageLabel.stringValue = lang
      #else
        languageDot.backgroundColor = Self.languageColor(lang)
        languageLabel.text = lang
      #endif
    } else {
      languageDot.isHidden = true
      languageLabel.isHidden = true
    }

    #if os(macOS)
      lineCountLabel.stringValue = lines.count == 1 ? "1 line" : "\(lines.count) lines"
      copyButton.title = "Copy"
    #else
      lineCountLabel.text = lines.count == 1 ? "1 line" : "\(lines.count) lines"
      copyButton.setTitle("Copy", for: .normal)
    #endif

    let shouldCollapse = lines.count > Self.collapseThreshold
    expandButton.isHidden = !shouldCollapse
    expandButtonHeightConstraint?.constant = shouldCollapse ? Self.expandButtonHeight : 0
    updateExpandButtonTitle()
    rebuildCodeContent()
  }

  // MARK: - Code Content

  private func rebuildCodeContent() {
    codeContainer.subviews.forEach { $0.removeFromSuperview() }

    let shouldCollapse = lines.count > Self.collapseThreshold
    let displayLines = shouldCollapse && !isExpanded
      ? Array(lines.prefix(Self.collapsedLineCount))
      : lines

    let maxLineNumWidth = CGFloat("\(lines.count)".count) * 8 + 10

    // Build line number + code rows
    var yOffset: CGFloat = Self.verticalPadding
    var maxCodeWidth: CGFloat = 0

    for (index, line) in displayLines.enumerated() {
      // Line number
      #if os(macOS)
        let lineNum = NSTextField(labelWithString: "\(index + 1)")
        lineNum.font = Self.lineNumberFont
        lineNum.textColor = Self.lineNumberColor
        lineNum.alignment = .right
      #else
        let lineNum = UILabel()
        lineNum.text = "\(index + 1)"
        lineNum.font = Self.lineNumberFont
        lineNum.textColor = Self.lineNumberColor
        lineNum.textAlignment = .right
      #endif
      lineNum.frame = CGRect(
        x: Self.lineNumberLeadingPad,
        y: yOffset,
        width: maxLineNumWidth,
        height: Self.lineHeight
      )
      codeContainer.addSubview(lineNum)

      // Code line
      #if os(macOS)
        let codeLine = NSTextField(labelWithString: "")
        codeLine.attributedStringValue = SyntaxHighlighter.highlightNativeLine(line, language: normalizedLanguage)
        codeLine.lineBreakMode = .byClipping
        codeLine.maximumNumberOfLines = 1
        codeLine.isSelectable = true
        let lineSize = codeLine.attributedStringValue.size()
      #else
        let codeLine = UILabel()
        codeLine.attributedText = SyntaxHighlighter.highlightNativeLine(line, language: normalizedLanguage)
        codeLine.lineBreakMode = .byClipping
        codeLine.numberOfLines = 1
        let lineSize = (codeLine.attributedText ?? NSAttributedString()).size()
      #endif

      let codeX = Self.lineNumberLeadingPad + maxLineNumWidth + Self.lineNumberTrailingPad
      let lineWidth = ceil(lineSize.width) + 20
      maxCodeWidth = max(maxCodeWidth, lineWidth)

      codeLine.frame = CGRect(
        x: codeX,
        y: yOffset,
        width: max(lineWidth, 200),
        height: Self.lineHeight
      )
      codeContainer.addSubview(codeLine)

      yOffset += Self.lineHeight
    }

    yOffset += Self.verticalPadding

    let totalWidth = Self.lineNumberLeadingPad + maxLineNumWidth + Self.lineNumberTrailingPad + maxCodeWidth + Self
      .horizontalPadding
    codeContainer.frame = CGRect(x: 0, y: 0, width: max(totalWidth, bounds.width), height: yOffset)

    #if os(iOS)
      codeScrollView.contentSize = codeContainer.frame.size
    #endif

    // Keep one height constraint instance to avoid accumulation during reuse/reconfigure.
    codeScrollHeightConstraint?.constant = yOffset

    // Line number background
    let lineNumBg = PlatformView(frame: CGRect(
      x: 0, y: 0,
      width: Self.lineNumberLeadingPad + maxLineNumWidth + Self.lineNumberTrailingPad,
      height: yOffset
    ))
    #if os(macOS)
      lineNumBg.wantsLayer = true
      lineNumBg.layer?.backgroundColor = PlatformColor(Color.backgroundTertiary).withAlphaComponent(0.4).cgColor
      codeContainer.addSubview(lineNumBg, positioned: .below, relativeTo: nil)
    #else
      lineNumBg.backgroundColor = PlatformColor(Color.backgroundTertiary).withAlphaComponent(0.4)
      codeContainer.insertSubview(lineNumBg, at: 0)
    #endif
  }

  // MARK: - Height Calculation

  static func requiredHeight(lineCount: Int, isExpanded: Bool) -> CGFloat {
    let shouldCollapse = lineCount > collapseThreshold
    let displayCount = shouldCollapse && !isExpanded ? collapsedLineCount : lineCount
    let codeHeight = CGFloat(displayCount) * lineHeight + verticalPadding * 2
    let expandHeight: CGFloat = shouldCollapse ? expandButtonHeight : 0
    return headerHeight + separatorHeight + codeHeight + expandHeight
  }

  // MARK: - Actions

  @objc private func handleCopy() {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(code, forType: .string)
      copyButton.title = "Copied"
    #else
      UIPasteboard.general.string = code
      copyButton.setTitle("Copied", for: .normal)
    #endif
  }

  @objc private func handleExpandToggle() {
    isExpanded.toggle()
    updateExpandButtonTitle()
    rebuildCodeContent()
    invalidateIntrinsicContentSize()
    #if os(macOS)
      superview?.needsLayout = true
    #else
      superview?.setNeedsLayout()
    #endif
  }

  private func updateExpandButtonTitle() {
    if isExpanded {
      #if os(macOS)
        expandButton.title = "Show less"
      #else
        expandButton.setTitle("Show less", for: .normal)
      #endif
    } else {
      let remaining = lines.count - Self.collapsedLineCount
      #if os(macOS)
        expandButton.title = "Show \(remaining) more lines"
      #else
        expandButton.setTitle("Show \(remaining) more lines", for: .normal)
      #endif
    }
  }

  // MARK: - Language Color

  private static func languageColor(_ lang: String) -> PlatformColor {
    PlatformColor(MarkdownLanguage.badgeColor(lang))
  }
}

// MARK: - Flipped View (top-left origin)

private final class FlippedView: PlatformView {
  #if os(macOS)
    override var isFlipped: Bool {
      true
    }
  #endif
}
