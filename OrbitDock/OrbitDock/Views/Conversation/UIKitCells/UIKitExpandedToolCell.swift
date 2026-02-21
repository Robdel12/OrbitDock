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
    private let contentContainer = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    // ── State ──

    private var model: NativeExpandedToolModel?
    var onCollapse: ((String) -> Void)?

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

      // Content container
      contentContainer.clipsToBounds = true
      cardBackground.addSubview(contentContainer)

      // Header tap gesture
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleHeaderTap(_:)))
      cardBackground.addGestureRecognizer(tap)
    }

    @objc private func handleHeaderTap(_ gesture: UITapGestureRecognizer) {
      let location = gesture.location(in: cardBackground)
      let headerHeight = EL.headerHeight(for: model)
      if location.y <= headerHeight, let messageID = model?.messageID {
        onCollapse?(messageID)
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onCollapse = nil
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
        spinner.frame = CGRect(
          x: cardWidth - EL.headerHPad - 16,
          y: EL.headerVPad + 2,
          width: 16, height: 16
        )
      } else {
        spinner.stopAnimating()
      }

      // Collapse chevron
      if !model.isInProgress {
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
      if let dur = model.duration, !model.isInProgress {
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
        case let .bash(command, _):
          let bashColor: UIColor = model.hasError ? UIColor(Color.statusError) : model.toolColor
          let bashAttr = NSMutableAttributedString()
          bashAttr.append(NSAttributedString(
            string: "$ ",
            attributes: [
              .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .bold),
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
          titleLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
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

        case let .mcp(server, displayTool, subtitle, _):
          titleLabel.attributedText = nil
          titleLabel.text = displayTool
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.isHidden = subtitle == nil
          subtitleLabel.text = subtitle
          statsLabel.isHidden = false
          statsLabel.text = server

        case let .webFetch(domain, _, _):
          titleLabel.attributedText = nil
          titleLabel.text = "WebFetch"
          titleLabel.font = EL.headerFont
          titleLabel.textColor = model.toolColor
          subtitleLabel.isHidden = false
          subtitleLabel.text = domain
          statsLabel.isHidden = true

        case let .webSearch(query, _):
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
        case let .bash(_, output):
          buildTextOutputContent(output: output, maxLines: EL.bashMaxLines, width: width)
        case let .edit(_, _, _, _, lines, isWriteNew):
          buildEditContent(lines: lines, isWriteNew: isWriteNew, width: width)
        case let .read(_, _, language, lines):
          buildReadContent(lines: lines, language: language, width: width)
        case let .glob(_, grouped):
          buildGlobContent(grouped: grouped, width: width)
        case let .grep(_, grouped):
          buildGrepContent(grouped: grouped, width: width)
        case let .task(_, _, _, output, _):
          buildTextOutputContent(output: output, maxLines: EL.genericMaxLines, width: width)
        case let .mcp(_, _, _, output):
          buildTextOutputContent(output: output, maxLines: EL.genericMaxLines, width: width)
        case let .webFetch(_, _, output):
          buildTextOutputContent(output: output, maxLines: EL.genericMaxLines, width: width)
        case let .webSearch(_, output):
          buildTextOutputContent(output: output, maxLines: EL.genericMaxLines, width: width)
        case let .generic(_, input, output):
          buildGenericContent(input: input, output: output, width: width)
      }
    }

    // ── Text Output (bash, mcp, webfetch, websearch, task) ──

    private func buildTextOutputContent(output: String?, maxLines: Int, width: CGFloat) {
      guard let output, !output.isEmpty else { return }

      let lines = output.components(separatedBy: "\n")
      let displayLines = Array(lines.prefix(maxLines))
      let truncated = lines.count > maxLines
      let textWidth = width - EL.headerHPad * 2
      var y: CGFloat = EL.sectionPadding + EL.contentTopPad

      for line in displayLines {
        let text = line.isEmpty ? " " : line
        let label = makeCodeLabel(text, color: EL.textSecondary)
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        let labelH = EL.measuredTextHeight(text, font: EL.codeFont, maxWidth: textWidth)
        label.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: labelH)
        contentContainer.addSubview(label)
        y += labelH
      }

      if truncated {
        let footer = makeFooterLabel("... +\(lines.count - maxLines) more lines")
        footer.frame = CGRect(x: EL.headerHPad, y: y + 4, width: textWidth, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Edit (diff lines) ──

    private func buildEditContent(lines: [DiffLine], isWriteNew: Bool, width: CGFloat) {
      let displayLines = Array(lines.prefix(EL.editMaxLines))
      let truncated = lines.count > EL.editMaxLines
      var y: CGFloat = 0

      if isWriteNew {
        let header = UILabel()
        header.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        header.textColor = EL.addedAccentColor
        header.text = "NEW FILE (\(lines.count) lines)"
        header.frame = CGRect(x: EL.headerHPad, y: y + 6, width: width - EL.headerHPad * 2, height: 16)
        contentContainer.addSubview(header)

        let headerBg = UIView(frame: CGRect(x: 0, y: y, width: width, height: 28))
        headerBg.backgroundColor = EL.addedBgColor.withAlphaComponent(0.3)
        contentContainer.insertSubview(headerBg, at: 0)
        y += 28
      }

      for line in displayLines {
        let bgColor: UIColor
        let prefixColor: UIColor
        switch line.type {
          case .added:
            bgColor = EL.addedBgColor
            prefixColor = EL.addedAccentColor
          case .removed:
            bgColor = EL.removedBgColor
            prefixColor = EL.removedAccentColor
          case .context:
            bgColor = .clear
            prefixColor = .clear
        }

        let rowBg = UIView(frame: CGRect(x: 0, y: y, width: width, height: EL.diffLineHeight))
        rowBg.backgroundColor = bgColor
        contentContainer.addSubview(rowBg)

        if let num = line.oldLineNum {
          let numLabel = makeLineNumLabel("\(num)")
          numLabel.textAlignment = .right
          numLabel.frame = CGRect(x: 4, y: y + 2, width: 32, height: 18)
          contentContainer.addSubview(numLabel)
        }

        if let num = line.newLineNum {
          let numLabel = makeLineNumLabel("\(num)")
          numLabel.textAlignment = .right
          numLabel.frame = CGRect(x: 40, y: y + 2, width: 32, height: 18)
          contentContainer.addSubview(numLabel)
        }

        let prefixLabel = UILabel()
        prefixLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        prefixLabel.textColor = prefixColor
        prefixLabel.text = line.prefix
        prefixLabel.frame = CGRect(x: 78, y: y + 1, width: 16, height: 20)
        contentContainer.addSubview(prefixLabel)

        let contentLabel = makeCodeLabel(
          line.content.isEmpty ? " " : line.content,
          color: EL.textPrimary,
          fontSize: 12
        )
        contentLabel.frame = CGRect(x: 96, y: y + 2, width: width - 110, height: 18)
        contentContainer.addSubview(contentLabel)

        y += EL.diffLineHeight
      }

      if truncated {
        let footer = makeFooterLabel("... +\(lines.count - EL.editMaxLines) more changed lines", fontSize: 11)
        footer.frame = CGRect(x: EL.headerHPad, y: y + 6, width: width - EL.headerHPad * 2, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Read (line-numbered code) ──

    private func buildReadContent(lines: [String], language: String, width: CGFloat) {
      let displayLines = Array(lines.prefix(EL.readMaxLines))
      let truncated = lines.count > EL.readMaxLines
      let maxLineNumWidth = CGFloat("\(lines.count)".count) * 8 + 10
      let codeX = maxLineNumWidth + 12
      let codeWidth = width - codeX - EL.headerHPad
      var y: CGFloat = EL.sectionPadding + EL.contentTopPad

      for (index, line) in displayLines.enumerated() {
        let text = line.isEmpty ? " " : line
        let lineH = EL.measuredTextHeight(text, font: EL.codeFont, maxWidth: codeWidth)

        let numLabel = makeLineNumLabel("\(index + 1)")
        numLabel.textAlignment = .right
        numLabel.frame = CGRect(x: 4, y: y, width: maxLineNumWidth, height: lineH)
        contentContainer.addSubview(numLabel)

        let codeLine = UILabel()
        let lang = language.isEmpty ? nil : language
        codeLine.attributedText = NativeSyntaxHighlighter.highlightLine(text, language: lang)
        codeLine.lineBreakMode = .byCharWrapping
        codeLine.numberOfLines = 0
        codeLine.frame = CGRect(x: codeX, y: y, width: codeWidth, height: lineH)
        contentContainer.addSubview(codeLine)

        y += lineH
      }

      if truncated {
        let footer = makeFooterLabel("... +\(lines.count - EL.readMaxLines) more lines")
        footer.frame = CGRect(x: EL.headerHPad, y: y + 4, width: width - EL.headerHPad * 2, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Glob (directory tree) ──

    private func buildGlobContent(grouped: [(dir: String, files: [String])], width: CGFloat) {
      let displayDirs = Array(grouped.prefix(EL.globMaxDirs))
      let truncated = grouped.count > EL.globMaxDirs
      let textWidth = width - EL.headerHPad * 2
      let dirFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
      let fileFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      var y: CGFloat = EL.sectionPadding + EL.contentTopPad

      for (dir, files) in displayDirs {
        let dirText = "\(dir == "." ? "(root)" : dir) (\(files.count))"
        let dirH = EL.measuredTextHeight(dirText, font: dirFont, maxWidth: textWidth - 18)

        let dirIcon = UIImageView()
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        dirIcon.image = UIImage(systemName: "folder.fill")?.withConfiguration(iconConfig)
        dirIcon.tintColor = UIColor(Color.toolWrite)
        dirIcon.frame = CGRect(x: EL.headerHPad, y: y + 2, width: 14, height: 14)
        contentContainer.addSubview(dirIcon)

        let dirLabel = makeCodeLabel(dirText, color: EL.textSecondary, fontSize: 11, weight: .medium)
        dirLabel.numberOfLines = 0
        dirLabel.lineBreakMode = .byCharWrapping
        dirLabel.frame = CGRect(x: EL.headerHPad + 18, y: y, width: textWidth - 18, height: dirH)
        contentContainer.addSubview(dirLabel)
        y += dirH + 2

        let displayFiles = Array(files.prefix(EL.globMaxFilesPerDir))
        let fileX = EL.headerHPad + 28
        let fileW = textWidth - 28
        for file in displayFiles {
          let filename = file.components(separatedBy: "/").last ?? file
          let fileH = EL.measuredTextHeight(filename, font: fileFont, maxWidth: fileW)
          let fileLabel = makeCodeLabel(filename, color: EL.textTertiary, fontSize: 11)
          fileLabel.numberOfLines = 0
          fileLabel.lineBreakMode = .byCharWrapping
          fileLabel.frame = CGRect(x: fileX, y: y, width: fileW, height: fileH)
          contentContainer.addSubview(fileLabel)
          y += fileH
        }

        if files.count > EL.globMaxFilesPerDir {
          let more = makeFooterLabel("... +\(files.count - EL.globMaxFilesPerDir) more")
          more.frame = CGRect(x: EL.headerHPad + 28, y: y, width: fileW, height: 14)
          contentContainer.addSubview(more)
          y += 16
        }

        y += 6
      }

      if truncated {
        let footer = makeFooterLabel("... +\(grouped.count - EL.globMaxDirs) more directories")
        footer.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Grep (file-grouped results) ──

    private func buildGrepContent(grouped: [(file: String, matches: [String])], width: CGFloat) {
      let displayFiles = Array(grouped.prefix(EL.grepMaxFiles))
      let truncated = grouped.count > EL.grepMaxFiles
      let textWidth = width - EL.headerHPad * 2
      let fileFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
      var y: CGFloat = EL.sectionPadding + EL.contentTopPad

      for (file, matches) in displayFiles {
        let shortPath = file.components(separatedBy: "/").suffix(3).joined(separator: "/")
        let matchSuffix = matches.isEmpty ? "" : " (\(matches.count))"
        let fileText = shortPath + matchSuffix
        let fileH = EL.measuredTextHeight(fileText, font: fileFont, maxWidth: textWidth)
        let fileLabel = makeCodeLabel(fileText, color: EL.textPrimary, fontSize: 11, weight: .medium)
        fileLabel.numberOfLines = 0
        fileLabel.lineBreakMode = .byCharWrapping
        fileLabel.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: fileH)
        contentContainer.addSubview(fileLabel)
        y += fileH + 2

        let displayMatches = Array(matches.prefix(EL.grepMaxMatchesPerFile))
        let matchX = EL.headerHPad + 16
        let matchW = textWidth - 16
        for match in displayMatches {
          let matchH = EL.measuredTextHeight(match, font: EL.codeFont, maxWidth: matchW)
          let matchLabel = makeCodeLabel(match, color: EL.textTertiary)
          matchLabel.numberOfLines = 0
          matchLabel.lineBreakMode = .byCharWrapping
          matchLabel.frame = CGRect(x: matchX, y: y, width: matchW, height: matchH)
          contentContainer.addSubview(matchLabel)
          y += matchH
        }

        if matches.count > EL.grepMaxMatchesPerFile {
          let more = makeFooterLabel("... +\(matches.count - EL.grepMaxMatchesPerFile) more")
          more.frame = CGRect(x: matchX, y: y, width: matchW, height: 14)
          contentContainer.addSubview(more)
          y += 16
        }

        y += 6
      }

      if truncated {
        let footer = makeFooterLabel("... +\(grouped.count - EL.grepMaxFiles) more files")
        footer.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Generic (input + output) ──

    private func buildGenericContent(input: String?, output: String?, width: CGFloat) {
      let textWidth = width - EL.headerHPad * 2
      var y: CGFloat = EL.contentTopPad

      if let input, !input.isEmpty {
        let inputHeader = makeSectionHeader("INPUT")
        inputHeader.frame = CGRect(x: EL.headerHPad, y: y + EL.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(inputHeader)
        y += EL.sectionHeaderHeight + EL.sectionPadding

        let inputLines = input.components(separatedBy: "\n")
        let displayLines = Array(inputLines.prefix(EL.genericMaxLines))
        for line in displayLines {
          let text = line.isEmpty ? " " : line
          let label = makeCodeLabel(text, color: EL.textSecondary)
          label.numberOfLines = 0
          label.lineBreakMode = .byCharWrapping
          let labelH = EL.measuredTextHeight(text, font: EL.codeFont, maxWidth: textWidth)
          label.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: labelH)
          contentContainer.addSubview(label)
          y += labelH
        }
        y += EL.sectionPadding
      }

      if let output, !output.isEmpty {
        let outputHeader = makeSectionHeader("OUTPUT")
        outputHeader.frame = CGRect(x: EL.headerHPad, y: y + EL.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(outputHeader)
        y += EL.sectionHeaderHeight + EL.sectionPadding

        let outputLines = output.components(separatedBy: "\n")
        let displayLines = Array(outputLines.prefix(EL.genericMaxLines))
        for line in displayLines {
          let text = line.isEmpty ? " " : line
          let label = makeCodeLabel(text, color: EL.textSecondary)
          label.numberOfLines = 0
          label.lineBreakMode = .byCharWrapping
          let labelH = EL.measuredTextHeight(text, font: EL.codeFont, maxWidth: textWidth)
          label.frame = CGRect(x: EL.headerHPad, y: y, width: textWidth, height: labelH)
          contentContainer.addSubview(label)
          y += labelH
        }

        if outputLines.count > EL.genericMaxLines {
          let footer = makeFooterLabel("... +\(outputLines.count - EL.genericMaxLines) more lines")
          footer.frame = CGRect(x: EL.headerHPad, y: y + 4, width: textWidth, height: 16)
          contentContainer.addSubview(footer)
        }
      }
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
      label.lineBreakMode = .byTruncatingTail
      label.numberOfLines = 1
      label.text = text
      return label
    }

    private func makeLineNumLabel(_ text: String) -> UILabel {
      let label = UILabel()
      label.font = EL.lineNumFont
      label.textColor = EL.textQuaternary
      label.text = text
      return label
    }

    private func makeFooterLabel(_ text: String, fontSize: CGFloat = 10) -> UILabel {
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
