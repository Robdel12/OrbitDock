//
//  ToolContentRenderer.swift
//  OrbitDock
//
//  Static content builder methods extracted from UIKitExpandedToolCell.
//  Each method adds subviews to a container for a specific tool content type.
//

#if os(iOS)

  import SwiftUI
  import UIKit

  private typealias EL = ExpandedToolLayout

  enum ToolContentRenderer {
    // MARK: - Content Dispatch

    static func buildContent(
      in container: UIView,
      model: NativeExpandedToolModel,
      width: CGFloat
    ) {
      switch model.content {
        case let .bash(_, input, output):
          buildGenericContent(in: container, input: input, output: output, width: width)
        case let .edit(_, _, _, _, lines, isWriteNew):
          buildEditContent(in: container, lines: lines, isWriteNew: isWriteNew, width: width)
        case let .read(_, _, language, lines):
          buildReadContent(in: container, lines: lines, language: language, width: width)
        case let .glob(_, grouped):
          buildGlobContent(in: container, grouped: grouped, width: width)
        case let .grep(_, grouped):
          buildGrepContent(in: container, grouped: grouped, width: width)
        case let .task(_, _, _, output, _):
          buildTextOutputContent(in: container, output: output, width: width)
        case let .todo(_, _, items, output):
          buildTodoContent(in: container, items: items, output: output, width: width)
        case let .mcp(_, _, _, input, output):
          buildGenericContent(in: container, input: input, output: output, width: width)
        case let .webFetch(_, _, input, output):
          buildGenericContent(in: container, input: input, output: output, width: width)
        case let .webSearch(_, input, output):
          buildGenericContent(in: container, input: input, output: output, width: width)
        case let .generic(toolName, input, output):
          buildGenericContent(in: container, toolName: toolName, input: input, output: output, width: width)
      }
    }

    // MARK: - Text Output

    static func buildTextOutputContent(in container: UIView, output: String?, width: CGFloat) {
      guard let output, !output.isEmpty else { return }

      let lines = output.components(separatedBy: "\n")
      let textWidth = width - EL.headerHPad * 2
      var y: CGFloat = EL.sectionPadding + EL.contentTopPad

      for line in lines {
        let text = line.isEmpty ? " " : line
        let label = makeCodeLabel(text, color: EL.textSecondary)
        let labelH = EL.measuredTextHeight(text, font: EL.codeFont, maxWidth: textWidth)
        label.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: labelH)
        container.addSubview(label)
        y += labelH
      }
    }

    // MARK: - Edit (diff lines)

    static func buildEditContent(
      in container: UIView,
      lines: [DiffLine],
      isWriteNew: Bool,
      width: CGFloat
    ) {
      var y: CGFloat = 0

      if isWriteNew {
        let header = UILabel()
        header.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .bold)
        header.textColor = EL.addedAccentColor
        header.text = "NEW FILE (\(lines.count) lines)"
        header.frame = CGRect(x: EL.headerHPad, y: y + 6, width: width - EL.headerHPad * 2, height: 16)
        container.addSubview(header)

        let headerBg = UIView(frame: CGRect(x: 0, y: y, width: width, height: 28))
        headerBg.backgroundColor = EL.addedBgColor.withAlphaComponent(0.3)
        container.insertSubview(headerBg, at: 0)
        y += 28
      }

      let gutterMetrics = EL.diffGutterMetrics(for: lines)
      let codeX = gutterMetrics.codeX
      let codeAvailW = width - codeX - EL.diffContentTrailingPad
      let diffFont = EL.diffContentFont

      var maxTextWidth: CGFloat = 0
      for line in lines {
        let text = line.content.isEmpty ? " " : line.content
        let w = ceil((text as NSString).size(withAttributes: [.font: diffFont as Any]).width)
        maxTextWidth = max(maxTextWidth, w)
      }
      let scrollContentW = max(codeAvailW, maxTextWidth + 8)

      let totalDiffH = CGFloat(lines.count) * EL.diffLineHeight
      let scrollView = HorizontalPanPassthroughScrollView()
      scrollView.showsHorizontalScrollIndicator = true
      scrollView.showsVerticalScrollIndicator = false
      scrollView.backgroundColor = .clear
      scrollView.frame = CGRect(x: codeX, y: y, width: codeAvailW, height: totalDiffH)
      scrollView.contentSize = CGSize(width: scrollContentW, height: totalDiffH)

      var rowY: CGFloat = 0
      for line in lines {
        let bgColor: UIColor
        let prefixColor: UIColor
        let contentColor: UIColor
        switch line.type {
          case .added:
            bgColor = EL.addedBgColor
            prefixColor = EL.addedAccentColor
            contentColor = EL.textPrimary
          case .removed:
            bgColor = EL.removedBgColor
            prefixColor = EL.removedAccentColor
            contentColor = EL.textPrimary
          case .context:
            bgColor = .clear
            prefixColor = EL.textQuaternary
            contentColor = EL.textTertiary
        }

        let rowBg = UIView(frame: CGRect(x: 0, y: y + rowY, width: width, height: EL.diffLineHeight))
        rowBg.backgroundColor = bgColor
        container.addSubview(rowBg)

        if let oldLineNumberX = gutterMetrics.oldLineNumberX, let num = line.oldLineNum {
          let numLabel = makeLineNumLabel("\(num)")
          numLabel.textAlignment = .right
          numLabel.frame = CGRect(
            x: oldLineNumberX, y: y + rowY + 2,
            width: gutterMetrics.oldLineNumberWidth, height: 18
          )
          container.addSubview(numLabel)
        }
        if let newLineNumberX = gutterMetrics.newLineNumberX, let num = line.newLineNum {
          let numLabel = makeLineNumLabel("\(num)")
          numLabel.textAlignment = .right
          numLabel.frame = CGRect(
            x: newLineNumberX, y: y + rowY + 2,
            width: gutterMetrics.newLineNumberWidth, height: 18
          )
          container.addSubview(numLabel)
        }

        let prefixLabel = UILabel()
        prefixLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.code, weight: .bold)
        prefixLabel.textColor = prefixColor
        prefixLabel.text = line.prefix
        prefixLabel.frame = CGRect(
          x: gutterMetrics.prefixX, y: y + rowY + 1,
          width: EL.diffPrefixWidth, height: 20
        )
        container.addSubview(prefixLabel)

        let text = line.content.isEmpty ? " " : line.content
        let contentLabel = UILabel()
        contentLabel.font = diffFont
        contentLabel.textColor = contentColor
        contentLabel.text = text
        contentLabel.lineBreakMode = .byClipping
        contentLabel.numberOfLines = 1
        contentLabel.frame = CGRect(x: 0, y: rowY + 2, width: scrollContentW, height: 18)
        scrollView.addSubview(contentLabel)

        rowY += EL.diffLineHeight
      }

      container.addSubview(scrollView)
    }

    // MARK: - Read (line-numbered code)

    static func buildReadContent(
      in container: UIView,
      lines: [String],
      language: String,
      width: CGFloat
    ) {
      let gutterMetrics = EL.readGutterMetrics(lineCount: lines.count)
      let codeX = gutterMetrics.codeX
      let codeAvailW = width - codeX - EL.diffContentTrailingPad
      let lang = language.isEmpty ? nil : language
      let y: CGFloat = EL.sectionPadding + EL.contentTopPad

      var maxTextWidth: CGFloat = 0
      for line in lines {
        let text = line.isEmpty ? " " : line
        let w = ceil((text as NSString).size(withAttributes: [.font: EL.codeFont as Any]).width)
        maxTextWidth = max(maxTextWidth, w)
      }
      let scrollContentW = max(codeAvailW, maxTextWidth + 8)

      let totalH = CGFloat(lines.count) * EL.contentLineHeight
      let scrollView = HorizontalPanPassthroughScrollView()
      scrollView.showsHorizontalScrollIndicator = true
      scrollView.showsVerticalScrollIndicator = false
      scrollView.backgroundColor = .clear
      scrollView.frame = CGRect(x: codeX, y: y, width: codeAvailW, height: totalH)
      scrollView.contentSize = CGSize(width: scrollContentW, height: totalH)

      var rowY: CGFloat = 0
      for (index, line) in lines.enumerated() {
        let text = line.isEmpty ? " " : line

        let numLabel = makeLineNumLabel("\(index + 1)")
        numLabel.textAlignment = .right
        numLabel.frame = CGRect(
          x: gutterMetrics.lineNumberX, y: y + rowY,
          width: gutterMetrics.lineNumberWidth, height: EL.contentLineHeight
        )
        container.addSubview(numLabel)

        let codeLine = UILabel()
        codeLine.attributedText = SyntaxHighlighter.highlightNativeLine(text, language: lang)
        codeLine.lineBreakMode = .byClipping
        codeLine.numberOfLines = 1
        codeLine.frame = CGRect(x: 0, y: rowY, width: scrollContentW, height: EL.contentLineHeight)
        scrollView.addSubview(codeLine)

        rowY += EL.contentLineHeight
      }

      container.addSubview(scrollView)
    }

    // MARK: - Glob (directory tree)

    static func buildGlobContent(
      in container: UIView,
      grouped: [(dir: String, files: [String])],
      width: CGFloat
    ) {
      let textWidth = width - EL.headerHPad * 2
      let dirFont = UIFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
      let fileFont = UIFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
      var y: CGFloat = EL.sectionPadding + EL.contentTopPad

      for (dir, files) in grouped {
        let dirText = "\(dir == "." ? "(root)" : dir) (\(files.count))"
        let dirH = EL.measuredTextHeight(dirText, font: dirFont, maxWidth: textWidth - 18)

        let dirIcon = UIImageView()
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        dirIcon.image = UIImage(systemName: "folder.fill")?.withConfiguration(iconConfig)
        dirIcon.tintColor = UIColor(Color.toolWrite)
        dirIcon.frame = CGRect(x: EL.headerHPad, y: y + 2, width: 14, height: 14)
        container.addSubview(dirIcon)

        let dirLabel = makeCodeLabel(dirText, color: EL.textSecondary, fontSize: TypeScale.meta, weight: .medium)
        dirLabel.frame = CGRect(x: EL.headerHPad + 18, y: y, width: textWidth - 18, height: dirH)
        container.addSubview(dirLabel)
        y += dirH + 2

        let fileX = EL.headerHPad + 28
        let fileW = textWidth - 28
        for file in files {
          let filename = file.components(separatedBy: "/").last ?? file
          let fileH = EL.measuredTextHeight(filename, font: fileFont, maxWidth: fileW)
          let fileLabel = makeCodeLabel(filename, color: EL.textTertiary, fontSize: TypeScale.meta)
          fileLabel.frame = CGRect(x: fileX, y: y, width: fileW, height: fileH)
          container.addSubview(fileLabel)
          y += fileH
        }

        y += 6
      }
    }

    // MARK: - Grep (file-grouped results)

    static func buildGrepContent(
      in container: UIView,
      grouped: [(file: String, matches: [String])],
      width: CGFloat
    ) {
      let textWidth = width - EL.headerHPad * 2
      let fileFont = UIFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
      var y: CGFloat = EL.sectionPadding + EL.contentTopPad

      for (file, matches) in grouped {
        let shortPath = file.components(separatedBy: "/").suffix(3).joined(separator: "/")
        let matchSuffix = matches.isEmpty ? "" : " (\(matches.count))"
        let fileText = shortPath + matchSuffix
        let fileH = EL.measuredTextHeight(fileText, font: fileFont, maxWidth: textWidth)
        let fileLabel = makeCodeLabel(fileText, color: EL.textPrimary, fontSize: TypeScale.meta, weight: .medium)
        fileLabel.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: fileH)
        container.addSubview(fileLabel)
        y += fileH + 2

        let matchX = EL.headerHPad + 16
        let matchW = textWidth - 16
        for match in matches {
          let matchH = EL.measuredTextHeight(match, font: EL.codeFont, maxWidth: matchW)
          let matchLabel = makeCodeLabel(match, color: EL.textTertiary)
          matchLabel.frame = CGRect(x: matchX, y: y, width: matchW, height: matchH)
          container.addSubview(matchLabel)
          y += matchH
        }

        y += 6
      }
    }

    // MARK: - Todo (structured checklist)

    static func buildTodoContent(
      in container: UIView,
      items: [NativeTodoItem],
      output: String?,
      width: CGFloat
    ) {
      let contentWidth = width - EL.headerHPad * 2
      var y: CGFloat = EL.contentTopPad

      if !items.isEmpty {
        let todoHeader = makeSectionHeader("TODOS")
        todoHeader.frame = CGRect(x: EL.headerHPad, y: y + EL.sectionPadding, width: 60, height: 14)
        container.addSubview(todoHeader)
        y += EL.sectionHeaderHeight + EL.sectionPadding

        for item in items {
          let style = EL.todoStatusStyle(item.status)
          let metrics = ExpandedToolRenderPlanning.todoRowMetrics(for: item, contentWidth: contentWidth)

          let rowX = EL.headerHPad
          let rowW = contentWidth
          let iconAndGap = EL.todoIconWidth + 8
          let textX = rowX + EL.todoRowHorizontalPadding + iconAndGap
          let badgeX = rowX + rowW - EL.todoRowHorizontalPadding - metrics.badgeWidth

          let rowBackground = UIView(frame: CGRect(x: rowX, y: y, width: rowW, height: metrics.rowHeight))
          rowBackground.backgroundColor = style.rowBackground
          rowBackground.layer.cornerRadius = 8
          container.addSubview(rowBackground)

          let icon = UIImageView()
          let iconConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
          icon.image = UIImage(systemName: metrics.iconName)?.withConfiguration(iconConfig)
          icon.tintColor = style.tint
          icon.frame = CGRect(
            x: rowX + EL.todoRowHorizontalPadding,
            y: y + (metrics.rowHeight - 14) / 2,
            width: 14, height: 14
          )
          container.addSubview(icon)

          let primaryLabel = UILabel()
          primaryLabel.font = EL.todoTitleFont
          primaryLabel.textColor = EL.textPrimary
          primaryLabel.lineBreakMode = .byWordWrapping
          primaryLabel.numberOfLines = 0
          primaryLabel.text = item.primaryText
          primaryLabel.frame = CGRect(
            x: textX, y: y + EL.todoRowVerticalPadding,
            width: metrics.textWidth, height: metrics.primaryHeight
          )
          container.addSubview(primaryLabel)

          if let secondaryText = item.secondaryText {
            let secondaryLabel = UILabel()
            secondaryLabel.font = EL.todoSecondaryFont
            secondaryLabel.textColor = EL.textTertiary
            secondaryLabel.lineBreakMode = .byWordWrapping
            secondaryLabel.numberOfLines = 0
            secondaryLabel.text = secondaryText
            secondaryLabel.frame = CGRect(
              x: textX, y: primaryLabel.frame.maxY + 2,
              width: metrics.textWidth, height: metrics.secondaryHeight
            )
            container.addSubview(secondaryLabel)
          }

          let badgeHeight = EL.todoBadgeHeight
          let badgeY = y + (metrics.rowHeight - badgeHeight) / 2
          let badgeView = UIView(frame: CGRect(x: badgeX, y: badgeY, width: metrics.badgeWidth, height: badgeHeight))
          badgeView.backgroundColor = style.badgeBackground
          badgeView.layer.cornerRadius = 6
          container.addSubview(badgeView)

          let badgeLabel = UILabel()
          badgeLabel.font = EL.statsFont
          badgeLabel.textColor = EL.textPrimary
          badgeLabel.textAlignment = .center
          badgeLabel.text = metrics.statusText
          badgeLabel.frame = CGRect(x: 0, y: 3, width: metrics.badgeWidth, height: 14)
          badgeView.addSubview(badgeLabel)

          y += metrics.rowHeight + EL.todoRowSpacing
        }

        y += EL.sectionPadding
      }

      if let output, !output.isEmpty {
        let outputHeader = makeSectionHeader("RESULT")
        outputHeader.frame = CGRect(x: EL.headerHPad, y: y + EL.sectionPadding, width: 60, height: 14)
        container.addSubview(outputHeader)
        y += EL.sectionHeaderHeight + EL.sectionPadding

        let textWidth = width - EL.headerHPad * 2
        let outputLines = output.components(separatedBy: "\n")
        for line in outputLines {
          let text = line.isEmpty ? " " : line
          let label = makeCodeLabel(text, color: EL.textSecondary)
          let labelH = EL.measuredTextHeight(text, font: EL.codeFont, maxWidth: textWidth)
          label.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: labelH)
          container.addSubview(label)
          y += labelH
        }
      }
    }

    // MARK: - Generic (input + output)

    static func buildGenericContent(
      in container: UIView,
      toolName: String? = nil,
      input: String?,
      output: String?,
      width: CGFloat
    ) {
      let textWidth = width - EL.headerHPad * 2
      var y: CGFloat = EL.contentTopPad

      buildPayloadSection(in: container, title: "INPUT", payload: input, toolName: toolName, textWidth: textWidth, y: &y)
      buildPayloadSection(in: container, title: "OUTPUT", payload: output, textWidth: textWidth, y: &y)
    }

    private static func buildPayloadSection(
      in container: UIView,
      title: String,
      payload: String?,
      toolName: String? = nil,
      textWidth: CGFloat,
      y: inout CGFloat
    ) {
      let rows = ExpandedToolRenderPlanning.payloadSectionTextRows(
        title: title,
        payload: payload,
        toolName: toolName
      )
      guard !rows.isEmpty else { return }

      let header = makeSectionHeader(title)
      header.frame = CGRect(x: EL.headerHPad, y: y + EL.sectionPadding, width: 80, height: 14)
      container.addSubview(header)
      y += EL.sectionHeaderHeight + EL.sectionPadding

      for row in rows {
        y += row.topInset
        let labelWidth = textWidth - row.widthAdjustment
        let label = makePayloadLabel(for: row)
        label.frame = CGRect(
          x: EL.headerHPad + row.leadingInset,
          y: y,
          width: labelWidth,
          height: payloadRowHeight(row, maxWidth: labelWidth)
        )
        container.addSubview(label)
        y += label.frame.height + row.bottomSpacing
      }

      y += EL.sectionPadding
    }

    // MARK: - Label Factories

    static func makeCodeLabel(
      _ text: String,
      color: PlatformColor,
      fontSize: CGFloat = 11.5,
      weight: UIFont.Weight = .regular
    ) -> UILabel {
      let label = UILabel()
      label.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
      label.textColor = color
      label.lineBreakMode = .byCharWrapping
      label.numberOfLines = 0
      label.text = text
      return label
    }

    static func makeLineNumLabel(_ text: String) -> UILabel {
      let label = UILabel()
      label.font = EL.lineNumFont
      label.textColor = EL.textQuaternary
      label.text = text
      return label
    }

    static func makeSectionHeader(_ text: String) -> UILabel {
      let label = UILabel()
      let attrs: [NSAttributedString.Key: Any] = [
        .kern: 0.8,
        .font: EL.sectionLabelFont,
        .foregroundColor: EL.textQuaternary,
      ]
      label.attributedText = NSAttributedString(string: text, attributes: attrs)
      return label
    }

    // MARK: - Payload Helpers

    private static func makePayloadLabel(for row: ExpandedToolPayloadTextRowPlan) -> UILabel {
      switch row.content {
        case let .structuredEntry(key, value):
          let label = UILabel()
          label.lineBreakMode = .byCharWrapping
          label.numberOfLines = 0
          let attributed = NSMutableAttributedString(string: "\(key): ", attributes: [
            .font: EL.codeFontStrong,
            .foregroundColor: EL.textQuaternary,
          ])
          attributed.append(NSAttributedString(string: value, attributes: [
            .font: EL.codeFont,
            .foregroundColor: EL.textSecondary,
          ]))
          label.attributedText = attributed
          return label

        case let .plain(text):
          return makeCodeLabel(
            text.isEmpty ? " " : text,
            color: payloadColor(for: row.style),
            fontSize: payloadFontSize(for: row.style),
            weight: payloadFontWeight(for: row.style)
          )
      }
    }

    private static func payloadRowHeight(_ row: ExpandedToolPayloadTextRowPlan, maxWidth: CGFloat) -> CGFloat {
      switch row.content {
        case let .structuredEntry(key, value):
          return EL.measuredTextHeight("\(key): \(value)", font: EL.codeFont, maxWidth: maxWidth)
        case let .plain(text):
          let font = UIFont.systemFont(
            ofSize: payloadFontSize(for: row.style),
            weight: payloadFontWeight(for: row.style)
          )
          return EL.measuredTextHeight(text.isEmpty ? " " : text, font: font, maxWidth: maxWidth)
      }
    }

    private static func payloadFontSize(for style: ExpandedToolPayloadTextStyle) -> CGFloat {
      switch style {
        case .questionHeader: TypeScale.mini
        case .questionPrompt: TypeScale.body
        case .questionOption: TypeScale.caption
        case .questionDetail: TypeScale.meta
        case .structuredEntry, .textLine: 11.5
      }
    }

    private static func payloadFontWeight(for style: ExpandedToolPayloadTextStyle) -> UIFont.Weight {
      switch style {
        case .questionHeader: .bold
        case .questionPrompt: .semibold
        case .questionOption: .medium
        case .questionDetail, .structuredEntry, .textLine: .regular
      }
    }

    private static func payloadColor(for style: ExpandedToolPayloadTextStyle) -> PlatformColor {
      switch style {
        case .questionHeader: EL.textQuaternary
        case .questionPrompt: EL.textPrimary
        case .questionOption: EL.textSecondary
        case .questionDetail: EL.textTertiary
        case .structuredEntry, .textLine: EL.textSecondary
      }
    }
  }

  // MARK: - HorizontalPanPassthroughScrollView

  final class HorizontalPanPassthroughScrollView: UIScrollView, UIGestureRecognizerDelegate {
    override init(frame: CGRect) {
      super.init(frame: frame)
      configureForHorizontalPan()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      configureForHorizontalPan()
    }

    private func configureForHorizontalPan() {
      isDirectionalLockEnabled = true
      alwaysBounceVertical = false
      panGestureRecognizer.delegate = self
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard gestureRecognizer === panGestureRecognizer,
            let panGesture = gestureRecognizer as? UIPanGestureRecognizer
      else {
        return true
      }
      guard contentSize.width > bounds.width + 1 else { return false }
      let velocity = panGesture.velocity(in: self)
      return abs(velocity.x) > abs(velocity.y)
    }
  }

#endif
