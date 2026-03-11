//
//  ExpandedToolCellView.swift
//  OrbitDock
//
//  Native cell for expanded tool cards.
//  Replaces SwiftUI HostingTableCellView for ALL expanded tool rows.
//  Deterministic height — no hosting view, no correction cycle.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import SwiftUI

// MARK: - macOS Cell View

#if os(macOS)

  private final class HorizontalPanPassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
      let hasHorizontalOverflow = (documentView?.bounds.width ?? 0) > contentView.bounds.width + 1
      let horizontalDelta = abs(event.scrollingDeltaX)
      let verticalDelta = abs(event.scrollingDeltaY)
      let shouldHandleHorizontally = hasHorizontalOverflow && horizontalDelta > verticalDelta

      if shouldHandleHorizontally {
        super.scrollWheel(with: event)
      } else if let nextResponder {
        nextResponder.scrollWheel(with: event)
      } else {
        super.scrollWheel(with: event)
      }
    }
  }

  final class NativeExpandedToolCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeExpandedToolCell")

    private static let logger = TimelineFileLogger.shared

    // ── Layout constants (delegate to shared ExpandedToolLayout) ──

    private static let laneHorizontalInset = ExpandedToolLayout.laneHorizontalInset
    private static let accentBarWidth = ExpandedToolLayout.accentBarWidth
    private static let headerHPad = ExpandedToolLayout.headerHPad
    private static let headerVPad = ExpandedToolLayout.headerVPad
    private static let iconSize = ExpandedToolLayout.iconSize
    private static let cornerRadius = ExpandedToolLayout.cornerRadius
    private static let contentLineHeight = ExpandedToolLayout.contentLineHeight
    private static let diffLineHeight = ExpandedToolLayout.diffLineHeight
    private static let sectionHeaderHeight = ExpandedToolLayout.sectionHeaderHeight
    private static let sectionPadding = ExpandedToolLayout.sectionPadding
    private static let contentTopPad = ExpandedToolLayout.contentTopPad
    private static let bottomPadding = ExpandedToolLayout.bottomPadding

    // No line count limits — show full content for all tool types

    // Card colors — opaque dark surface with subtle depth
    private static let bgColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.85)
    private static let contentBgColor = NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)
    private static let headerDividerColor = NSColor.white.withAlphaComponent(0.06)

    private static let addedBgColor = NSColor(calibratedRed: 0.15, green: 0.32, blue: 0.18, alpha: 0.6)
    private static let removedBgColor = NSColor(calibratedRed: 0.35, green: 0.14, blue: 0.14, alpha: 0.6)
    private static let addedAccentColor = NSColor(calibratedRed: 0.4, green: 0.95, blue: 0.5, alpha: 1)
    private static let removedAccentColor = NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1)

    // Text colors — themed hierarchy (matches Color.textPrimary/Secondary/Tertiary/Quaternary)
    private static let textPrimary = NSColor.white.withAlphaComponent(0.92)
    private static let textSecondary = NSColor.white.withAlphaComponent(0.65)
    private static let textTertiary = NSColor.white.withAlphaComponent(0.50)
    private static let textQuaternary = NSColor.white.withAlphaComponent(0.38)

    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let codeFontStrong = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    private static let headerFont = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
    private static let subtitleFont = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
    private static let lineNumFont = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
    private static let sectionLabelFont = NSFont.systemFont(ofSize: TypeScale.mini, weight: .bold)
    private static let statsFont = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)

    // ── Subviews ──

    private let cardBackground = NSView()
    private let accentBar = NSView()
    private let headerDivider = NSView()
    private let contentBg = NSView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let statsField = NSTextField(labelWithString: "")
    private let durationField = NSTextField(labelWithString: "")
    private let collapseChevron = NSImageView()
    private let cancelButton = NSButton(title: "Stop", target: nil, action: nil)
    private let workerButton = NSButton(title: "", target: nil, action: nil)
    private let contentContainer = FlippedContentView()
    private let progressIndicator = NSProgressIndicator()

    // ── State ──

    private var model: NativeExpandedToolModel?
    var onCollapse: ((String) -> Void)?
    var onCancel: ((String) -> Void)?
    var onFocusWorker: ((String) -> Void)?

    // ── Init ──

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    // ── Setup ──

    private func setup() {
      wantsLayer = true

      // Card background
      cardBackground.wantsLayer = true
      cardBackground.layer?.backgroundColor = Self.bgColor.cgColor
      cardBackground.layer?.cornerRadius = Self.cornerRadius
      cardBackground.layer?.masksToBounds = true
      cardBackground.layer?.borderWidth = 1
      addSubview(cardBackground)

      // Accent bar — full height of card
      accentBar.wantsLayer = true
      cardBackground.addSubview(accentBar)

      // Header divider — thin line separating header from content
      headerDivider.wantsLayer = true
      headerDivider.layer?.backgroundColor = Self.headerDividerColor.cgColor
      cardBackground.addSubview(headerDivider)

      // Content background — darker inset behind output
      contentBg.wantsLayer = true
      contentBg.layer?.backgroundColor = Self.contentBgColor.cgColor
      cardBackground.addSubview(contentBg)

      // Icon
      iconView.imageScaling = .scaleProportionallyUpOrDown
      iconView.contentTintColor = Self.textSecondary
      cardBackground.addSubview(iconView)

      // Title
      titleField.font = Self.headerFont
      titleField.textColor = Self.textPrimary
      titleField.lineBreakMode = .byTruncatingTail
      titleField.maximumNumberOfLines = 1
      cardBackground.addSubview(titleField)

      // Subtitle
      subtitleField.font = Self.subtitleFont
      subtitleField.textColor = Self.textTertiary
      subtitleField.lineBreakMode = .byTruncatingTail
      subtitleField.maximumNumberOfLines = 1
      cardBackground.addSubview(subtitleField)

      // Stats
      statsField.font = Self.statsFont
      statsField.textColor = Self.textTertiary
      statsField.alignment = .right
      cardBackground.addSubview(statsField)

      // Duration
      durationField.font = Self.statsFont
      durationField.textColor = Self.textQuaternary
      durationField.alignment = .right
      cardBackground.addSubview(durationField)

      // Collapse chevron
      let chevronConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
      collapseChevron.image = NSImage(
        systemSymbolName: "chevron.down",
        accessibilityDescription: "Collapse"
      )?.withSymbolConfiguration(chevronConfig)
      collapseChevron.contentTintColor = Self.textQuaternary
      cardBackground.addSubview(collapseChevron)

      // Progress indicator
      progressIndicator.style = .spinning
      progressIndicator.controlSize = .small
      progressIndicator.isHidden = true
      cardBackground.addSubview(progressIndicator)

      // Cancel button (shell-only)
      cancelButton.bezelStyle = .rounded
      cancelButton.font = NSFont.systemFont(ofSize: TypeScale.meta, weight: .semibold)
      cancelButton.contentTintColor = NSColor(Color.statusError)
      cancelButton.target = self
      cancelButton.action = #selector(handleCancelTap(_:))
      cancelButton.isHidden = true
      cardBackground.addSubview(cancelButton)

      let workerConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      workerButton.image = NSImage(
        systemSymbolName: "sidebar.right",
        accessibilityDescription: "Show worker"
      )?.withSymbolConfiguration(workerConfig)
      workerButton.contentTintColor = NSColor(Color.accent)
      workerButton.isBordered = false
      workerButton.bezelStyle = .regularSquare
      workerButton.target = self
      workerButton.action = #selector(handleWorkerTap(_:))
      workerButton.isHidden = true
      cardBackground.addSubview(workerButton)

      // Content container — on top of content background
      contentContainer.wantsLayer = true
      cardBackground.addSubview(contentContainer)

      // Header tap gesture
      let click = NSClickGestureRecognizer(target: self, action: #selector(handleHeaderTap(_:)))
      cardBackground.addGestureRecognizer(click)
    }

    @objc private func handleHeaderTap(_ gesture: NSClickGestureRecognizer) {
      let location = gesture.location(in: cardBackground)
      if !cancelButton.isHidden, cancelButton.frame.contains(location) {
        return
      }
      if !workerButton.isHidden, workerButton.frame.contains(location) {
        return
      }
      let headerHeight = Self.headerHeight(for: model)
      if location.y <= headerHeight, let messageID = model?.messageID {
        onCollapse?(messageID)
      }
    }

    @objc private func handleCancelTap(_ sender: NSButton) {
      guard let messageID = model?.messageID else { return }
      onCancel?(messageID)
    }

    @objc private func handleWorkerTap(_ sender: NSButton) {
      guard let workerID = model?.linkedWorkerID else { return }
      onFocusWorker?(workerID)
    }

    // ── Configure ──

    func configure(model: NativeExpandedToolModel, width: CGFloat) {
      self.model = model

      let layoutPlan = ExpandedToolCellPlanning.cardLayoutPlan(for: model, width: width)
      let cardWidth = layoutPlan.cardWidth
      let headerH = layoutPlan.headerHeight
      let contentH = layoutPlan.contentHeight
      let totalH = layoutPlan.totalHeight

      // Card background — inset from lane edges
      cardBackground.frame = layoutPlan.cardFrame
      cardBackground.layer?.borderColor = model.toolColor.withAlphaComponent(OpacityTier.light).cgColor

      // Accent bar — full height of card
      let accentColor = model.hasError ? NSColor(Color.statusError) : model.toolColor
      accentBar.layer?.backgroundColor = accentColor.cgColor
      accentBar.frame = layoutPlan.accentFrame

      // Header divider line
      if let headerDividerFrame = layoutPlan.headerDividerFrame {
        headerDivider.frame = headerDividerFrame
        headerDivider.isHidden = false
      } else {
        headerDivider.isHidden = true
      }

      // Content background — darker region behind output (stops before card corner radius)
      if let contentBackgroundFrame = layoutPlan.contentBackgroundFrame {
        contentBg.isHidden = false
        contentBg.frame = contentBackgroundFrame
      } else {
        contentBg.isHidden = true
      }

      // Icon
      let iconConfig = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .medium)
      iconView.image = NSImage(
        systemSymbolName: model.iconName,
        accessibilityDescription: nil
      )?.withSymbolConfiguration(iconConfig)
      iconView.contentTintColor = model.hasError ? NSColor(Color.statusError) : model.toolColor
      iconView.frame = layoutPlan.iconFrame

      // Title + subtitle
      configureHeader(model: model, layoutPlan: layoutPlan)

      // Progress indicator
      if let progressFrame = layoutPlan.progressFrame {
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        progressIndicator.frame = progressFrame
      } else {
        progressIndicator.isHidden = true
        progressIndicator.stopAnimation(nil)
      }

      if let cancelFrame = layoutPlan.cancelFrame {
        cancelButton.isHidden = false
        cancelButton.frame = cancelFrame
      } else {
        cancelButton.isHidden = true
      }

      if let workerID = model.linkedWorkerID {
        workerButton.isHidden = false
        workerButton.toolTip = "Show \(workerID) in Workers"
        workerButton.frame = NSRect(
          x: cardWidth - Self.headerHPad - (model.canCancel ? 86 : 48),
          y: Self.headerVPad - 1,
          width: 20,
          height: 20
        )
      } else {
        workerButton.isHidden = true
      }

      // Collapse chevron
      if let chevronFrame = layoutPlan.chevronFrame {
        collapseChevron.isHidden = false
        collapseChevron.frame = chevronFrame
      } else {
        collapseChevron.isHidden = true
      }

      // Duration
      if let durationFrame = layoutPlan.durationFrame, let dur = model.duration {
        durationField.isHidden = false
        durationField.stringValue = dur
        durationField.frame = durationFrame
      } else {
        durationField.isHidden = true
      }

      // Content
      contentContainer.subviews.forEach { $0.removeFromSuperview() }
      contentContainer.frame = layoutPlan.contentContainerFrame
      buildContent(model: model, width: cardWidth)

      // ── Diagnostic: detect content overflow ──
      let maxSubviewBottom = contentContainer.subviews
        .map(\.frame.maxY)
        .max() ?? 0
      let toolType = ExpandedToolLayout.toolTypeName(model.content)
      if maxSubviewBottom > contentH + 1 {
        // Content overflows calculated height — this causes clipping
        Self.logger.info(
          "⚠️ OVERFLOW tool-cell[\(model.messageID)] \(toolType) "
            + "contentH=\(f(contentH)) maxSubview=\(f(maxSubviewBottom)) "
            + "overflow=\(f(maxSubviewBottom - contentH)) "
            + "headerH=\(f(headerH)) totalH=\(f(totalH)) w=\(f(width))"
        )
      } else {
        Self.logger.debug(
          "tool-cell[\(model.messageID)] \(toolType) "
            + "headerH=\(f(headerH)) contentH=\(f(contentH)) totalH=\(f(totalH)) "
            + "maxSubview=\(f(maxSubviewBottom)) w=\(f(width))"
        )
      }
    }

    // ── Header Configuration ──

    private func configureHeader(model: NativeExpandedToolModel, layoutPlan: ExpandedToolCardLayoutPlan) {
      let plan = ExpandedToolHeaderPlanning.plan(for: model)
      applyHeaderPlan(plan, model: model)

      titleField.frame = layoutPlan.header.titleFrame
      if let subtitleFrame = layoutPlan.header.subtitleFrame {
        subtitleField.frame = subtitleFrame
      }
      if let statsFrame = layoutPlan.header.statsFrame {
        statsField.frame = statsFrame
      }
    }

    private func applyHeaderPlan(_ plan: ExpandedToolHeaderPlan, model: NativeExpandedToolModel) {
      switch plan.title {
        case let .bash(command):
          let bashColor = model.hasError ? NSColor(Color.statusError) : model.toolColor
          let bashAttr = NSMutableAttributedString()
          bashAttr.append(NSAttributedString(
            string: "$ ",
            attributes: [
              .font: NSFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .bold),
              .foregroundColor: bashColor,
            ]
          ))
          bashAttr.append(NSAttributedString(
            string: command,
            attributes: [
              .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
              .foregroundColor: Self.textPrimary,
            ]
          ))
          titleField.attributedStringValue = bashAttr
          titleField.lineBreakMode = .byCharWrapping
          titleField.maximumNumberOfLines = 0

        case let .plain(text, style):
          titleField.attributedStringValue = NSAttributedString(string: text)
          titleField.stringValue = text
          titleField.font = titleFont(for: style)
          titleField.textColor = titleColor(for: style, model: model)
          titleField.lineBreakMode = .byTruncatingTail
          titleField.maximumNumberOfLines = 1
      }

      subtitleField.stringValue = plan.subtitle ?? ""
      subtitleField.isHidden = plan.subtitle == nil

      if let statsText = plan.statsText {
        statsField.isHidden = false
        statsField.stringValue = statsText
        statsField.textColor = statsColor(for: plan.statsTone)
      } else {
        statsField.isHidden = true
      }
    }

    private func titleFont(for style: ExpandedToolHeaderTitleStyle) -> NSFont {
      switch style {
        case .primary, .toolTint:
          Self.headerFont
        case .fileName:
          NSFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .semibold)
      }
    }

    private func titleColor(for style: ExpandedToolHeaderTitleStyle, model: NativeExpandedToolModel) -> NSColor {
      switch style {
        case .primary, .fileName:
          Self.textPrimary
        case .toolTint:
          model.toolColor
      }
    }

    private func statsColor(for tone: ExpandedToolHeaderStatsTone) -> NSColor {
      switch tone {
        case .secondary:
          Self.textTertiary
        case let .diff(additions, _):
          additions > 0 ? Self.addedAccentColor : Self.removedAccentColor
      }
    }

    // ── Content Builders ──

    private func buildContent(model: NativeExpandedToolModel, width: CGFloat) {
      let plan = ExpandedToolContentPlanning.contentPlan(for: model)
      buildContent(plan: plan, width: width)
    }

    private func buildContent(plan: ExpandedToolContentPlan, width: CGFloat) {
      var payloadSectionY = Self.contentTopPad
      for section in plan.sections {
        switch section {
          case let .textOutput(lines):
            buildTextOutputContent(lines: lines, width: width)
          case let .edit(plan):
            buildEditContent(plan: plan, width: width)
          case let .read(plan):
            buildReadContent(plan: plan, width: width)
          case let .glob(groups):
            buildGlobContent(groups: groups, width: width)
          case let .grep(groups):
            buildGrepContent(groups: groups, width: width)
          case let .todo(plan):
            buildTodoContent(plan: plan, width: width)
          case let .payload(sectionPlan):
            payloadSectionY = buildPayloadSection(plan: sectionPlan, width: width, startY: payloadSectionY)
        }
      }
    }

    // ── Text Output (bash, mcp, webfetch, websearch, task) ──

    private func buildTextOutputContent(lines: [String], width: CGFloat) {
      guard !lines.isEmpty else { return }

      let textWidth = width - Self.headerHPad * 2
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for line in lines {
        let label = NSTextField(labelWithString: line)
        label.font = Self.codeFont
        label.textColor = Self.textSecondary
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        let labelH = ExpandedToolLayout.measuredTextHeight(line, font: Self.codeFont, maxWidth: textWidth)
        label.frame = NSRect(x: Self.headerHPad, y: y, width: textWidth, height: labelH)
        contentContainer.addSubview(label)
        y += labelH
      }
    }

    // ── Edit (diff lines) ──

    private func buildEditContent(plan: ExpandedToolEditSectionPlan, width: CGFloat) {
      let lines = plan.lines
      let isWriteNew = plan.isWriteNew
      var y: CGFloat = 0

      // Write new file header
      if isWriteNew {
        let header = NSTextField(labelWithString: "NEW FILE (\(lines.count) lines)")
        header.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .bold)
        header.textColor = Self.addedAccentColor
        header.frame = NSRect(x: Self.headerHPad, y: y + 6, width: width - Self.headerHPad * 2, height: 16)
        contentContainer.addSubview(header)

        let headerBg = NSView(frame: NSRect(x: 0, y: y, width: width, height: 28))
        headerBg.wantsLayer = true
        headerBg.layer?.backgroundColor = Self.addedBgColor.withAlphaComponent(0.3).cgColor
        contentContainer.addSubview(headerBg, positioned: .below, relativeTo: nil)
        y += 28
      }

      let gutterMetrics = ExpandedToolLayout.diffGutterMetrics(for: lines)
      let codeX = gutterMetrics.codeX
      let codeAvailW = width - codeX - ExpandedToolLayout.diffContentTrailingPad
      let diffFont = ExpandedToolLayout.diffContentFont

      // Measure widest line for scroll content
      var maxTextWidth: CGFloat = 0
      for line in lines {
        let text = line.content.isEmpty ? " " : line.content
        let w = ceil((text as NSString).size(withAttributes: [.font: diffFont as Any]).width)
        maxTextWidth = max(maxTextWidth, w)
      }
      let scrollContentW = max(codeAvailW, maxTextWidth + 8)

      // Horizontal scroll view for code content
      let totalDiffH = CGFloat(lines.count) * Self.diffLineHeight
      let scrollView = HorizontalPanPassthroughScrollView()
      scrollView.hasHorizontalScroller = true
      scrollView.hasVerticalScroller = false
      scrollView.autohidesScrollers = true
      scrollView.scrollerStyle = .overlay
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      scrollView.frame = NSRect(x: codeX, y: y, width: codeAvailW, height: totalDiffH)

      let docView = FlippedContentView()
      docView.frame = NSRect(x: 0, y: 0, width: scrollContentW, height: totalDiffH)
      scrollView.documentView = docView

      var rowY: CGFloat = 0
      for line in lines {
        let bgColor: NSColor
        let prefixColor: NSColor
        let contentColor: NSColor
        switch line.type {
          case .added:
            bgColor = Self.addedBgColor
            prefixColor = Self.addedAccentColor
            contentColor = Self.textPrimary
          case .removed:
            bgColor = Self.removedBgColor
            prefixColor = Self.removedAccentColor
            contentColor = Self.textPrimary
          case .context:
            bgColor = .clear
            prefixColor = Self.textQuaternary
            contentColor = Self.textTertiary
        }

        // Row background (full card width, in contentContainer)
        let rowBg = NSView(frame: NSRect(x: 0, y: y + rowY, width: width, height: Self.diffLineHeight))
        rowBg.wantsLayer = true
        rowBg.layer?.backgroundColor = bgColor.cgColor
        contentContainer.addSubview(rowBg)

        // Line numbers (in contentContainer — stay fixed)
        if let oldLineNumberX = gutterMetrics.oldLineNumberX, let num = line.oldLineNum {
          let numLabel = NSTextField(labelWithString: "\(num)")
          numLabel.font = Self.lineNumFont
          numLabel.textColor = Self.textQuaternary
          numLabel.alignment = .right
          numLabel.frame = NSRect(
            x: oldLineNumberX,
            y: y + rowY + 2,
            width: gutterMetrics.oldLineNumberWidth,
            height: 18
          )
          contentContainer.addSubview(numLabel)
        }
        if let newLineNumberX = gutterMetrics.newLineNumberX, let num = line.newLineNum {
          let numLabel = NSTextField(labelWithString: "\(num)")
          numLabel.font = Self.lineNumFont
          numLabel.textColor = Self.textQuaternary
          numLabel.alignment = .right
          numLabel.frame = NSRect(
            x: newLineNumberX,
            y: y + rowY + 2,
            width: gutterMetrics.newLineNumberWidth,
            height: 18
          )
          contentContainer.addSubview(numLabel)
        }

        // Prefix (in contentContainer — stays fixed)
        let prefixLabel = NSTextField(labelWithString: line.prefix)
        prefixLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .bold)
        prefixLabel.textColor = prefixColor
        prefixLabel.frame = NSRect(
          x: gutterMetrics.prefixX,
          y: y + rowY + 1,
          width: ExpandedToolLayout.diffPrefixWidth,
          height: 20
        )
        contentContainer.addSubview(prefixLabel)

        // Code content (in scroll view — scrolls horizontally)
        let text = line.content.isEmpty ? " " : line.content
        let contentLabel = NSTextField(labelWithString: text)
        contentLabel.font = diffFont
        contentLabel.textColor = contentColor
        contentLabel.lineBreakMode = .byClipping
        contentLabel.maximumNumberOfLines = 1
        contentLabel.isSelectable = true
        contentLabel.frame = NSRect(x: 0, y: rowY + 2, width: scrollContentW, height: 18)
        docView.addSubview(contentLabel)

        rowY += Self.diffLineHeight
      }

      contentContainer.addSubview(scrollView)
    }

    // ── Read (line-numbered code) ──

    private func buildReadContent(plan: ExpandedToolReadSectionPlan, width: CGFloat) {
      let lines = plan.lines
      let language = plan.language
      let gutterMetrics = ExpandedToolLayout.readGutterMetrics(lineCount: lines.count)
      let codeX = gutterMetrics.codeX
      let codeAvailW = width - codeX - ExpandedToolLayout.diffContentTrailingPad
      let lang = language.isEmpty ? nil : language
      let y: CGFloat = Self.sectionPadding + Self.contentTopPad

      // Measure widest line for scroll content
      var maxTextWidth: CGFloat = 0
      for line in lines {
        let text = line.isEmpty ? " " : line
        let w = ceil((text as NSString).size(withAttributes: [.font: Self.codeFont as Any]).width)
        maxTextWidth = max(maxTextWidth, w)
      }
      let scrollContentW = max(codeAvailW, maxTextWidth + 8)

      // Horizontal scroll view for code content
      let totalH = CGFloat(lines.count) * Self.contentLineHeight
      let scrollView = HorizontalPanPassthroughScrollView()
      scrollView.hasHorizontalScroller = true
      scrollView.hasVerticalScroller = false
      scrollView.autohidesScrollers = true
      scrollView.scrollerStyle = .overlay
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      scrollView.frame = NSRect(x: codeX, y: y, width: codeAvailW, height: totalH)

      let docView = FlippedContentView()
      docView.frame = NSRect(x: 0, y: 0, width: scrollContentW, height: totalH)
      scrollView.documentView = docView

      var rowY: CGFloat = 0
      for (index, line) in lines.enumerated() {
        let text = line.isEmpty ? " " : line

        // Line number (in contentContainer — stays fixed)
        let numLabel = NSTextField(labelWithString: "\(index + 1)")
        numLabel.font = Self.lineNumFont
        numLabel.textColor = Self.textQuaternary
        numLabel.alignment = .right
        numLabel.frame = NSRect(
          x: gutterMetrics.lineNumberX,
          y: y + rowY,
          width: gutterMetrics.lineNumberWidth,
          height: Self.contentLineHeight
        )
        contentContainer.addSubview(numLabel)

        // Code line (in scroll view — scrolls horizontally)
        let codeLine = NSTextField(labelWithString: "")
        codeLine.attributedStringValue = SyntaxHighlighter.highlightNativeLine(text, language: lang)
        codeLine.lineBreakMode = .byClipping
        codeLine.maximumNumberOfLines = 1
        codeLine.isSelectable = true
        codeLine.frame = NSRect(x: 0, y: rowY, width: scrollContentW, height: Self.contentLineHeight)
        docView.addSubview(codeLine)

        rowY += Self.contentLineHeight
      }

      contentContainer.addSubview(scrollView)
    }

    // ── Glob (directory tree) ──

    private func buildGlobContent(groups: [ExpandedToolGlobDirectoryPlan], width: CGFloat) {
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for group in groups {
        // Directory header
        let dirIcon = NSImageView()
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        dirIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
          .withSymbolConfiguration(iconConfig)
        dirIcon.contentTintColor = NSColor(Color.toolWrite)
        dirIcon.frame = NSRect(x: Self.headerHPad, y: y + 2, width: 14, height: 14)
        contentContainer.addSubview(dirIcon)

        let dirLabel = NSTextField(labelWithString: group.displayName)
        dirLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
        dirLabel.textColor = Self.textSecondary
        dirLabel.lineBreakMode = .byCharWrapping
        dirLabel.maximumNumberOfLines = 0
        let dirW = width - Self.headerHPad * 2 - 18
        let dirH = ExpandedToolLayout.measuredTextHeight(group.displayName, font: dirLabel.font!, maxWidth: dirW)
        dirLabel.frame = NSRect(x: Self.headerHPad + 18, y: y, width: dirW, height: dirH)
        contentContainer.addSubview(dirLabel)
        y += dirH + 2

        // Files
        for file in group.files {
          let fileLabel = NSTextField(labelWithString: file)
          fileLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
          fileLabel.textColor = Self.textTertiary
          fileLabel.lineBreakMode = .byCharWrapping
          fileLabel.maximumNumberOfLines = 0
          let fileX = Self.headerHPad + 28
          let fileW = width - Self.headerHPad * 2 - 28
          let fileH = ExpandedToolLayout.measuredTextHeight(file, font: fileLabel.font!, maxWidth: fileW)
          fileLabel.frame = NSRect(
            x: fileX, y: y, width: fileW, height: fileH
          )
          contentContainer.addSubview(fileLabel)
          y += fileH
        }

        y += 6
      }
    }

    // ── Grep (file-grouped results) ──

    private func buildGrepContent(groups: [ExpandedToolGrepMatchPlan], width: CGFloat) {
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for group in groups {
        // File header
        let fileLabel = NSTextField(labelWithString: group.displayName)
        fileLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
        fileLabel.textColor = Self.textPrimary
        fileLabel.lineBreakMode = .byCharWrapping
        fileLabel.maximumNumberOfLines = 0
        let fileLabelW = width - Self.headerHPad * 2
        let fileLabelH = ExpandedToolLayout.measuredTextHeight(group.displayName, font: fileLabel.font!, maxWidth: fileLabelW)
        fileLabel.frame = NSRect(x: Self.headerHPad, y: y, width: fileLabelW, height: fileLabelH)
        contentContainer.addSubview(fileLabel)
        y += fileLabelH + 2

        // Match lines
        for match in group.matches {
          let matchLabel = NSTextField(labelWithString: match)
          matchLabel.font = Self.codeFont
          matchLabel.textColor = Self.textTertiary
          matchLabel.lineBreakMode = .byCharWrapping
          matchLabel.maximumNumberOfLines = 0
          let matchX = Self.headerHPad + 16
          let matchW = width - Self.headerHPad * 2 - 16
          let matchH = ExpandedToolLayout.measuredTextHeight(match, font: Self.codeFont, maxWidth: matchW)
          matchLabel.frame = NSRect(
            x: matchX, y: y, width: matchW, height: matchH
          )
          contentContainer.addSubview(matchLabel)
          y += matchH
        }

        y += 6
      }
    }

    // ── Todo (structured checklist) ──

    private func buildTodoContent(plan: ExpandedToolTodoSectionPlan, width: CGFloat) {
      var y: CGFloat = Self.contentTopPad
      let contentWidth = width - Self.headerHPad * 2
      let items = plan.items

      if !items.isEmpty {
        let todoHeader = NSTextField(labelWithString: "")
        let attrs: [NSAttributedString.Key: Any] = [
          .kern: 0.8,
          .font: Self.sectionLabelFont as Any,
          .foregroundColor: Self.textQuaternary,
        ]
        todoHeader.attributedStringValue = NSAttributedString(string: "TODOS", attributes: attrs)
        todoHeader.frame = NSRect(x: Self.headerHPad, y: y + Self.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(todoHeader)
        y += Self.sectionHeaderHeight + Self.sectionPadding

        for item in items {
          let style = ExpandedToolLayout.todoStatusStyle(item.status)
          let metrics = ExpandedToolRenderPlanning.todoRowMetrics(for: item, contentWidth: contentWidth)

          let rowX = Self.headerHPad
          let rowW = contentWidth
          let iconAndGap = ExpandedToolLayout.todoIconWidth + 8
          let textX = rowX + ExpandedToolLayout.todoRowHorizontalPadding + iconAndGap
          let badgeX = rowX + rowW - ExpandedToolLayout.todoRowHorizontalPadding - metrics.badgeWidth

          let rowBackground = NSView(frame: NSRect(x: rowX, y: y, width: rowW, height: metrics.rowHeight))
          rowBackground.wantsLayer = true
          rowBackground.layer?.cornerRadius = 8
          rowBackground.layer?.backgroundColor = style.rowBackground.cgColor
          contentContainer.addSubview(rowBackground)

          let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
          let iconView = NSImageView()
          iconView.image = NSImage(
            systemSymbolName: metrics.iconName,
            accessibilityDescription: nil
          )?
            .withSymbolConfiguration(iconConfig)
          iconView.contentTintColor = style.tint
          iconView.frame = NSRect(
            x: rowX + ExpandedToolLayout.todoRowHorizontalPadding,
            y: y + (metrics.rowHeight - 14) / 2,
            width: 14,
            height: 14
          )
          contentContainer.addSubview(iconView)

          let primaryLabel = NSTextField(labelWithString: item.primaryText)
          primaryLabel.font = ExpandedToolLayout.todoTitleFont
          primaryLabel.textColor = Self.textPrimary
          primaryLabel.lineBreakMode = .byWordWrapping
          primaryLabel.maximumNumberOfLines = 0
          primaryLabel.isSelectable = true
          primaryLabel.frame = NSRect(
            x: textX,
            y: y + ExpandedToolLayout.todoRowVerticalPadding,
            width: metrics.textWidth,
            height: metrics.primaryHeight
          )
          contentContainer.addSubview(primaryLabel)

          if let secondaryText = item.secondaryText {
            let secondaryLabel = NSTextField(labelWithString: secondaryText)
            secondaryLabel.font = ExpandedToolLayout.todoSecondaryFont
            secondaryLabel.textColor = Self.textTertiary
            secondaryLabel.lineBreakMode = .byWordWrapping
            secondaryLabel.maximumNumberOfLines = 0
            secondaryLabel.isSelectable = true
            secondaryLabel.frame = NSRect(
              x: textX,
              y: primaryLabel.frame.maxY + 2,
              width: metrics.textWidth,
              height: metrics.secondaryHeight
            )
            contentContainer.addSubview(secondaryLabel)
          }

          let badgeHeight = ExpandedToolLayout.todoBadgeHeight
          let badgeY = y + (metrics.rowHeight - badgeHeight) / 2
          let badgeView = NSView(frame: NSRect(x: badgeX, y: badgeY, width: metrics.badgeWidth, height: badgeHeight))
          badgeView.wantsLayer = true
          badgeView.layer?.cornerRadius = 6
          badgeView.layer?.backgroundColor = style.badgeBackground.cgColor
          contentContainer.addSubview(badgeView)

          let badgeLabel = NSTextField(labelWithString: metrics.statusText)
          badgeLabel.font = Self.statsFont
          badgeLabel.textColor = Self.textPrimary
          badgeLabel.alignment = .center
          badgeLabel.frame = NSRect(x: 0, y: 3, width: metrics.badgeWidth, height: 14)
          badgeView.addSubview(badgeLabel)

          y += metrics.rowHeight + ExpandedToolLayout.todoRowSpacing
        }

        y += Self.sectionPadding
      }

      if !plan.outputLines.isEmpty {
        let outputHeader = NSTextField(labelWithString: "")
        let attrs: [NSAttributedString.Key: Any] = [
          .kern: 0.8,
          .font: Self.sectionLabelFont as Any,
          .foregroundColor: Self.textQuaternary,
        ]
        outputHeader.attributedStringValue = NSAttributedString(string: "RESULT", attributes: attrs)
        outputHeader.frame = NSRect(x: Self.headerHPad, y: y + Self.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(outputHeader)
        y += Self.sectionHeaderHeight + Self.sectionPadding

        let textW = width - Self.headerHPad * 2
        for line in plan.outputLines {
          let label = NSTextField(labelWithString: line)
          label.font = Self.codeFont
          label.textColor = Self.textSecondary
          label.lineBreakMode = .byCharWrapping
          label.maximumNumberOfLines = 0
          label.isSelectable = true
          let lineH = ExpandedToolLayout.measuredTextHeight(line, font: Self.codeFont, maxWidth: textW)
          label.frame = NSRect(x: Self.headerHPad, y: y, width: textW, height: lineH)
          contentContainer.addSubview(label)
          y += lineH
        }

        y += Self.sectionPadding
      }
    }

    // ── Generic (input + output) ──

    private func buildPayloadSection(
      plan: ExpandedToolPayloadSectionRenderPlan,
      width: CGFloat,
      startY: CGFloat
    ) -> CGFloat {
      let rows = ExpandedToolRenderPlanning.payloadTextRows(for: plan.items)
      guard !rows.isEmpty else { return startY }
      let y = startY

      let header = NSTextField(labelWithString: "")
      let attrs: [NSAttributedString.Key: Any] = [
        .kern: 0.8,
        .font: Self.sectionLabelFont as Any,
        .foregroundColor: Self.textQuaternary,
      ]
      header.attributedStringValue = NSAttributedString(string: plan.title, attributes: attrs)
      header.frame = NSRect(x: Self.headerHPad, y: y + Self.sectionPadding, width: 80, height: 14)
      contentContainer.addSubview(header)
      var nextY = y + Self.sectionHeaderHeight + Self.sectionPadding

      let textWidth = width - Self.headerHPad * 2
      for row in rows {
        nextY += row.topInset
        let labelWidth = textWidth - row.widthAdjustment

        let labelPlan = ExpandedToolCellPlanning.payloadLabelPlan(for: row, containerWidth: width)
        let label = payloadLabel(for: labelPlan)
        label.frame = NSRect(
          x: labelPlan.frame.origin.x,
          y: nextY,
          width: labelPlan.frame.width,
          height: labelPlan.frame.height
        )
        contentContainer.addSubview(label)
        nextY += label.frame.height + row.bottomSpacing
      }

      return nextY + Self.sectionPadding
    }

    private func payloadLabel(for plan: ExpandedToolPayloadLabelPlan) -> NSTextField {
      if let key = plan.attributedKey, let value = plan.attributedValue {
        let label = NSTextField(labelWithAttributedString: payloadAttributedLine(key: key, value: value))
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        return label
      }

      let label = NSTextField(labelWithString: plan.text ?? " ")
      label.font = payloadFont(for: plan.style)
      label.textColor = payloadColor(for: plan.style)
      label.lineBreakMode = plan.style == .textLine || plan.style == .structuredEntry ? .byCharWrapping : .byWordWrapping
      label.maximumNumberOfLines = 0
      label.isSelectable = true
      return label
    }

    private func payloadAttributedLine(key: String, value: String) -> NSAttributedString {
      let attributed = NSMutableAttributedString(
        string: "\(key): ",
        attributes: [
          .font: Self.codeFontStrong as Any,
          .foregroundColor: Self.textQuaternary,
        ]
      )
      attributed.append(NSAttributedString(
        string: value,
        attributes: [
          .font: Self.codeFont as Any,
          .foregroundColor: Self.textSecondary,
        ]
      ))
      return attributed
    }

    private func payloadFont(for style: ExpandedToolPayloadTextStyle) -> NSFont {
      switch style {
        case .questionHeader:
          NSFont.systemFont(ofSize: TypeScale.mini, weight: .bold)
        case .questionPrompt:
          NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
        case .questionOption:
          NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
        case .questionDetail:
          NSFont.systemFont(ofSize: TypeScale.meta, weight: .regular)
        case .structuredEntry, .textLine:
          Self.codeFont
      }
    }

    private func payloadColor(for style: ExpandedToolPayloadTextStyle) -> NSColor {
      switch style {
        case .questionHeader:
          Self.textQuaternary
        case .questionPrompt:
          Self.textPrimary
        case .questionOption:
          Self.textSecondary
        case .questionDetail:
          Self.textTertiary
        case .structuredEntry, .textLine:
          Self.textSecondary
      }
    }

    // ── Height Calculation (delegates to shared ExpandedToolLayout) ──

    static func headerHeight(for model: NativeExpandedToolModel?) -> CGFloat {
      ExpandedToolLayout.headerHeight(for: model)
    }

    static func contentHeight(for model: NativeExpandedToolModel) -> CGFloat {
      ExpandedToolLayout.contentHeight(for: model)
    }

    static func requiredHeight(for width: CGFloat, model: NativeExpandedToolModel) -> CGFloat {
      let total = ExpandedToolLayout.requiredHeight(for: width, model: model)
      let tool = ExpandedToolLayout.toolTypeName(model.content)
      let h = ExpandedToolLayout.headerHeight(for: model)
      let c = ExpandedToolLayout.contentHeight(for: model)
      logger.debug(
        "requiredHeight[\(model.messageID)] \(tool) "
          + "header=\(f(h)) content=\(f(c)) total=\(f(total)) w=\(f(width))"
      )
      return total
    }

    private func f(_ v: CGFloat) -> String {
      String(format: "%.1f", v)
    }

    private static func f(_ v: CGFloat) -> String {
      String(format: "%.1f", v)
    }
  }

  // MARK: - Flipped Content View

  private final class FlippedContentView: NSView {
    override var isFlipped: Bool {
      true
    }
  }

#endif
