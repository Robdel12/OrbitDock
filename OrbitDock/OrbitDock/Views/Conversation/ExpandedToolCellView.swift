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

// MARK: - Tool Content Enum

enum NativeToolContent {
  case bash(command: String, output: String?)
  case edit(filename: String?, path: String?, additions: Int, deletions: Int, lines: [DiffLine], isWriteNew: Bool)
  case read(filename: String?, path: String?, language: String, lines: [String])
  case glob(pattern: String, grouped: [(dir: String, files: [String])])
  case grep(pattern: String, grouped: [(file: String, matches: [String])])
  case task(agentLabel: String, agentColor: PlatformColor, description: String, output: String?, isComplete: Bool)
  case mcp(server: String, displayTool: String, subtitle: String?, output: String?)
  case webFetch(domain: String, url: String, output: String?)
  case webSearch(query: String, output: String?)
  case generic(toolName: String, input: String?, output: String?)
}

// MARK: - Model

struct NativeExpandedToolModel {
  let messageID: String
  let toolColor: PlatformColor
  let iconName: String
  let hasError: Bool
  let isInProgress: Bool
  let duration: String?
  let content: NativeToolContent
}

// MARK: - Cell View

// MARK: - Shared Height Calculation

enum ExpandedToolLayout {
  static let laneHorizontalInset = ConversationLayout.laneHorizontalInset
  static let accentBarWidth: CGFloat = EdgeBar.width
  static let headerHPad: CGFloat = 14
  static let headerVPad: CGFloat = 10
  static let iconSize: CGFloat = 14
  static let cornerRadius: CGFloat = Radius.lg
  static let contentLineHeight: CGFloat = 18
  static let diffLineHeight: CGFloat = 22
  static let sectionHeaderHeight: CGFloat = 24
  static let sectionPadding: CGFloat = 10
  static let truncationFooterHeight: CGFloat = 26
  static let contentTopPad: CGFloat = 6
  static let bottomPadding: CGFloat = 10

  // Max display lines per type
  static let bashMaxLines = 12
  static let editMaxLines = 24
  static let readMaxLines = 30
  static let globMaxDirs = 5
  static let globMaxFilesPerDir = 8
  static let grepMaxFiles = 5
  static let grepMaxMatchesPerFile = 5
  static let genericMaxLines = 12

  // Card colors
  static let bgColor = PlatformColor.calibrated(red: 0.06, green: 0.06, blue: 0.08, alpha: 0.85)
  static let contentBgColor = PlatformColor.calibrated(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
  static let headerDividerColor = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.06)

  static let addedBgColor = PlatformColor.calibrated(red: 0.15, green: 0.32, blue: 0.18, alpha: 0.6)
  static let removedBgColor = PlatformColor.calibrated(red: 0.35, green: 0.14, blue: 0.14, alpha: 0.6)
  static let addedAccentColor = PlatformColor.calibrated(red: 0.4, green: 0.95, blue: 0.5, alpha: 1)
  static let removedAccentColor = PlatformColor.calibrated(red: 1.0, green: 0.5, blue: 0.5, alpha: 1)

