//
//  UIKitExpandedToolCell.swift
//  OrbitDock
//
//  Native UICollectionViewCell for expanded tool cards on iOS.
//  Ports NativeExpandedToolCellView (macOS NSTableCellView) to UIKit.
//  Uses ExpandedToolLayout for shared height calculation and constants.
//

#if os(iOS)

  import SwiftUI
  import UIKit

  // swiftlint:disable type_body_length file_length

  private typealias EL = ExpandedToolLayout

  private final class HorizontalPanPassthroughScrollView: UIScrollView, UIGestureRecognizerDelegate {
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

      // Let the parent conversation scroll view handle vertical swipes.
      guard contentSize.width > bounds.width + 1 else { return false }
      let velocity = panGesture.velocity(in: self)
      return abs(velocity.x) > abs(velocity.y)
    }
  }

  final class UIKitExpandedToolCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitExpandedToolCell"

    // ── Subviews ──

    private let cardBackground = UIView()
    private let accentBar = UIView()
    private let headerDivider = UIView()
    private let contentBg = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statsLabel = UILabel()
    private let durationLabel = UILabel()
    private let collapseChevron = UIImageView()
    private let cancelButton = UIButton(type: .system)
    private let contentContainer = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    // ── State ──

    private var model: NativeExpandedToolModel?
    var onCollapse: ((String) -> Void)?
    var onCancel: ((String) -> Void)?

    // ── Init ──

    override init(frame: CGRect) {
      super.init(frame: frame)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    // ── Setup ──

    private func setup() {
      backgroundColor = .clear
      contentView.backgroundColor = .clear

      // Card background
      cardBackground.backgroundColor = EL.bgColor
      cardBackground.layer.cornerRadius = EL.cornerRadius
      cardBackground.layer.masksToBounds = true
      cardBackground.layer.borderWidth = 1
      contentView.addSubview(cardBackground)

      // Accent bar
      cardBackground.addSubview(accentBar)

      // Header divider
      headerDivider.backgroundColor = EL.headerDividerColor
      cardBackground.addSubview(headerDivider)

      // Content background
      contentBg.backgroundColor = EL.contentBgColor
      cardBackground.addSubview(contentBg)

      // Icon
      iconView.contentMode = .scaleAspectFit
      cardBackground.addSubview(iconView)

      // Title
      titleLabel.font = EL.headerFont
      titleLabel.textColor = EL.textPrimary
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.numberOfLines = 1
      cardBackground.addSubview(titleLabel)

      // Subtitle
      subtitleLabel.font = EL.subtitleFont
      subtitleLabel.textColor = EL.textTertiary
      subtitleLabel.lineBreakMode = .byTruncatingTail
      subtitleLabel.numberOfLines = 1
      cardBackground.addSubview(subtitleLabel)

      // Stats
      statsLabel.font = EL.statsFont
      statsLabel.textColor = EL.textTertiary
      statsLabel.textAlignment = .right
      cardBackground.addSubview(statsLabel)

      // Duration
      durationLabel.font = EL.statsFont
      durationLabel.textColor = EL.textQuaternary
      durationLabel.textAlignment = .right
      cardBackground.addSubview(durationLabel)

      // Collapse chevron
      let chevronConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
      collapseChevron.image = UIImage(systemName: "chevron.down")?.withConfiguration(chevronConfig)
      collapseChevron.tintColor = EL.textQuaternary
      cardBackground.addSubview(collapseChevron)

      // Spinner
      spinner.color = EL.textTertiary
      spinner.hidesWhenStopped = true
      spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
      cardBackground.addSubview(spinner)

      // Cancel button (shell-only)
      cancelButton.setTitle("Stop", for: .normal)
      cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.meta, weight: .semibold)
      cancelButton.setTitleColor(UIColor(Color.statusError), for: .normal)
      cancelButton.isHidden = true
      cancelButton.addTarget(self, action: #selector(handleCancelTap), for: .touchUpInside)
      cardBackground.addSubview(cancelButton)

      // Content container
      contentContainer.clipsToBounds = true
      cardBackground.addSubview(contentContainer)

      // Header tap gesture
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleHeaderTap(_:)))
      cardBackground.addGestureRecognizer(tap)
    }

    @objc private func handleHeaderTap(_ gesture: UITapGestureRecognizer) {
      let location = gesture.location(in: cardBackground)
      if !cancelButton.isHidden, cancelButton.frame.contains(location) {
        return
      }
      let headerHeight = EL.headerHeight(for: model)
      if location.y <= headerHeight, let messageID = model?.messageID {
        onCollapse?(messageID)
      }
    }

    @objc private func handleCancelTap() {
      guard let messageID = model?.messageID else { return }
      onCancel?(messageID)
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onCollapse = nil
      onCancel = nil
      model = nil
      contentContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    // ── Configure ──

    func configure(model: NativeExpandedToolModel, width: CGFloat) {
      self.model = model

      let inset = EL.laneHorizontalInset
      let cardWidth = width - inset * 2
      let headerH = EL.headerHeight(for: model, cardWidth: cardWidth)
      let contentH = EL.contentHeight(for: model, cardWidth: cardWidth)
      let totalH = EL.requiredHeight(for: width, model: model)

      // Card background
      cardBackground.frame = CGRect(x: inset, y: 0, width: cardWidth, height: totalH)
      cardBackground.layer.borderColor = model.toolColor.withAlphaComponent(OpacityTier.light).cgColor

      // Accent bar
      let accentColor: UIColor = model.hasError ? UIColor(Color.statusError) : model.toolColor
      accentBar.backgroundColor = accentColor
      accentBar.frame = CGRect(x: 0, y: 0, width: EL.accentBarWidth, height: totalH)

      // Header divider
      let dividerX = EL.accentBarWidth
      let dividerW = cardWidth - EL.accentBarWidth
      headerDivider.frame = CGRect(x: dividerX, y: headerH, width: dividerW, height: 1)
      headerDivider.isHidden = contentH == 0

      // Content background
      if contentH > 0 {
        contentBg.isHidden = false
        contentBg.frame = CGRect(x: dividerX, y: headerH + 1, width: dividerW, height: contentH)
      } else {
        contentBg.isHidden = true
      }

      // Icon
      let iconConfig = UIImage.SymbolConfiguration(pointSize: EL.iconSize, weight: .medium)
      iconView.image = UIImage(systemName: model.iconName)?.withConfiguration(iconConfig)
      iconView.tintColor = model.hasError ? UIColor(Color.statusError) : model.toolColor
      iconView.frame = CGRect(
        x: EL.accentBarWidth + EL.headerHPad,
        y: EL.headerVPad,
        width: 20, height: 20
      )

      // Title + subtitle
      configureHeader(model: model, cardWidth: cardWidth, headerH: headerH)

      // Progress spinner
      if model.isInProgress {
        spinner.startAnimating()
        let spinnerX = model.canCancel
          ? cardWidth - EL.headerHPad - 72
          : cardWidth - EL.headerHPad - 16
        spinner.frame = CGRect(
          x: spinnerX,
          y: EL.headerVPad + 2,
          width: 16, height: 16
        )
      } else {
        spinner.stopAnimating()
      }

      if model.canCancel {
        cancelButton.isHidden = false
        cancelButton.frame = CGRect(
          x: cardWidth - EL.headerHPad - 52,
          y: EL.headerVPad,
          width: 52,
          height: 20
        )
      } else {
        cancelButton.isHidden = true
      }

      // Collapse chevron
      if !model.isInProgress, !model.canCancel {
        collapseChevron.isHidden = false
        collapseChevron.frame = CGRect(
          x: cardWidth - EL.headerHPad - 12,
          y: EL.headerVPad + 3,
          width: 12, height: 12
        )
      } else {
        collapseChevron.isHidden = true
      }

      // Duration
      if let dur = model.duration, !model.isInProgress, !model.canCancel {
        durationLabel.isHidden = false
        durationLabel.text = dur
        durationLabel.sizeToFit()
        let durW = durationLabel.frame.width
        let durX = cardWidth - EL.headerHPad - 12 - 8 - durW
        durationLabel.frame = CGRect(x: durX, y: EL.headerVPad + 2, width: durW, height: 16)
      } else {
        durationLabel.isHidden = true
      }

      // Content
      contentContainer.subviews.forEach { $0.removeFromSuperview() }
      contentContainer.frame = CGRect(x: 0, y: headerH, width: cardWidth, height: contentH)
      buildContent(model: model, width: cardWidth)
    }

    // ── Header Configuration ──

    private func configureHeader(model: NativeExpandedToolModel, cardWidth: CGFloat, headerH: CGFloat) {
      let leftEdge = EL.accentBarWidth + EL.headerHPad + 20 + 8
      let rightEdge = cardWidth - EL.headerHPad - 12 - 8 - 60

      switch model.content {
        case let .bash(command, _, _):
          let bashColor: UIColor = model.hasError ? UIColor(Color.statusError) : model.toolColor
          let bashAttr = NSMutableAttributedString()
          bashAttr.append(NSAttributedString(
            string: "$ ",
            attributes: [
              .font: UIFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .bold),
              .foregroundColor: bashColor,
            ]
          ))
          bashAttr.append(NSAttributedString(
            string: command,
            attributes: [
              .font: UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
              .foregroundColor: EL.textPrimary,
            ]
          ))
          titleLabel.attributedText = bashAttr
          titleLabel.lineBreakMode = .byCharWrapping
          titleLabel.numberOfLines = 0
          subtitleLabel.isHidden = true
          statsLabel.isHidden = true

        case let .edit(filename, path, additions, deletions, _, _):
          titleLabel.attributedText = nil
          titleLabel.text = filename ?? "Edit"
          titleLabel.font = EL.headerFont
          titleLabel.textColor = EL.textPrimary
          subtitleLabel.isHidden = path == nil
          subtitleLabel.text = path.map { ToolCardStyle.shortenPath($0) }
          configureEditStats(additions: additions, deletions: deletions, cardWidth: cardWidth)
          return

        case let .read(filename, path, language, lines):
          titleLabel.attributedText = nil
          titleLabel.text = filename ?? "Read"
          titleLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .semibold)
          titleLabel.textColor = EL.textPrimary
          subtitleLabel.isHidden = path == nil
          subtitleLabel.text = path.map { ToolCardStyle.shortenPath($0) }
          statsLabel.isHidden = false
          statsLabel.text = "\(lines.count) lines" + (language.isEmpty ? "" : " · \(language)")

        case let .glob(pattern, grouped):
          let fileCount = grouped.reduce(0) { $0 + $1.files.count }
          titleLabel.attributedText = nil
          titleLabel.text = "Glob"
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.isHidden = false
          subtitleLabel.text = pattern
          statsLabel.isHidden = false
          statsLabel.text = "\(fileCount) \(fileCount == 1 ? "file" : "files")"

        case let .grep(pattern, grouped):
          let matchCount = grouped.reduce(0) { $0 + max(1, $1.matches.count) }
          titleLabel.attributedText = nil
          titleLabel.text = "Grep"
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.isHidden = false
          subtitleLabel.text = pattern
          statsLabel.isHidden = false
          statsLabel.text = "\(matchCount) in \(grouped.count) \(grouped.count == 1 ? "file" : "files")"

        case let .task(agentLabel, _, description, _, isComplete):
          titleLabel.attributedText = nil
          titleLabel.text = agentLabel
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.isHidden = description.isEmpty
          subtitleLabel.text = description
          statsLabel.isHidden = false
          statsLabel.text = isComplete ? "Complete" : "Running..."
          statsLabel.textColor = EL.textTertiary

        case let .todo(title, subtitle, items, _):
          let completedCount = items.filter { $0.status == .completed }.count
          let activeCount = items.filter { $0.status == .inProgress }.count
          titleLabel.attributedText = nil
          titleLabel.text = title
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.text = subtitle
          subtitleLabel.isHidden = subtitle?.isEmpty ?? true
          if !items.isEmpty {
            var statusParts = ["\(completedCount)/\(items.count) done"]
            if activeCount > 0 {
              statusParts.append("\(activeCount) active")
            }
            statsLabel.text = statusParts.joined(separator: " · ")
            statsLabel.isHidden = false
          } else if model.isInProgress {
            statsLabel.text = "Syncing..."
            statsLabel.isHidden = false
          } else {
            statsLabel.isHidden = true
          }
          statsLabel.textColor = EL.textTertiary

        case let .mcp(server, displayTool, subtitle, _, _):
          titleLabel.attributedText = nil
          titleLabel.text = displayTool
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.isHidden = subtitle == nil
          subtitleLabel.text = subtitle
          statsLabel.isHidden = false
          statsLabel.text = server

        case let .webFetch(domain, _, _, _):
          titleLabel.attributedText = nil
          titleLabel.text = "WebFetch"
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.isHidden = false
          subtitleLabel.text = domain
          statsLabel.isHidden = true

        case let .webSearch(query, _, _):
          titleLabel.attributedText = nil
          titleLabel.text = "WebSearch"
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.isHidden = false
          subtitleLabel.text = query
          statsLabel.isHidden = true

        case let .generic(toolName, _, _):
          titleLabel.attributedText = nil
          titleLabel.text = toolName
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.isHidden = true
          statsLabel.isHidden = true
      }

      // Layout title + subtitle
      let hasSubtitle = !subtitleLabel.isHidden
      let titleWidth = max(60, rightEdge - leftEdge)
      if hasSubtitle {
        titleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad, width: titleWidth, height: 18)
        subtitleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad + 18, width: titleWidth, height: 16)
      } else {
        // For bash commands, use measured wrapped height
        if case .bash = model.content {
          let titleH = headerH - EL.headerVPad * 2
          titleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad, width: titleWidth, height: max(18, titleH))
        } else {
          titleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad + 4, width: titleWidth, height: 18)
        }
      }

      // Stats (right-aligned)
      if !statsLabel.isHidden {
        statsLabel.sizeToFit()
        let statsW = statsLabel.frame.width
        let statsX = cardWidth - EL
          .headerHPad - 12 - 8 - (durationLabel.isHidden ? 0 : durationLabel.frame.width + 8) - statsW
        statsLabel.frame = CGRect(x: statsX, y: EL.headerVPad + 2, width: statsW, height: 16)
      }
    }

    private func configureEditStats(additions: Int, deletions: Int, cardWidth: CGFloat) {
      subtitleLabel.isHidden = (subtitleLabel.text ?? "").isEmpty

      let leftEdge = EL.accentBarWidth + EL.headerHPad + 20 + 8
      let rightEdge = cardWidth - EL.headerHPad - 60

      titleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad, width: rightEdge - leftEdge, height: 18)
      if !subtitleLabel.isHidden {
        subtitleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad + 20, width: rightEdge - leftEdge, height: 14)
      }

      var parts: [String] = []
      if deletions > 0 { parts.append("−\(deletions)") }
      if additions > 0 { parts.append("+\(additions)") }
      if !parts.isEmpty {
        statsLabel.isHidden = false
        statsLabel.text = parts.joined(separator: " ")
        statsLabel.textColor = additions > 0 ? EL.addedAccentColor : EL.removedAccentColor
      } else {
        statsLabel.isHidden = true
      }
    }

    // ── Content Builders ──

    private func buildContent(model: NativeExpandedToolModel, width: CGFloat) {
      switch model.content {
        case let .bash(_, input, output):
          buildGenericContent(input: input, output: output, width: width)
        case let .edit(_, _, _, _, lines, isWriteNew):
          buildEditContent(lines: lines, isWriteNew: isWriteNew, width: width)
        case let .read(_, _, language, lines):
          buildReadContent(lines: lines, language: language, width: width)
        case let .glob(_, grouped):
          buildGlobContent(grouped: grouped, width: width)
        case let .grep(_, grouped):
          buildGrepContent(grouped: grouped, width: width)
        case let .task(_, _, _, output, _):
          buildTextOutputContent(output: output, width: width)
        case let .todo(_, _, items, output):
          buildTodoContent(items: items, output: output, width: width)
        case let .mcp(_, _, _, input, output):
          buildGenericContent(input: input, output: output, width: width)
        case let .webFetch(_, _, input, output):
          buildGenericContent(input: input, output: output, width: width)
        case let .webSearch(_, input, output):
          buildGenericContent(input: input, output: output, width: width)
        case let .generic(toolName, input, output):
          buildGenericContent(toolName: toolName, input: input, output: output, width: width)
      }
    }

    // ── Text Output (bash, mcp, webfetch, websearch, task) ──

    private func buildTextOutputContent(output: String?, width: CGFloat) {
      guard let output, !output.isEmpty else { return }

      let lines = output.components(separatedBy: "\n")
      let textWidth = width - EL.headerHPad * 2
      var y: CGFloat = EL.sectionPadding + EL.contentTopPad

      for line in lines {
        let text = line.isEmpty ? " " : line
        let label = makeCodeLabel(text, color: EL.textSecondary)
        let labelH = EL.measuredTextHeight(text, font: EL.codeFont, maxWidth: textWidth)
        label.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: labelH)
        contentContainer.addSubview(label)
        y += labelH
      }
    }

    // ── Edit (diff lines) ──

    private func buildEditContent(lines: [DiffLine], isWriteNew: Bool, width: CGFloat) {
      var y: CGFloat = 0

      if isWriteNew {
        let header = UILabel()
        header.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .bold)
        header.textColor = EL.addedAccentColor
        header.text = "NEW FILE (\(lines.count) lines)"
        header.frame = CGRect(x: EL.headerHPad, y: y + 6, width: width - EL.headerHPad * 2, height: 16)
        contentContainer.addSubview(header)

        let headerBg = UIView(frame: CGRect(x: 0, y: y, width: width, height: 28))
        headerBg.backgroundColor = EL.addedBgColor.withAlphaComponent(0.3)
        contentContainer.insertSubview(headerBg, at: 0)
        y += 28
      }

      let gutterMetrics = EL.diffGutterMetrics(for: lines)
      let codeX = gutterMetrics.codeX
      let codeAvailW = width - codeX - EL.diffContentTrailingPad
      let diffFont = EL.diffContentFont

      // Measure widest line for scroll content
      var maxTextWidth: CGFloat = 0
      for line in lines {
        let text = line.content.isEmpty ? " " : line.content
        let w = ceil((text as NSString).size(withAttributes: [.font: diffFont as Any]).width)
        maxTextWidth = max(maxTextWidth, w)
      }
      let scrollContentW = max(codeAvailW, maxTextWidth + 8)

      // Horizontal scroll view for code content
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

        // Row background (full card width, in contentContainer)
        let rowBg = UIView(frame: CGRect(x: 0, y: y + rowY, width: width, height: EL.diffLineHeight))
        rowBg.backgroundColor = bgColor
        contentContainer.addSubview(rowBg)

        // Line numbers (in contentContainer — stay fixed)
        if let oldLineNumberX = gutterMetrics.oldLineNumberX, let num = line.oldLineNum {
          let numLabel = makeLineNumLabel("\(num)")
          numLabel.textAlignment = .right
          numLabel.frame = CGRect(
            x: oldLineNumberX,
            y: y + rowY + 2,
            width: gutterMetrics.oldLineNumberWidth,
            height: 18
          )
          contentContainer.addSubview(numLabel)
        }
        if let newLineNumberX = gutterMetrics.newLineNumberX, let num = line.newLineNum {
          let numLabel = makeLineNumLabel("\(num)")
          numLabel.textAlignment = .right
          numLabel.frame = CGRect(
            x: newLineNumberX,
            y: y + rowY + 2,
            width: gutterMetrics.newLineNumberWidth,
            height: 18
          )
          contentContainer.addSubview(numLabel)
        }

        // Prefix (in contentContainer — stays fixed)
        let prefixLabel = UILabel()
        prefixLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.code, weight: .bold)
        prefixLabel.textColor = prefixColor
        prefixLabel.text = line.prefix
        prefixLabel.frame = CGRect(
          x: gutterMetrics.prefixX,
          y: y + rowY + 1,
          width: EL.diffPrefixWidth,
          height: 20
        )
        contentContainer.addSubview(prefixLabel)

        // Code content (in scroll view — scrolls horizontally)
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

      contentContainer.addSubview(scrollView)
    }

    // ── Read (line-numbered code) ──

    private func buildReadContent(lines: [String], language: String, width: CGFloat) {
      let gutterMetrics = EL.readGutterMetrics(lineCount: lines.count)
      let codeX = gutterMetrics.codeX
      let codeAvailW = width - codeX - EL.diffContentTrailingPad
      let lang = language.isEmpty ? nil : language
      let y: CGFloat = EL.sectionPadding + EL.contentTopPad

      // Measure widest line for scroll content
      var maxTextWidth: CGFloat = 0
      for line in lines {
        let text = line.isEmpty ? " " : line
        let w = ceil((text as NSString).size(withAttributes: [.font: EL.codeFont as Any]).width)
        maxTextWidth = max(maxTextWidth, w)
      }
      let scrollContentW = max(codeAvailW, maxTextWidth + 8)

      // Horizontal scroll view for code content
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

        // Line number (in contentContainer — stays fixed)
        let numLabel = makeLineNumLabel("\(index + 1)")
        numLabel.textAlignment = .right
        numLabel.frame = CGRect(
          x: gutterMetrics.lineNumberX,
          y: y + rowY,
          width: gutterMetrics.lineNumberWidth,
          height: EL.contentLineHeight
        )
        contentContainer.addSubview(numLabel)

        // Code line (in scroll view — scrolls horizontally)
        let codeLine = UILabel()
        codeLine.attributedText = SyntaxHighlighter.highlightNativeLine(text, language: lang)
        codeLine.lineBreakMode = .byClipping
        codeLine.numberOfLines = 1
        codeLine.frame = CGRect(x: 0, y: rowY, width: scrollContentW, height: EL.contentLineHeight)
        scrollView.addSubview(codeLine)

        rowY += EL.contentLineHeight
      }

      contentContainer.addSubview(scrollView)
    }

    // ── Glob (directory tree) ──

    private func buildGlobContent(grouped: [(dir: String, files: [String])], width: CGFloat) {
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
        contentContainer.addSubview(dirIcon)

        let dirLabel = makeCodeLabel(dirText, color: EL.textSecondary, fontSize: TypeScale.meta, weight: .medium)
        dirLabel.frame = CGRect(x: EL.headerHPad + 18, y: y, width: textWidth - 18, height: dirH)
        contentContainer.addSubview(dirLabel)
        y += dirH + 2

        let fileX = EL.headerHPad + 28
        let fileW = textWidth - 28
        for file in files {
          let filename = file.components(separatedBy: "/").last ?? file
          let fileH = EL.measuredTextHeight(filename, font: fileFont, maxWidth: fileW)
          let fileLabel = makeCodeLabel(filename, color: EL.textTertiary, fontSize: TypeScale.meta)
          fileLabel.frame = CGRect(x: fileX, y: y, width: fileW, height: fileH)
          contentContainer.addSubview(fileLabel)
          y += fileH
        }

        y += 6
      }
    }

    // ── Grep (file-grouped results) ──

    private func buildGrepContent(grouped: [(file: String, matches: [String])], width: CGFloat) {
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
        contentContainer.addSubview(fileLabel)
        y += fileH + 2

        let matchX = EL.headerHPad + 16
        let matchW = textWidth - 16
        for match in matches {
          let matchH = EL.measuredTextHeight(match, font: EL.codeFont, maxWidth: matchW)
          let matchLabel = makeCodeLabel(match, color: EL.textTertiary)
          matchLabel.frame = CGRect(x: matchX, y: y, width: matchW, height: matchH)
          contentContainer.addSubview(matchLabel)
          y += matchH
        }

        y += 6
      }
    }

    // ── Todo (structured checklist) ──

    private func buildTodoContent(items: [NativeTodoItem], output: String?, width: CGFloat) {
      let contentWidth = width - EL.headerHPad * 2
      var y: CGFloat = EL.contentTopPad

      if !items.isEmpty {
        let todoHeader = makeSectionHeader("TODOS")
        todoHeader.frame = CGRect(x: EL.headerHPad, y: y + EL.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(todoHeader)
        y += EL.sectionHeaderHeight + EL.sectionPadding

        for item in items {
          let style = EL.todoStatusStyle(item.status)
          let statusText = item.status.label.uppercased()
          let badgeTextWidth = ceil((statusText as NSString).size(withAttributes: [.font: EL.statsFont as Any]).width)
          let badgeWidth = min(
            EL.todoBadgeMaxWidth,
            max(
              EL.todoBadgeMinWidth,
              badgeTextWidth + EL.todoBadgeSidePadding * 2
            )
          )

          let rowX = EL.headerHPad
          let rowW = contentWidth
          let iconAndGap = EL.todoIconWidth + 8
          let textX = rowX + EL.todoRowHorizontalPadding + iconAndGap
          let badgeX = rowX + rowW - EL.todoRowHorizontalPadding - badgeWidth
          let textW = max(90, badgeX - textX - 8)
          let primaryHeight = EL.measuredTextHeight(
            item.primaryText,
            font: EL.todoTitleFont,
            maxWidth: textW
          )
          let secondaryHeight = item.secondaryText.map {
            EL.measuredTextHeight(
              $0,
              font: EL.todoSecondaryFont,
              maxWidth: textW
            )
          } ?? 0
          let textHeight = primaryHeight + (secondaryHeight > 0 ? 2 + secondaryHeight : 0)
          let rowHeight = max(
            EL.todoBadgeHeight + EL.todoRowVerticalPadding * 2,
            textHeight + EL.todoRowVerticalPadding * 2
          )

          let rowBackground = UIView(frame: CGRect(x: rowX, y: y, width: rowW, height: rowHeight))
          rowBackground.backgroundColor = style.rowBackground
          rowBackground.layer.cornerRadius = 8
          contentContainer.addSubview(rowBackground)

          let icon = UIImageView()
          let iconConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
          icon.image = UIImage(systemName: todoStatusIconName(for: item.status))?.withConfiguration(iconConfig)
          icon.tintColor = style.tint
          icon.frame = CGRect(
            x: rowX + EL.todoRowHorizontalPadding,
            y: y + (rowHeight - 14) / 2,
            width: 14,
            height: 14
          )
          contentContainer.addSubview(icon)

          let primaryLabel = UILabel()
          primaryLabel.font = EL.todoTitleFont
          primaryLabel.textColor = EL.textPrimary
          primaryLabel.lineBreakMode = .byWordWrapping
          primaryLabel.numberOfLines = 0
          primaryLabel.text = item.primaryText
          primaryLabel.frame = CGRect(
            x: textX,
            y: y + EL.todoRowVerticalPadding,
            width: textW,
            height: primaryHeight
          )
          contentContainer.addSubview(primaryLabel)

          if let secondaryText = item.secondaryText {
            let secondaryLabel = UILabel()
            secondaryLabel.font = EL.todoSecondaryFont
            secondaryLabel.textColor = EL.textTertiary
            secondaryLabel.lineBreakMode = .byWordWrapping
            secondaryLabel.numberOfLines = 0
            secondaryLabel.text = secondaryText
            secondaryLabel.frame = CGRect(
              x: textX,
              y: primaryLabel.frame.maxY + 2,
              width: textW,
              height: secondaryHeight
            )
            contentContainer.addSubview(secondaryLabel)
          }

          let badgeHeight = EL.todoBadgeHeight
          let badgeY = y + (rowHeight - badgeHeight) / 2
          let badgeView = UIView(frame: CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight))
          badgeView.backgroundColor = style.badgeBackground
          badgeView.layer.cornerRadius = 6
          contentContainer.addSubview(badgeView)

          let badgeLabel = UILabel()
          badgeLabel.font = EL.statsFont
          badgeLabel.textColor = EL.textPrimary
          badgeLabel.textAlignment = .center
          badgeLabel.text = statusText
          badgeLabel.frame = CGRect(x: 0, y: 3, width: badgeWidth, height: 14)
          badgeView.addSubview(badgeLabel)

          y += rowHeight + EL.todoRowSpacing
        }

        y += EL.sectionPadding
      }

      if let output, !output.isEmpty {
        let outputHeader = makeSectionHeader("RESULT")
        outputHeader.frame = CGRect(x: EL.headerHPad, y: y + EL.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(outputHeader)
        y += EL.sectionHeaderHeight + EL.sectionPadding

        let textWidth = width - EL.headerHPad * 2
        let outputLines = output.components(separatedBy: "\n")
        for line in outputLines {
          let text = line.isEmpty ? " " : line
          let label = makeCodeLabel(text, color: EL.textSecondary)
          let labelH = EL.measuredTextHeight(text, font: EL.codeFont, maxWidth: textWidth)
          label.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: labelH)
          contentContainer.addSubview(label)
          y += labelH
        }
      }
    }

    private func todoStatusIconName(for status: NativeTodoStatus) -> String {
      switch status {
        case .pending: "circle"
        case .inProgress: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
      }
    }

    // ── Generic (input + output) ──

    private func buildGenericContent(toolName: String? = nil, input: String?, output: String?, width: CGFloat) {
      let textWidth = width - EL.headerHPad * 2
      var y: CGFloat = EL.contentTopPad

      buildPayloadSection(title: "INPUT", payload: input, toolName: toolName, textWidth: textWidth, y: &y)
      buildPayloadSection(title: "OUTPUT", payload: output, textWidth: textWidth, y: &y)
    }

    private func buildPayloadSection(
      title: String,
      payload: String?,
      toolName: String? = nil,
      textWidth: CGFloat,
      y: inout CGFloat
    ) {
      guard let payload, !payload.isEmpty else { return }

      let header = makeSectionHeader(title)
      header.frame = CGRect(x: EL.headerHPad, y: y + EL.sectionPadding, width: 80, height: 14)
      contentContainer.addSubview(header)
      y += EL.sectionHeaderHeight + EL.sectionPadding

      if toolName?.lowercased() == "question",
         let questions = EL.askUserQuestionItems(from: payload)
      {
        for (index, question) in questions.enumerated() {
          if let headerText = question.header, !headerText.isEmpty {
            let headerLabel = UILabel()
            headerLabel.font = UIFont.systemFont(ofSize: TypeScale.mini, weight: .bold)
            headerLabel.textColor = EL.textQuaternary
            headerLabel.text = headerText.uppercased()
            headerLabel.numberOfLines = 0
            let headerHeight = EL.measuredTextHeight(headerText, font: UIFont.systemFont(ofSize: TypeScale.mini, weight: .bold), maxWidth: textWidth)
            headerLabel.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: headerHeight)
            contentContainer.addSubview(headerLabel)
            y += headerHeight + 3
          }

          let promptLabel = UILabel()
          promptLabel.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
          promptLabel.textColor = EL.textPrimary
          promptLabel.lineBreakMode = .byWordWrapping
          promptLabel.numberOfLines = 0
          promptLabel.text = question.question
          let promptHeight = EL.measuredTextHeight(question.question, font: UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold), maxWidth: textWidth)
          promptLabel.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: promptHeight)
          contentContainer.addSubview(promptLabel)
          y += promptHeight

          if !question.options.isEmpty {
            y += 6
            for option in question.options {
              let optionLabel = UILabel()
              optionLabel.font = UIFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
              optionLabel.textColor = EL.textSecondary
              optionLabel.numberOfLines = 0
              optionLabel.text = "• \(option.label)"
              let optionHeight = EL.measuredTextHeight("• \(option.label)", font: UIFont.systemFont(ofSize: TypeScale.caption, weight: .medium), maxWidth: textWidth)
              optionLabel.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: optionHeight)
              contentContainer.addSubview(optionLabel)
              y += optionHeight

              if let detail = option.description, !detail.isEmpty {
                let detailLabel = UILabel()
                detailLabel.font = UIFont.systemFont(ofSize: TypeScale.meta, weight: .regular)
                detailLabel.textColor = EL.textTertiary
                detailLabel.lineBreakMode = .byWordWrapping
                detailLabel.numberOfLines = 0
                detailLabel.text = detail
                let detailHeight = EL.measuredTextHeight(detail, font: UIFont.systemFont(ofSize: TypeScale.meta, weight: .regular), maxWidth: textWidth - 14)
                detailLabel.frame = CGRect(x: EL.headerHPad + 14, y: y + 2, width: textWidth - 14, height: detailHeight)
                contentContainer.addSubview(detailLabel)
                y += detailHeight + 2
              }
              y += 5
            }
            y -= 5
          }

          if index < questions.count - 1 {
            y += 8
          }
        }
      } else if let entries = EL.structuredPayloadEntries(from: payload) {
        for entry in entries {
          let label = makePayloadLabel(key: entry.keyPath, value: entry.value)
          let display = "\(entry.keyPath): \(entry.value)"
          let labelH = EL.measuredTextHeight(display, font: EL.codeFont, maxWidth: textWidth)
          label.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: labelH)
          contentContainer.addSubview(label)
          y += labelH
        }
      } else {
        let lines = EL.payloadDisplayLines(from: payload)
        for line in lines {
          let text = line.isEmpty ? " " : line
          let label = makeCodeLabel(text, color: EL.textSecondary)
          let labelH = EL.measuredTextHeight(text, font: EL.codeFont, maxWidth: textWidth)
          label.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: labelH)
          contentContainer.addSubview(label)
          y += labelH
        }
      }

      y += EL.sectionPadding
    }

    // MARK: - Label Factories

    private func makeCodeLabel(
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

    private func makePayloadLabel(key: String, value: String) -> UILabel {
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
    }

    private func makeLineNumLabel(_ text: String) -> UILabel {
      let label = UILabel()
      label.font = EL.lineNumFont
      label.textColor = EL.textQuaternary
      label.text = text
      return label
    }

    private func makeFooterLabel(_ text: String, fontSize: CGFloat = TypeScale.micro) -> UILabel {
      let label = UILabel()
      label.font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
      label.textColor = EL.textQuaternary
      label.text = text
      return label
    }

    private func makeSectionHeader(_ text: String) -> UILabel {
      let label = UILabel()
      let attrs: [NSAttributedString.Key: Any] = [
        .kern: 0.8,
        .font: EL.sectionLabelFont,
        .foregroundColor: EL.textQuaternary,
      ]
      label.attributedText = NSAttributedString(string: text, attributes: attrs)
      return label
    }
  }

  // swiftlint:enable type_body_length file_length

#endif
