//
//  AppKitStructuralStripCells.swift
//  OrbitDock
//
//  macOS-specific NSTableCellView subclasses for strip-style structural rows:
//  compact tool summaries and collapsed turn summaries.
//

#if os(macOS)

  import AppKit
  import SwiftUI

  final class NativeCompactToolCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeCompactToolCell")

    private let stripContainer = NSView()
    private let accentBar = NSView()
    private let glyphImage = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let dotSeparator = NSTextField(labelWithString: "\u{00B7}")
    private let subtitleField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let workerButton = NSButton(title: "", target: nil, action: nil)
    private let chevronView = NSImageView()
    private let contextField = NSTextField(labelWithString: "")
    private let snippetField = NSTextField(labelWithString: "")
    private let outputPreviewField = NSTextField(labelWithString: "")
    private let diffBarContainer = NSView()
    private let diffBarAdded = NSView()
    private let diffBarRemoved = NSView()
    private var diffBarAddedWidth: NSLayoutConstraint?
    private var diffBarRemovedWidth: NSLayoutConstraint?

    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    var onTap: (() -> Void)?
    var onFocusWorker: (() -> Void)?

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

      let inset = ConversationLayout.laneHorizontalInset

      stripContainer.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.wantsLayer = true
      stripContainer.layer?.cornerRadius = CGFloat(Radius.md)
      stripContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
      addSubview(stripContainer)

      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.wantsLayer = true
      accentBar.layer?.cornerRadius = CGFloat(Radius.xs)
      stripContainer.addSubview(accentBar)

      glyphImage.translatesAutoresizingMaskIntoConstraints = false
      glyphImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
      stripContainer.addSubview(glyphImage)

      titleField.translatesAutoresizingMaskIntoConstraints = false
      titleField.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      titleField.textColor = NSColor(Color.textPrimary)
      titleField.lineBreakMode = .byTruncatingTail
      titleField.maximumNumberOfLines = 1
      titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      stripContainer.addSubview(titleField)

      dotSeparator.translatesAutoresizingMaskIntoConstraints = false
      dotSeparator.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      dotSeparator.textColor = NSColor(Color.textQuaternary)
      dotSeparator.setContentCompressionResistancePriority(.required, for: .horizontal)
      dotSeparator.isHidden = true
      stripContainer.addSubview(dotSeparator)

      subtitleField.translatesAutoresizingMaskIntoConstraints = false
      subtitleField.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      subtitleField.textColor = NSColor(Color.textTertiary)
      subtitleField.lineBreakMode = .byTruncatingTail
      subtitleField.maximumNumberOfLines = 1
      subtitleField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
      subtitleField.isHidden = true
      stripContainer.addSubview(subtitleField)

      metaField.translatesAutoresizingMaskIntoConstraints = false
      metaField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
      metaField.textColor = NSColor(Color.textTertiary)
      metaField.lineBreakMode = .byTruncatingTail
      metaField.alignment = .right
      metaField.setContentCompressionResistancePriority(.required, for: .horizontal)
      stripContainer.addSubview(metaField)

      workerButton.translatesAutoresizingMaskIntoConstraints = false
      workerButton.image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "Inspect worker")
      workerButton.contentTintColor = NSColor(Color.accent)
      workerButton.isBordered = false
      workerButton.bezelStyle = .regularSquare
      workerButton.target = self
      workerButton.action = #selector(handleWorkerTap(_:))
      workerButton.isHidden = true
      stripContainer.addSubview(workerButton)

      chevronView.translatesAutoresizingMaskIntoConstraints = false
      chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
      chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
      chevronView.contentTintColor = NSColor(Color.textQuaternary)
      chevronView.alphaValue = 0.25
      stripContainer.addSubview(chevronView)

      contextField.translatesAutoresizingMaskIntoConstraints = false
      contextField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
      contextField.textColor = NSColor.white.withAlphaComponent(0.25)
      contextField.lineBreakMode = .byTruncatingTail
      contextField.maximumNumberOfLines = 1
      contextField.isHidden = true
      stripContainer.addSubview(contextField)

      snippetField.translatesAutoresizingMaskIntoConstraints = false
      snippetField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
      snippetField.lineBreakMode = .byTruncatingTail
      snippetField.maximumNumberOfLines = 1
      snippetField.isHidden = true
      stripContainer.addSubview(snippetField)

      outputPreviewField.translatesAutoresizingMaskIntoConstraints = false
      outputPreviewField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
      outputPreviewField.textColor = NSColor(Color.textQuaternary)
      outputPreviewField.lineBreakMode = .byTruncatingTail
      outputPreviewField.maximumNumberOfLines = 3
      outputPreviewField.isHidden = true
      stripContainer.addSubview(outputPreviewField)

      diffBarContainer.wantsLayer = true
      diffBarContainer.translatesAutoresizingMaskIntoConstraints = false
      diffBarContainer.isHidden = true
      stripContainer.addSubview(diffBarContainer)

      diffBarAdded.wantsLayer = true
      diffBarAdded.layer?.cornerRadius = 1.5
      diffBarAdded.translatesAutoresizingMaskIntoConstraints = false
      diffBarContainer.addSubview(diffBarAdded)

      diffBarRemoved.wantsLayer = true
      diffBarRemoved.layer?.cornerRadius = 1.5
      diffBarRemoved.translatesAutoresizingMaskIntoConstraints = false
      diffBarContainer.addSubview(diffBarRemoved)

      let addedW = diffBarAdded.widthAnchor.constraint(equalToConstant: 0)
      let removedW = diffBarRemoved.widthAnchor.constraint(equalToConstant: 0)
      diffBarAddedWidth = addedW
      diffBarRemovedWidth = removedW

      let contentLeading = glyphImage.trailingAnchor

      NSLayoutConstraint.activate([
        stripContainer.topAnchor.constraint(equalTo: topAnchor, constant: ConversationStripRowMetrics.verticalInset),
        stripContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ConversationStripRowMetrics.verticalInset),
        stripContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        stripContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

        accentBar.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor, constant: ConversationStripRowMetrics.accentLeadingInset),
        accentBar.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.accentVerticalInset),
        accentBar.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor, constant: -ConversationStripRowMetrics.accentVerticalInset),
        accentBar.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.accentWidth),

        glyphImage.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: Spacing.sm),
        glyphImage.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.iconTopInset),
        glyphImage.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.iconSize),

        titleField.leadingAnchor.constraint(equalTo: contentLeading, constant: Spacing.xs),
        titleField.centerYAnchor.constraint(equalTo: glyphImage.centerYAnchor),

        dotSeparator.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: Spacing.xs),
        dotSeparator.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

        subtitleField.leadingAnchor.constraint(equalTo: dotSeparator.trailingAnchor, constant: Spacing.xs),
        subtitleField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
        subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: metaField.leadingAnchor, constant: -Spacing.sm),

        metaField.trailingAnchor.constraint(equalTo: workerButton.leadingAnchor, constant: -Spacing.xs),
        metaField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

        workerButton.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -Spacing.xs),
        workerButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
        workerButton.widthAnchor.constraint(equalToConstant: 18),
        workerButton.heightAnchor.constraint(equalToConstant: 18),

        chevronView.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor, constant: -Spacing.md_),
        chevronView.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
        chevronView.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.chevronWidth),

        titleField.trailingAnchor.constraint(lessThanOrEqualTo: metaField.leadingAnchor, constant: -Spacing.sm),

        contextField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        contextField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: ConversationStripRowMetrics.detailTopSpacing),
        contextField.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -Spacing.sm),

        snippetField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        snippetField.topAnchor.constraint(equalTo: contextField.bottomAnchor, constant: 0),
        snippetField.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -Spacing.sm),

        outputPreviewField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        outputPreviewField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: ConversationStripRowMetrics.detailTopSpacing),
        outputPreviewField.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -Spacing.sm),

        diffBarContainer.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        diffBarContainer.topAnchor.constraint(equalTo: snippetField.bottomAnchor, constant: 2),
        diffBarContainer.heightAnchor.constraint(equalToConstant: ConversationStripRowMetrics.diffBarHeight),
        diffBarContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 100),

        diffBarAdded.leadingAnchor.constraint(equalTo: diffBarContainer.leadingAnchor),
        diffBarAdded.topAnchor.constraint(equalTo: diffBarContainer.topAnchor),
        diffBarAdded.heightAnchor.constraint(equalToConstant: ConversationStripRowMetrics.diffBarHeight),
        addedW,

        diffBarRemoved.leadingAnchor.constraint(equalTo: diffBarAdded.trailingAnchor, constant: 1),
        diffBarRemoved.topAnchor.constraint(equalTo: diffBarContainer.topAnchor),
        diffBarRemoved.heightAnchor.constraint(equalToConstant: ConversationStripRowMetrics.diffBarHeight),
        removedW,
      ])

      let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
      addGestureRecognizer(click)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let existing = trackingArea { removeTrackingArea(existing) }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInActiveApp],
        owner: self
      )
      addTrackingArea(area)
      trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
      isHovering = true
      updateHoverState()
    }

    override func mouseExited(with event: NSEvent) {
      isHovering = false
      updateHoverState()
    }

    private func updateHoverState() {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.15
        ctx.allowsImplicitAnimation = true
        stripContainer.layer?.backgroundColor = isHovering
          ? NSColor.white.withAlphaComponent(0.065).cgColor
          : NSColor.white.withAlphaComponent(0.035).cgColor
        chevronView.animator().alphaValue = isHovering ? 0.6 : 0.25
      }
      if isHovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }

    @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
      onTap?()
    }

    @objc private func handleWorkerTap(_ sender: NSButton) {
      onFocusWorker?()
    }

    static func requiredHeight(model: NativeCompactToolRowModel, width: CGFloat) -> CGFloat {
      NativeCompactToolRowModel.requiredHeight(for: model, width: width)
    }

    func configure(model: NativeCompactToolRowModel) {
      glyphImage.image = NSImage(systemSymbolName: model.glyphSymbol, accessibilityDescription: nil)
      glyphImage.contentTintColor = model.glyphColor.withAlphaComponent(0.8)
      accentBar.layer?.backgroundColor = model.glyphColor.withAlphaComponent(0.6).cgColor
      glyphImage.alphaValue = model.isInProgress ? 0.5 : 1.0

      if model.toolType == .bash {
        titleField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .semibold)
      } else {
        titleField.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      }
      titleField.stringValue = model.summary

      let hasSubtitle = !(model.subtitle?.isEmpty ?? true)
      dotSeparator.isHidden = !hasSubtitle
      subtitleField.isHidden = !hasSubtitle
      subtitleField.stringValue = model.subtitle ?? ""

      let hasMeta = !(model.rightMeta?.isEmpty ?? true)
      metaField.isHidden = !hasMeta
      metaField.stringValue = model.rightMeta ?? ""

      workerButton.isHidden = model.linkedWorkerID == nil
      workerButton.toolTip = model.linkedWorkerLabel.map { "Inspect \($0)" } ?? "Inspect worker"
      chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
      chevronView.contentTintColor = NSColor(Color.textQuaternary)
      chevronView.alphaValue = 0.25

      if let preview = model.diffPreview {
        configureDiffPreview(preview)
      } else if let livePreview = model.liveOutputPreview {
        configureLivePreview(livePreview)
      } else if let items = model.todoItems, !items.isEmpty {
        configureTodoPreview(items)
      } else if let preview = model.outputPreview {
        configureOutputPreview(preview)
      } else {
        contextField.isHidden = true
        snippetField.isHidden = true
        outputPreviewField.isHidden = true
        diffBarContainer.isHidden = true
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onTap = nil
      onFocusWorker = nil
      stripContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
      chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
      chevronView.contentTintColor = NSColor(Color.textQuaternary)
      chevronView.alphaValue = 0.25
      workerButton.isHidden = true
      workerButton.toolTip = nil
    }

    private func configureDiffPreview(_ preview: DiffPreviewInfo) {
      outputPreviewField.isHidden = true

      if let context = preview.contextLine {
        contextField.stringValue = "  \(context)"
        contextField.isHidden = false
      } else {
        contextField.isHidden = true
        contextField.stringValue = ""
      }

      let prefixColor = preview.isAddition
        ? ExpandedToolLayout.addedAccentColor
        : ExpandedToolLayout.removedAccentColor
      let attributed = NSMutableAttributedString()
      attributed.append(NSAttributedString(
        string: "\(preview.snippetPrefix) ",
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .bold),
          .foregroundColor: prefixColor.withAlphaComponent(0.7),
        ]
      ))
      attributed.append(NSAttributedString(
        string: preview.snippetText,
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular),
          .foregroundColor: prefixColor.withAlphaComponent(0.7),
        ]
      ))
      snippetField.attributedStringValue = attributed
      snippetField.isHidden = false

      let widths = preview.barWidths(maxWidth: 100)
      diffBarAddedWidth?.constant = widths.added
      diffBarRemovedWidth?.constant = widths.removed
      diffBarAdded.layer?.backgroundColor = ExpandedToolLayout.addedAccentColor.withAlphaComponent(0.6).cgColor
      diffBarRemoved.layer?.backgroundColor = ExpandedToolLayout.removedAccentColor.withAlphaComponent(0.6).cgColor
      diffBarRemoved.isHidden = preview.deletions == 0
      diffBarContainer.isHidden = false
    }

    private func configureLivePreview(_ livePreview: String) {
      contextField.isHidden = true
      diffBarContainer.isHidden = true
      outputPreviewField.isHidden = true

      let color = PlatformColor(Color.toolBash).withAlphaComponent(0.72)
      let attributed = NSMutableAttributedString()
      attributed.append(NSAttributedString(
        string: "> ",
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .bold),
          .foregroundColor: color,
        ]
      ))
      attributed.append(NSAttributedString(
        string: livePreview,
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular),
          .foregroundColor: color,
        ]
      ))
      snippetField.attributedStringValue = attributed
      snippetField.isHidden = false
    }

    private func configureTodoPreview(_ items: [CompactTodoItem]) {
      contextField.isHidden = true
      snippetField.isHidden = true
      diffBarContainer.isHidden = true
      outputPreviewField.isHidden = true

      let font = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
      let attributed = NSMutableAttributedString()
      for (index, item) in items.prefix(8).enumerated() {
        if index > 0 {
          attributed.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        let (symbol, color): (String, NSColor) = switch item.status {
          case .completed: ("\u{2713}", NSColor(Color.toolWrite).withAlphaComponent(0.7))
          case .inProgress: ("\u{25C9}", NSColor(Color.accent).withAlphaComponent(0.8))
          case .pending, .unknown: ("\u{25CB}", NSColor(Color.textQuaternary))
          case .blocked: ("\u{2298}", NSColor(Color.statusPermission).withAlphaComponent(0.7))
          case .canceled: ("\u{2298}", NSColor(Color.textQuaternary).withAlphaComponent(0.5))
        }
        attributed.append(NSAttributedString(
          string: symbol,
          attributes: [.font: font, .foregroundColor: color]
        ))
      }
      if items.count > 8 {
        attributed.append(NSAttributedString(
          string: " +\(items.count - 8)",
          attributes: [.font: font, .foregroundColor: NSColor(Color.textQuaternary)]
        ))
      }
      outputPreviewField.attributedStringValue = attributed
      outputPreviewField.isHidden = false
    }

    private func configureOutputPreview(_ preview: String) {
      contextField.isHidden = true
      snippetField.isHidden = true
      diffBarContainer.isHidden = true

      outputPreviewField.stringValue = preview
      outputPreviewField.isHidden = false
    }
  }

  final class NativeCollapsedTurnCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeCollapsedTurnCell")

    private let stripContainer = NSView()
    private let accentBar = NSView()
    private let disclosureIcon = NSImageView()
    private let userLabel = NSTextField(labelWithString: "")
    private let dotLabel = NSTextField(labelWithString: "\u{00B7}")
    private let assistantLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    var onTap: (() -> Void)?

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

      let inset = ConversationLayout.laneHorizontalInset

      stripContainer.wantsLayer = true
      stripContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
      stripContainer.layer?.cornerRadius = CGFloat(Radius.md)
      stripContainer.translatesAutoresizingMaskIntoConstraints = false
      addSubview(stripContainer)

      accentBar.wantsLayer = true
      accentBar.layer?.backgroundColor = NSColor(Color.textTertiary).withAlphaComponent(0.2).cgColor
      accentBar.layer?.cornerRadius = CGFloat(Radius.xs)
      accentBar.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(accentBar)

      disclosureIcon.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand")
      disclosureIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
      disclosureIcon.contentTintColor = NSColor(Color.textTertiary)
      disclosureIcon.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(disclosureIcon)

      userLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      userLabel.textColor = NSColor(Color.textSecondary)
      userLabel.lineBreakMode = .byTruncatingTail
      userLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(userLabel)

      dotLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      dotLabel.textColor = NSColor(Color.textQuaternary)
      dotLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(dotLabel)

      assistantLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .regular)
      assistantLabel.textColor = NSColor(Color.textTertiary)
      assistantLabel.lineBreakMode = .byTruncatingTail
      assistantLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(assistantLabel)

      statsLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
      statsLabel.textColor = NSColor(Color.textQuaternary)
      statsLabel.alignment = .right
      statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      statsLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(statsLabel)

      NSLayoutConstraint.activate([
        stripContainer.topAnchor.constraint(equalTo: topAnchor, constant: ConversationStripRowMetrics.verticalInset),
        stripContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ConversationStripRowMetrics.verticalInset),
        stripContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        stripContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

        accentBar.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor, constant: ConversationStripRowMetrics.accentLeadingInset),
        accentBar.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.accentVerticalInset),
        accentBar.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor, constant: -ConversationStripRowMetrics.accentVerticalInset),
        accentBar.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.accentWidth),

        disclosureIcon.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: Spacing.sm),
        disclosureIcon.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        disclosureIcon.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.disclosureWidth),

        userLabel.leadingAnchor.constraint(equalTo: disclosureIcon.trailingAnchor, constant: Spacing.sm_),
        userLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        userLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

        dotLabel.leadingAnchor.constraint(equalTo: userLabel.trailingAnchor, constant: Spacing.xs),
        dotLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),

        assistantLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: Spacing.xs),
        assistantLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        assistantLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsLabel.leadingAnchor, constant: -Spacing.sm),

        statsLabel.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor, constant: -Spacing.md_),
        statsLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
      ])

      let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
      addGestureRecognizer(click)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let existing = trackingArea { removeTrackingArea(existing) }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInActiveApp],
        owner: self
      )
      addTrackingArea(area)
      trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.15
        ctx.allowsImplicitAnimation = true
        stripContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
      }
      NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.15
        ctx.allowsImplicitAnimation = true
        stripContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
      }
      NSCursor.pop()
    }

    @objc private func handleClick() {
      onTap?()
    }

    func configure(model: ConversationUtilityRowModels.CollapsedTurnModel) {
      userLabel.stringValue = model.userPreview
      assistantLabel.stringValue = model.assistantPreview
      statsLabel.stringValue = model.statsText
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onTap = nil
      stripContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
    }
  }

#endif