  // Text colors
  static let textPrimary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.92)
  static let textSecondary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.65)
  static let textTertiary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.50)
  static let textQuaternary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.38)

  // Fonts
  static let codeFont = PlatformFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
  static let headerFont = PlatformFont.systemFont(ofSize: 13, weight: .semibold)
  static let subtitleFont = PlatformFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  static let lineNumFont = PlatformFont.monospacedSystemFont(ofSize: 10, weight: .medium)
  static let sectionLabelFont = PlatformFont.systemFont(ofSize: 9, weight: .bold)
  static let statsFont = PlatformFont.monospacedSystemFont(ofSize: 10, weight: .medium)

  // MARK: - Text Measurement

  /// Measure the height a text string needs when allowed to wrap at `maxWidth`.
  /// Returns at least `contentLineHeight` so empty/short lines keep consistent spacing.
  static func measuredTextHeight(_ text: String, font: PlatformFont, maxWidth: CGFloat) -> CGFloat {
    guard maxWidth > 0 else { return contentLineHeight }
    let constraintSize = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
    let rect = (text as NSString).boundingRect(
      with: constraintSize,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font],
      context: nil
    )
    return max(contentLineHeight, ceil(rect.height))
  }

  /// Available width for content text inside the card (after horizontal padding).
  static func contentTextWidth(cardWidth: CGFloat) -> CGFloat {
    cardWidth - headerHPad * 2
  }

  // MARK: - Height Calculation

  static func headerHeight(for model: NativeExpandedToolModel?, cardWidth: CGFloat = 0) -> CGFloat {
    guard let model else { return 40 }
    switch model.content {
      case let .bash(command, _):
        guard cardWidth > 0 else { return 40 }
        let leftEdge: CGFloat = accentBarWidth + headerHPad + 20 + 8
        let rightEdge: CGFloat = cardWidth - headerHPad - 12 - 8 - 60
        let titleWidth = max(60, rightEdge - leftEdge)
        let bashFont = PlatformFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let titleH = measuredTextHeight("$ " + command, font: bashFont, maxWidth: titleWidth)
        return max(40, headerVPad + titleH + headerVPad)
      case .edit, .read, .glob, .grep, .mcp, .task:
        return 48
      default:
        return 40
    }
  }

  static func contentHeight(for model: NativeExpandedToolModel, cardWidth: CGFloat = 0) -> CGFloat {
    switch model.content {
      case let .bash(_, output):
        return textOutputHeight(output: output, maxLines: bashMaxLines, cardWidth: cardWidth)
      case let .edit(_, _, _, _, lines, isWriteNew):
        let displayCount = min(lines.count, editMaxLines)
        let writeHeaderH: CGFloat = isWriteNew ? 28 : 0
        let truncH: CGFloat = lines.count > editMaxLines ? truncationFooterHeight : 0
        return writeHeaderH + CGFloat(displayCount) * diffLineHeight + truncH
      case let .read(_, _, _, lines):
        return readHeight(lines: lines, cardWidth: cardWidth)
      case let .glob(_, grouped):
        return globHeight(grouped: grouped, cardWidth: cardWidth)
      case let .grep(_, grouped):
        return grepHeight(grouped: grouped, cardWidth: cardWidth)
      case let .task(_, _, _, output, _):
        return textOutputHeight(output: output, maxLines: genericMaxLines, cardWidth: cardWidth)
      case let .mcp(_, _, _, output):
        return textOutputHeight(output: output, maxLines: genericMaxLines, cardWidth: cardWidth)
      case let .webFetch(_, _, output):
        return textOutputHeight(output: output, maxLines: genericMaxLines, cardWidth: cardWidth)
      case let .webSearch(_, output):
        return textOutputHeight(output: output, maxLines: genericMaxLines, cardWidth: cardWidth)
      case let .generic(_, input, output):
        return genericHeight(input: input, output: output, cardWidth: cardWidth)
    }
  }

  static func requiredHeight(for width: CGFloat, model: NativeExpandedToolModel) -> CGFloat {
    let cardWidth = width - laneHorizontalInset * 2
    let h = headerHeight(for: model, cardWidth: cardWidth)
    let c = contentHeight(for: model, cardWidth: cardWidth)
    return h + c + (c > 0 ? bottomPadding : 0)
  }

  static func textOutputHeight(output: String?, maxLines: Int, cardWidth: CGFloat = 0) -> CGFloat {
    guard let output, !output.isEmpty else { return 0 }
    let lines = output.components(separatedBy: "\n")
    let displayLines = Array(lines.prefix(maxLines))
    let truncH: CGFloat = lines.count > maxLines ? truncationFooterHeight : 0
    let textWidth = contentTextWidth(cardWidth: cardWidth)

    var h: CGFloat = sectionPadding + contentTopPad
    if textWidth > 0 {
      for line in displayLines {
        let text = line.isEmpty ? " " : line
        h += measuredTextHeight(text, font: codeFont, maxWidth: textWidth)
      }
    } else {
      h += CGFloat(displayLines.count) * contentLineHeight
    }
    h += truncH + sectionPadding
    return h
  }

  static func readHeight(lines: [String], cardWidth: CGFloat) -> CGFloat {
    let displayLines = Array(lines.prefix(readMaxLines))
    let truncH: CGFloat = lines.count > readMaxLines ? truncationFooterHeight : 0
    let maxLineNumWidth = CGFloat("\(lines.count)".count) * 8 + 10
    let codeX = maxLineNumWidth + 12
    let textWidth = cardWidth - codeX - headerHPad

    var h: CGFloat = sectionPadding + contentTopPad
    if textWidth > 0 {
      for line in displayLines {
        let text = line.isEmpty ? " " : line
        h += measuredTextHeight(text, font: codeFont, maxWidth: textWidth)
      }
    } else {
      h += CGFloat(displayLines.count) * contentLineHeight
    }
    h += truncH + sectionPadding
    return h
  }

  static func globHeight(grouped: [(dir: String, files: [String])], cardWidth: CGFloat = 0) -> CGFloat {
    let displayDirs = Array(grouped.prefix(globMaxDirs))
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    let fileTextWidth = textWidth > 0 ? textWidth - 28 : 0
    let dirFont = PlatformFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    let fileFont = PlatformFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    var h: CGFloat = sectionPadding + contentTopPad
    for (dir, files) in displayDirs {
      let dirText = "\(dir == "." ? "(root)" : dir) (\(files.count))"
      if textWidth > 0 {
        h += measuredTextHeight(dirText, font: dirFont, maxWidth: textWidth - 18)
      } else {
        h += 20
      }

      let displayFiles = Array(files.prefix(globMaxFilesPerDir))
      for file in displayFiles {
        let filename = file.components(separatedBy: "/").last ?? file
        if fileTextWidth > 0 {
          h += measuredTextHeight(filename, font: fileFont, maxWidth: fileTextWidth)
        } else {
          h += contentLineHeight
        }
      }
      if files.count > globMaxFilesPerDir { h += 16 }
      h += 6
    }
    if grouped.count > globMaxDirs { h += 20 }
    return h
  }

  static func grepHeight(grouped: [(file: String, matches: [String])], cardWidth: CGFloat = 0) -> CGFloat {
    let displayFiles = Array(grouped.prefix(grepMaxFiles))
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    let matchTextWidth = textWidth > 0 ? textWidth - 16 : 0
    let fileFont = PlatformFont.monospacedSystemFont(ofSize: 11, weight: .medium)

    var h: CGFloat = sectionPadding + contentTopPad
    for (file, matches) in displayFiles {
      let shortPath = file.components(separatedBy: "/").suffix(3).joined(separator: "/")
      let matchSuffix = matches.isEmpty ? "" : " (\(matches.count))"
      if textWidth > 0 {
        h += measuredTextHeight(shortPath + matchSuffix, font: fileFont, maxWidth: textWidth)
        h += 2 // gap after file header
      } else {
        h += 20
      }

      let displayMatches = Array(matches.prefix(grepMaxMatchesPerFile))
      for match in displayMatches {
        if matchTextWidth > 0 {
          h += measuredTextHeight(match, font: codeFont, maxWidth: matchTextWidth)
        } else {
          h += contentLineHeight
        }
      }
      if matches.count > grepMaxMatchesPerFile { h += 16 }
      h += 6
    }
    if grouped.count > grepMaxFiles { h += 20 }
    return h
  }

  static func genericHeight(input: String?, output: String?, cardWidth: CGFloat = 0) -> CGFloat {
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    var h: CGFloat = contentTopPad

    if let input, !input.isEmpty {
      let inputLines = input.components(separatedBy: "\n")
      let displayLines = Array(inputLines.prefix(genericMaxLines))
      h += sectionPadding + sectionHeaderHeight
      if textWidth > 0 {
        for line in displayLines {
          h += measuredTextHeight(line.isEmpty ? " " : line, font: codeFont, maxWidth: textWidth)
        }
      } else {
        h += CGFloat(displayLines.count) * contentLineHeight
      }
      h += sectionPadding
    }

    if let output, !output.isEmpty {
      let outputLines = output.components(separatedBy: "\n")
      let displayLines = Array(outputLines.prefix(genericMaxLines))
      let truncH: CGFloat = outputLines.count > genericMaxLines ? truncationFooterHeight : 0
      h += sectionPadding + sectionHeaderHeight
      if textWidth > 0 {
        for line in displayLines {
          h += measuredTextHeight(line.isEmpty ? " " : line, font: codeFont, maxWidth: textWidth)
        }
      } else {
        h += CGFloat(displayLines.count) * contentLineHeight
      }
      h += truncH + sectionPadding
    }
    return h
  }

  static func toolTypeName(_ content: NativeToolContent) -> String {
    switch content {
      case .bash: "bash"
      case .edit: "edit"
      case .read: "read"
      case .glob: "glob"
      case .grep: "grep"
      case .task: "task"
      case .mcp: "mcp"
      case .webFetch: "webFetch"
      case .webSearch: "webSearch"
      case .generic: "generic"
    }
  }
}

// MARK: - macOS Cell View

#if os(macOS)

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
    private static let truncationFooterHeight = ExpandedToolLayout.truncationFooterHeight
    private static let contentTopPad = ExpandedToolLayout.contentTopPad
    private static let bottomPadding = ExpandedToolLayout.bottomPadding

    private static let bashMaxLines = ExpandedToolLayout.bashMaxLines
    private static let editMaxLines = ExpandedToolLayout.editMaxLines
    private static let readMaxLines = ExpandedToolLayout.readMaxLines
    private static let globMaxDirs = ExpandedToolLayout.globMaxDirs
    private static let globMaxFilesPerDir = ExpandedToolLayout.globMaxFilesPerDir
    private static let grepMaxFiles = ExpandedToolLayout.grepMaxFiles
    private static let grepMaxMatchesPerFile = ExpandedToolLayout.grepMaxMatchesPerFile
    private static let genericMaxLines = ExpandedToolLayout.genericMaxLines

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
    private static let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let subtitleFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let lineNumFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    private static let sectionLabelFont = NSFont.systemFont(ofSize: 9, weight: .bold)
    private static let statsFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

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
    private let contentContainer = FlippedContentView()
    private let progressIndicator = NSProgressIndicator()

    // ── State ──

    private var model: NativeExpandedToolModel?
    var onCollapse: ((String) -> Void)?

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

      // Content container — on top of content background
      contentContainer.wantsLayer = true
      cardBackground.addSubview(contentContainer)

      // Header tap gesture
      let click = NSClickGestureRecognizer(target: self, action: #selector(handleHeaderTap(_:)))
      cardBackground.addGestureRecognizer(click)
    }

    @objc private func handleHeaderTap(_ gesture: NSClickGestureRecognizer) {
      let location = gesture.location(in: cardBackground)
      let headerHeight = Self.headerHeight(for: model)
      if location.y <= headerHeight, let messageID = model?.messageID {
        onCollapse?(messageID)
      }
    }

    // ── Configure ──

    func configure(model: NativeExpandedToolModel, width: CGFloat) {
      self.model = model

      let inset = Self.laneHorizontalInset
      let cardWidth = width - inset * 2
      let headerH = ExpandedToolLayout.headerHeight(for: model, cardWidth: cardWidth)
      let contentH = ExpandedToolLayout.contentHeight(for: model, cardWidth: cardWidth)
      let totalH = Self.requiredHeight(for: width, model: model)

      // Card background — inset from lane edges
      cardBackground.frame = NSRect(x: inset, y: 0, width: cardWidth, height: totalH)
      cardBackground.layer?.borderColor = model.toolColor.withAlphaComponent(OpacityTier.light).cgColor

      // Accent bar — full height of card
      let accentColor = model.hasError ? NSColor(Color.statusError) : model.toolColor
      accentBar.layer?.backgroundColor = accentColor.cgColor
      accentBar.frame = NSRect(x: 0, y: 0, width: Self.accentBarWidth, height: totalH)

      // Header divider line
      let dividerX = Self.accentBarWidth
      let dividerW = cardWidth - Self.accentBarWidth
      headerDivider.frame = NSRect(x: dividerX, y: headerH, width: dividerW, height: 1)
      headerDivider.isHidden = contentH == 0

      // Content background — darker region behind output (stops before card corner radius)
      if contentH > 0 {
        contentBg.isHidden = false
        contentBg.frame = NSRect(
          x: dividerX, y: headerH + 1, width: dividerW, height: contentH
        )
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
      iconView.frame = NSRect(
        x: Self.accentBarWidth + Self.headerHPad,
        y: Self.headerVPad,
        width: 20, height: 20
      )

      // Title + subtitle
      configureHeader(model: model, cardWidth: cardWidth, headerH: headerH)

      // Progress indicator
      if model.isInProgress {
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        progressIndicator.frame = NSRect(
          x: cardWidth - Self.headerHPad - 16,
          y: Self.headerVPad + 2,
          width: 16, height: 16
        )
      } else {
        progressIndicator.isHidden = true
        progressIndicator.stopAnimation(nil)
      }

      // Collapse chevron
      if !model.isInProgress {
        collapseChevron.isHidden = false
        collapseChevron.frame = NSRect(
          x: cardWidth - Self.headerHPad - 12,
          y: Self.headerVPad + 3,
          width: 12, height: 12
        )
      } else {
        collapseChevron.isHidden = true
      }

      // Duration
      if let dur = model.duration, !model.isInProgress {
        durationField.isHidden = false
        durationField.stringValue = dur
        durationField.sizeToFit()
        let durW = durationField.frame.width
        let durX = cardWidth - Self.headerHPad - 12 - 8 - durW
        durationField.frame = NSRect(x: durX, y: Self.headerVPad + 2, width: durW, height: 16)
      } else {
        durationField.isHidden = true
      }

      // Content
      contentContainer.subviews.forEach { $0.removeFromSuperview() }
      contentContainer.frame = NSRect(
        x: 0,
        y: headerH,
        width: cardWidth,
        height: contentH
      )
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

    private func configureHeader(model: NativeExpandedToolModel, cardWidth: CGFloat, headerH: CGFloat) {
      let leftEdge = Self.accentBarWidth + Self.headerHPad + 20 + 8 // after accent + pad + icon + gap
      let rightEdge = cardWidth - Self.headerHPad - 12 - 8 - 60 // before chevron + duration

      switch model.content {
        case let .bash(command, _):
          let bashColor = model.hasError ? NSColor(Color.statusError) : model.toolColor
          let bashAttr = NSMutableAttributedString()
          bashAttr.append(NSAttributedString(
            string: "$ ",
            attributes: [
              .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
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
          subtitleField.isHidden = true
          statsField.isHidden = true

        case let .edit(filename, path, additions, deletions, _, _):
          titleField.stringValue = filename ?? "Edit"
          titleField.font = Self.headerFont
          titleField.textColor = Self.textPrimary
          subtitleField.isHidden = path == nil
          subtitleField.stringValue = path.map { ToolCardStyle.shortenPath($0) } ?? ""
          configureEditStats(additions: additions, deletions: deletions, cardWidth: cardWidth)
          return

        case let .read(filename, path, language, lines):
          titleField.stringValue = filename ?? "Read"
          titleField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
          titleField.textColor = Self.textPrimary
          subtitleField.isHidden = path == nil
          subtitleField.stringValue = path.map { ToolCardStyle.shortenPath($0) } ?? ""
          statsField.isHidden = false
          statsField.stringValue = "\(lines.count) lines" + (language.isEmpty ? "" : " · \(language)")

        case let .glob(pattern, grouped):
          let fileCount = grouped.reduce(0) { $0 + $1.files.count }
          titleField.stringValue = "Glob"
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = false
          subtitleField.stringValue = pattern
          statsField.isHidden = false
          statsField.stringValue = "\(fileCount) \(fileCount == 1 ? "file" : "files")"

        case let .grep(pattern, grouped):
          let matchCount = grouped.reduce(0) { $0 + max(1, $1.matches.count) }
          titleField.stringValue = "Grep"
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = false
          subtitleField.stringValue = pattern
          statsField.isHidden = false
          statsField.stringValue = "\(matchCount) in \(grouped.count) \(grouped.count == 1 ? "file" : "files")"

        case let .task(agentLabel, _, description, _, isComplete):
          titleField.stringValue = agentLabel
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = description.isEmpty
          subtitleField.stringValue = description
          statsField.isHidden = false
          statsField.stringValue = isComplete ? "Complete" : "Running..."

        case let .mcp(server, displayTool, subtitle, _):
          titleField.stringValue = displayTool
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = subtitle == nil
          subtitleField.stringValue = subtitle ?? ""
          statsField.isHidden = false
          statsField.stringValue = server

        case let .webFetch(domain, _, _):
          titleField.stringValue = "WebFetch"
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = false
          subtitleField.stringValue = domain
          statsField.isHidden = true

        case let .webSearch(query, _):
          titleField.stringValue = "WebSearch"
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = false
          subtitleField.stringValue = query
          statsField.isHidden = true

        case let .generic(toolName, _, _):
          titleField.stringValue = toolName
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = true
          statsField.isHidden = true
      }

      // Layout title + subtitle
      let hasSubtitle = !subtitleField.isHidden
      let titleWidth = max(60, rightEdge - leftEdge)
      if hasSubtitle {
        titleField.frame = NSRect(x: leftEdge, y: Self.headerVPad, width: titleWidth, height: 18)
        subtitleField.frame = NSRect(x: leftEdge, y: Self.headerVPad + 18, width: titleWidth, height: 16)
      } else {
        // For bash commands, measure wrapped height
        if case .bash = model.content {
          let titleH = headerH - Self.headerVPad * 2
          titleField.frame = NSRect(x: leftEdge, y: Self.headerVPad, width: titleWidth, height: max(18, titleH))
        } else {
          titleField.frame = NSRect(x: leftEdge, y: Self.headerVPad + 4, width: titleWidth, height: 18)
        }
      }

      // Stats (right-aligned, after title)
      if !statsField.isHidden {
        statsField.sizeToFit()
        let statsW = statsField.frame.width
        let statsX = cardWidth - Self
          .headerHPad - 12 - 8 - (durationField.isHidden ? 0 : durationField.frame.width + 8) - statsW
        statsField.frame = NSRect(x: statsX, y: Self.headerVPad + 2, width: statsW, height: 16)
      }
    }

    private func configureEditStats(additions: Int, deletions: Int, cardWidth: CGFloat) {
      subtitleField.isHidden = subtitleField.stringValue.isEmpty

      let leftEdge = Self.accentBarWidth + Self.headerHPad + 20 + 8
      let rightEdge = cardWidth - Self.headerHPad - 60

      // Layout title + subtitle for edit
      titleField.frame = NSRect(x: leftEdge, y: Self.headerVPad, width: rightEdge - leftEdge, height: 18)
      if !subtitleField.isHidden {
        subtitleField.frame = NSRect(x: leftEdge, y: Self.headerVPad + 20, width: rightEdge - leftEdge, height: 14)
      }

      // Use statsField for combined diff stats
      var parts: [String] = []
      if deletions > 0 { parts.append("−\(deletions)") }
      if additions > 0 { parts.append("+\(additions)") }
      if !parts.isEmpty {
        statsField.isHidden = false
        statsField.stringValue = parts.joined(separator: " ")
        statsField.textColor = additions > 0 ? Self.addedAccentColor : Self.removedAccentColor
      } else {
        statsField.isHidden = true
      }
    }

    // ── Content Builders ──

    private func buildContent(model: NativeExpandedToolModel, width: CGFloat) {
      switch model.content {
        case let .bash(_, output):
          buildTextOutputContent(output: output, maxLines: Self.bashMaxLines, width: width)
        case let .edit(_, _, _, _, lines, isWriteNew):
          buildEditContent(lines: lines, isWriteNew: isWriteNew, width: width)
        case let .read(_, _, language, lines):
          buildReadContent(lines: lines, language: language, width: width)
        case let .glob(_, grouped):
          buildGlobContent(grouped: grouped, width: width)
        case let .grep(_, grouped):
          buildGrepContent(grouped: grouped, width: width)
        case let .task(_, _, _, output, _):
          buildTextOutputContent(output: output, maxLines: Self.genericMaxLines, width: width)
        case let .mcp(_, _, _, output):
          buildTextOutputContent(output: output, maxLines: Self.genericMaxLines, width: width)
        case let .webFetch(_, _, output):
          buildTextOutputContent(output: output, maxLines: Self.genericMaxLines, width: width)
        case let .webSearch(_, output):
          buildTextOutputContent(output: output, maxLines: Self.genericMaxLines, width: width)
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
      let textWidth = width - Self.headerHPad * 2
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for line in displayLines {
        let text = line.isEmpty ? " " : line
        let label = NSTextField(labelWithString: text)
        label.font = Self.codeFont
        label.textColor = Self.textSecondary
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        let labelH = ExpandedToolLayout.measuredTextHeight(text, font: Self.codeFont, maxWidth: textWidth)
        label.frame = NSRect(x: Self.headerHPad, y: y, width: textWidth, height: labelH)
        contentContainer.addSubview(label)
        y += labelH
      }

      if truncated {
        let footer = NSTextField(labelWithString: "... +\(lines.count - maxLines) more lines")
        footer.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        footer.textColor = Self.textQuaternary
        footer.frame = NSRect(x: Self.headerHPad, y: y + 4, width: textWidth, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Edit (diff lines) ──

    private func buildEditContent(lines: [DiffLine], isWriteNew: Bool, width: CGFloat) {
      let displayLines = Array(lines.prefix(Self.editMaxLines))
      let truncated = lines.count > Self.editMaxLines
      var y: CGFloat = 0

      // Write new file header
      if isWriteNew {
        let header = NSTextField(labelWithString: "NEW FILE (\(lines.count) lines)")
        header.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        header.textColor = Self.addedAccentColor
        header.frame = NSRect(x: Self.headerHPad, y: y + 6, width: width - Self.headerHPad * 2, height: 16)
        contentContainer.addSubview(header)

        let headerBg = NSView(frame: NSRect(x: 0, y: y, width: width, height: 28))
        headerBg.wantsLayer = true
        headerBg.layer?.backgroundColor = Self.addedBgColor.withAlphaComponent(0.3).cgColor
        contentContainer.addSubview(headerBg, positioned: .below, relativeTo: nil)
        y += 28
      }

      for line in displayLines {
        let bgColor: NSColor
        let prefixColor: NSColor
        switch line.type {
          case .added:
            bgColor = Self.addedBgColor
            prefixColor = Self.addedAccentColor
          case .removed:
            bgColor = Self.removedBgColor
            prefixColor = Self.removedAccentColor
          case .context:
            bgColor = .clear
            prefixColor = .clear
        }

        // Row background
        let rowBg = NSView(frame: NSRect(x: 0, y: y, width: width, height: Self.diffLineHeight))
        rowBg.wantsLayer = true
        rowBg.layer?.backgroundColor = bgColor.cgColor
        contentContainer.addSubview(rowBg)

        // Old line number
        if let num = line.oldLineNum {
          let numLabel = NSTextField(labelWithString: "\(num)")
          numLabel.font = Self.lineNumFont
          numLabel.textColor = Self.textQuaternary
          numLabel.alignment = .right
          numLabel.frame = NSRect(x: 4, y: y + 2, width: 32, height: 18)
          contentContainer.addSubview(numLabel)
        }

        // New line number
        if let num = line.newLineNum {
          let numLabel = NSTextField(labelWithString: "\(num)")
          numLabel.font = Self.lineNumFont
          numLabel.textColor = Self.textQuaternary
          numLabel.alignment = .right
          numLabel.frame = NSRect(x: 40, y: y + 2, width: 32, height: 18)
          contentContainer.addSubview(numLabel)
        }

        // Prefix (+/-)
        let prefixLabel = NSTextField(labelWithString: line.prefix)
        prefixLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        prefixLabel.textColor = prefixColor
        prefixLabel.frame = NSRect(x: 78, y: y + 1, width: 16, height: 20)
        contentContainer.addSubview(prefixLabel)

        // Content
        let contentLabel = NSTextField(labelWithString: line.content.isEmpty ? " " : line.content)
        contentLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        contentLabel.textColor = Self.textPrimary
        contentLabel.lineBreakMode = .byTruncatingTail
        contentLabel.maximumNumberOfLines = 1
        contentLabel.isSelectable = true
        contentLabel.frame = NSRect(x: 96, y: y + 2, width: width - 110, height: 18)
        contentContainer.addSubview(contentLabel)

        y += Self.diffLineHeight
      }

      if truncated {
        let footer = NSTextField(labelWithString: "... +\(lines.count - Self.editMaxLines) more changed lines")
        footer.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        footer.textColor = Self.textQuaternary
        footer.frame = NSRect(x: Self.headerHPad, y: y + 6, width: width - Self.headerHPad * 2, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Read (line-numbered code) ──

    private func buildReadContent(lines: [String], language: String, width: CGFloat) {
      let displayLines = Array(lines.prefix(Self.readMaxLines))
      let truncated = lines.count > Self.readMaxLines
      let maxLineNumWidth = CGFloat("\(lines.count)".count) * 8 + 10
      let codeX = maxLineNumWidth + 12
      let codeWidth = width - codeX - Self.headerHPad
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for (index, line) in displayLines.enumerated() {
        let text = line.isEmpty ? " " : line
        let lineH = ExpandedToolLayout.measuredTextHeight(text, font: Self.codeFont, maxWidth: codeWidth)

        // Line number
        let numLabel = NSTextField(labelWithString: "\(index + 1)")
        numLabel.font = Self.lineNumFont
        numLabel.textColor = Self.textQuaternary
        numLabel.alignment = .right
        numLabel.frame = NSRect(x: 4, y: y, width: maxLineNumWidth, height: lineH)
        contentContainer.addSubview(numLabel)

        // Code line
        let codeLine = NSTextField(labelWithString: "")
        let lang = language.isEmpty ? nil : language
        codeLine.attributedStringValue = NativeSyntaxHighlighter.highlightLine(text, language: lang)
        codeLine.lineBreakMode = .byCharWrapping
        codeLine.maximumNumberOfLines = 0
        codeLine.isSelectable = true
        codeLine.frame = NSRect(x: codeX, y: y, width: codeWidth, height: lineH)
        contentContainer.addSubview(codeLine)

        y += lineH
      }

      if truncated {
        y += 4
        let footer = NSTextField(labelWithString: "... +\(lines.count - Self.readMaxLines) more lines")
        footer.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        footer.textColor = Self.textQuaternary
        footer.frame = NSRect(x: Self.headerHPad, y: y, width: width - Self.headerHPad * 2, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Glob (directory tree) ──

    private func buildGlobContent(grouped: [(dir: String, files: [String])], width: CGFloat) {
      let displayDirs = Array(grouped.prefix(Self.globMaxDirs))
      let truncated = grouped.count > Self.globMaxDirs
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for (dir, files) in displayDirs {
        // Directory header
        let dirIcon = NSImageView()
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        dirIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
          .withSymbolConfiguration(iconConfig)
        dirIcon.contentTintColor = NSColor(Color.toolWrite)
        dirIcon.frame = NSRect(x: Self.headerHPad, y: y + 2, width: 14, height: 14)
        contentContainer.addSubview(dirIcon)

        let dirText = "\(dir == "." ? "(root)" : dir) (\(files.count))"
        let dirLabel = NSTextField(labelWithString: dirText)
        dirLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        dirLabel.textColor = Self.textSecondary
        dirLabel.lineBreakMode = .byCharWrapping
        dirLabel.maximumNumberOfLines = 0
        let dirW = width - Self.headerHPad * 2 - 18
        let dirH = ExpandedToolLayout.measuredTextHeight(dirText, font: dirLabel.font!, maxWidth: dirW)
        dirLabel.frame = NSRect(x: Self.headerHPad + 18, y: y, width: dirW, height: dirH)
        contentContainer.addSubview(dirLabel)
        y += dirH + 2

        // Files
        let displayFiles = Array(files.prefix(Self.globMaxFilesPerDir))
        for file in displayFiles {
          let filename = file.components(separatedBy: "/").last ?? file
          let fileLabel = NSTextField(labelWithString: filename)
          fileLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
          fileLabel.textColor = Self.textTertiary
          fileLabel.lineBreakMode = .byCharWrapping
          fileLabel.maximumNumberOfLines = 0
          let fileX = Self.headerHPad + 28
          let fileW = width - Self.headerHPad * 2 - 28
          let fileH = ExpandedToolLayout.measuredTextHeight(filename, font: fileLabel.font!, maxWidth: fileW)
          fileLabel.frame = NSRect(
            x: fileX, y: y, width: fileW, height: fileH
          )
          contentContainer.addSubview(fileLabel)
          y += fileH
        }

        if files.count > Self.globMaxFilesPerDir {
          let more = NSTextField(labelWithString: "... +\(files.count - Self.globMaxFilesPerDir) more")
          more.font = NSFont.systemFont(ofSize: 10, weight: .regular)
          more.textColor = Self.textQuaternary
          more.frame = NSRect(x: Self.headerHPad + 28, y: y, width: width - Self.headerHPad * 2 - 28, height: 14)
          contentContainer.addSubview(more)
          y += 16
        }

        y += 6 // gap between dirs
      }

      if truncated {
        let footer = NSTextField(labelWithString: "... +\(grouped.count - Self.globMaxDirs) more directories")
        footer.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        footer.textColor = Self.textQuaternary
        footer.frame = NSRect(x: Self.headerHPad, y: y, width: width - Self.headerHPad * 2, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Grep (file-grouped results) ──

    private func buildGrepContent(grouped: [(file: String, matches: [String])], width: CGFloat) {
      let displayFiles = Array(grouped.prefix(Self.grepMaxFiles))
      let truncated = grouped.count > Self.grepMaxFiles
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for (file, matches) in displayFiles {
        // File header
        let shortPath = file.components(separatedBy: "/").suffix(3).joined(separator: "/")
        let matchSuffix = matches.isEmpty ? "" : " (\(matches.count))"
        let fileText = shortPath + matchSuffix
        let fileLabel = NSTextField(labelWithString: fileText)
        fileLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        fileLabel.textColor = Self.textPrimary
        fileLabel.lineBreakMode = .byCharWrapping
        fileLabel.maximumNumberOfLines = 0
        let fileLabelW = width - Self.headerHPad * 2
        let fileLabelH = ExpandedToolLayout.measuredTextHeight(fileText, font: fileLabel.font!, maxWidth: fileLabelW)
        fileLabel.frame = NSRect(x: Self.headerHPad, y: y, width: fileLabelW, height: fileLabelH)
        contentContainer.addSubview(fileLabel)
        y += fileLabelH + 2

        // Match lines
        let displayMatches = Array(matches.prefix(Self.grepMaxMatchesPerFile))
        for match in displayMatches {
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

        if matches.count > Self.grepMaxMatchesPerFile {
          let more = NSTextField(labelWithString: "... +\(matches.count - Self.grepMaxMatchesPerFile) more")
          more.font = NSFont.systemFont(ofSize: 10, weight: .regular)
          more.textColor = Self.textQuaternary
          more.frame = NSRect(x: Self.headerHPad + 16, y: y, width: width - Self.headerHPad * 2 - 16, height: 14)
          contentContainer.addSubview(more)
          y += 16
        }

        y += 6
      }

      if truncated {
        let footer = NSTextField(labelWithString: "... +\(grouped.count - Self.grepMaxFiles) more files")
        footer.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        footer.textColor = Self.textQuaternary
        footer.frame = NSRect(x: Self.headerHPad, y: y, width: width - Self.headerHPad * 2, height: 16)
        contentContainer.addSubview(footer)
      }
    }

    // ── Generic (input + output) ──

    private func buildGenericContent(input: String?, output: String?, width: CGFloat) {
      var y: CGFloat = Self.contentTopPad

      // Input section
      if let input, !input.isEmpty {
        let inputHeader = NSTextField(labelWithString: "INPUT")
        inputHeader.font = Self.sectionLabelFont
        inputHeader.textColor = Self.textQuaternary
        let attrs: [NSAttributedString.Key: Any] = [
          .kern: 0.8,
          .font: Self.sectionLabelFont as Any,
          .foregroundColor: Self.textQuaternary,
        ]
        inputHeader.attributedStringValue = NSAttributedString(string: "INPUT", attributes: attrs)
        inputHeader.frame = NSRect(x: Self.headerHPad, y: y + Self.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(inputHeader)
        y += Self.sectionHeaderHeight + Self.sectionPadding

        let inputLines = input.components(separatedBy: "\n")
        let displayLines = Array(inputLines.prefix(Self.genericMaxLines))
        let textW = width - Self.headerHPad * 2
        for line in displayLines {
          let text = line.isEmpty ? " " : line
          let label = NSTextField(labelWithString: text)
          label.font = Self.codeFont
          label.textColor = Self.textSecondary
          label.lineBreakMode = .byCharWrapping
          label.maximumNumberOfLines = 0
          label.isSelectable = true
          let lineH = ExpandedToolLayout.measuredTextHeight(text, font: Self.codeFont, maxWidth: textW)
          label.frame = NSRect(
            x: Self.headerHPad,
            y: y,
            width: textW,
            height: lineH
          )
          contentContainer.addSubview(label)
          y += lineH
        }
        y += Self.sectionPadding
      }

      // Output section
      if let output, !output.isEmpty {
        let outputHeader = NSTextField(labelWithString: "")
        let attrs: [NSAttributedString.Key: Any] = [
          .kern: 0.8,
          .font: Self.sectionLabelFont as Any,
          .foregroundColor: Self.textQuaternary,
        ]
        outputHeader.attributedStringValue = NSAttributedString(string: "OUTPUT", attributes: attrs)
        outputHeader.frame = NSRect(x: Self.headerHPad, y: y + Self.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(outputHeader)
        y += Self.sectionHeaderHeight + Self.sectionPadding

        let outputLines = output.components(separatedBy: "\n")
        let displayLines = Array(outputLines.prefix(Self.genericMaxLines))
        let outTextW = width - Self.headerHPad * 2
        for line in displayLines {
          let text = line.isEmpty ? " " : line
          let label = NSTextField(labelWithString: text)
          label.font = Self.codeFont
          label.textColor = Self.textSecondary
          label.lineBreakMode = .byCharWrapping
          label.maximumNumberOfLines = 0
          label.isSelectable = true
          let lineH = ExpandedToolLayout.measuredTextHeight(text, font: Self.codeFont, maxWidth: outTextW)
          label.frame = NSRect(
            x: Self.headerHPad,
            y: y,
            width: outTextW,
            height: lineH
          )
          contentContainer.addSubview(label)
          y += lineH
        }

        if outputLines.count > Self.genericMaxLines {
          let footer = NSTextField(labelWithString: "... +\(outputLines.count - Self.genericMaxLines) more lines")
          footer.font = NSFont.systemFont(ofSize: 10, weight: .medium)
          footer.textColor = Self.textQuaternary
          footer.frame = NSRect(x: Self.headerHPad, y: y + 4, width: width - Self.headerHPad * 2, height: 16)
          contentContainer.addSubview(footer)
          y += Self.truncationFooterHeight
        }

        y += Self.sectionPadding
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
