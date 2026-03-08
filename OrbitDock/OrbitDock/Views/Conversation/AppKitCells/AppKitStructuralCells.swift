//
//  AppKitStructuralCells.swift
//  OrbitDock
//
//  macOS-specific NSTableCellView subclasses for structural timeline rows:
//  spacers, turn headers, rollup summaries, load-more buttons, message counts,
//  and compact tool rows.
//

#if os(macOS)

  import AppKit
  import SwiftUI

  // MARK: - Spacer Cell

  final class NativeSpacerCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeSpacerCell")

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
    }
  }

  // MARK: - Turn Header Cell

  final class NativeTurnHeaderCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeTurnHeaderCell")

    private let leftHairline = NSView()
    private let rightHairline = NSView()
    private let turnLabel = NSTextField(labelWithString: "")
    private let toolsLabel = NSTextField(labelWithString: "")

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
      let hairlineColor = NSColor(Color.textQuaternary).withAlphaComponent(0.15)

      leftHairline.wantsLayer = true
      leftHairline.layer?.backgroundColor = hairlineColor.cgColor
      leftHairline.translatesAutoresizingMaskIntoConstraints = false
      addSubview(leftHairline)

      rightHairline.wantsLayer = true
      rightHairline.layer?.backgroundColor = hairlineColor.cgColor
      rightHairline.translatesAutoresizingMaskIntoConstraints = false
      addSubview(rightHairline)

      turnLabel.translatesAutoresizingMaskIntoConstraints = false
      turnLabel.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
      turnLabel.textColor = NSColor(Color.textQuaternary)
      turnLabel.alignment = .center
      turnLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      addSubview(turnLabel)

      toolsLabel.translatesAutoresizingMaskIntoConstraints = false
      toolsLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
      toolsLabel.textColor = NSColor(Color.textQuaternary)
      toolsLabel.alignment = .right
      toolsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      addSubview(toolsLabel)

      NSLayoutConstraint.activate([
        leftHairline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        leftHairline.centerYAnchor.constraint(equalTo: centerYAnchor),
        leftHairline.trailingAnchor.constraint(equalTo: turnLabel.leadingAnchor, constant: -Spacing.sm),
        leftHairline.heightAnchor.constraint(equalToConstant: 0.5),

        turnLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        turnLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

        rightHairline.leadingAnchor.constraint(equalTo: turnLabel.trailingAnchor, constant: Spacing.sm),
        rightHairline.centerYAnchor.constraint(equalTo: centerYAnchor),
        rightHairline.trailingAnchor.constraint(equalTo: toolsLabel.leadingAnchor, constant: -Spacing.sm),
        rightHairline.heightAnchor.constraint(equalToConstant: 0.5),

        toolsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        toolsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    func configure(model: ConversationUtilityRowModels.TurnHeaderModel) {
      if model.isHidden {
        leftHairline.isHidden = true
        rightHairline.isHidden = true
        turnLabel.isHidden = true
        toolsLabel.isHidden = true
        return
      }

      leftHairline.isHidden = false
      rightHairline.isHidden = false
      turnLabel.isHidden = false

      let attributed = NSMutableAttributedString(
        string: model.labelText ?? "",
        attributes: [
          .font: NSFont.systemFont(ofSize: TypeScale.micro, weight: .semibold),
          .foregroundColor: NSColor(Color.textQuaternary),
          .kern: 1.5,
        ]
      )
      turnLabel.attributedStringValue = attributed

      if let toolsText = model.toolsText {
        toolsLabel.isHidden = false
        toolsLabel.stringValue = toolsText
      } else {
        toolsLabel.isHidden = true
        toolsLabel.stringValue = ""
      }
    }
  }

  // MARK: - Rollup Summary Cell (Activity Capsule)

  final class NativeRollupSummaryCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeRollupSummaryCell")

    private let capsuleBackground = NSView()
    private let iconImage = NSImageView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let chevronImage = NSImageView()
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var baseCapsuleAlpha: CGFloat = 0.08
    private var baseSummaryColor = NSColor(Color.textSecondary)
    var onToggle: (() -> Void)?

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

      // Capsule background pill
      capsuleBackground.wantsLayer = true
      capsuleBackground.layer?.cornerRadius = ConversationLayout.capsuleCornerRadius
      capsuleBackground.translatesAutoresizingMaskIntoConstraints = false
      addSubview(capsuleBackground)

      // Activity icon (colored dot/icon)
      iconImage.translatesAutoresizingMaskIntoConstraints = false
      iconImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
      addSubview(iconImage)

      // Semantic summary text
      summaryLabel.translatesAutoresizingMaskIntoConstraints = false
      summaryLabel.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
      summaryLabel.textColor = NSColor(Color.textSecondary)
      summaryLabel.lineBreakMode = .byTruncatingTail
      summaryLabel.maximumNumberOfLines = 1
      addSubview(summaryLabel)

      // Duration badge
      durationLabel.translatesAutoresizingMaskIntoConstraints = false
      durationLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
      durationLabel.textColor = NSColor(Color.textTertiary)
      durationLabel.alignment = .right
      addSubview(durationLabel)

      // Expand chevron
      chevronImage.translatesAutoresizingMaskIntoConstraints = false
      chevronImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
      chevronImage.contentTintColor = NSColor(Color.textQuaternary)
      addSubview(chevronImage)

      NSLayoutConstraint.activate([
        // Capsule background
        capsuleBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        capsuleBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        capsuleBackground.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        capsuleBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

        // Icon
        iconImage.leadingAnchor.constraint(equalTo: capsuleBackground.leadingAnchor, constant: Spacing.sm),
        iconImage.centerYAnchor.constraint(equalTo: centerYAnchor),
        iconImage.widthAnchor.constraint(equalToConstant: 14),

        // Summary text
        summaryLabel.leadingAnchor.constraint(equalTo: iconImage.trailingAnchor, constant: Spacing.sm_),
        summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

        // Duration
        durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: Spacing.sm),
        durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

        // Chevron
        chevronImage.leadingAnchor.constraint(equalTo: durationLabel.trailingAnchor, constant: Spacing.sm_),
        chevronImage.trailingAnchor.constraint(equalTo: capsuleBackground.trailingAnchor, constant: -Spacing.sm),
        chevronImage.centerYAnchor.constraint(equalTo: centerYAnchor),
        chevronImage.widthAnchor.constraint(equalToConstant: 10),
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
        let bgAlpha: CGFloat = isHovering ? min(baseCapsuleAlpha + 0.04, 0.12) : baseCapsuleAlpha
        capsuleBackground.layer?.backgroundColor = currentCapsuleColor.withAlphaComponent(bgAlpha).cgColor
        chevronImage.contentTintColor = isHovering
          ? NSColor(Color.accent)
          : NSColor(Color.textQuaternary)
        summaryLabel.textColor = isHovering
          ? NSColor(Color.textPrimary)
          : baseSummaryColor
      }
    }

    @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
      onToggle?()
    }

    private var currentCapsuleColor: NSColor = NSColor(Color.textTertiary)

    func configure(model: ConversationUtilityRowModels.RollupSummaryModel) {
      chevronImage.image = NSImage(systemSymbolName: model.chevronName, accessibilityDescription: nil)
      summaryLabel.stringValue = model.summaryText
      iconImage.image = NSImage(systemSymbolName: model.symbolName, accessibilityDescription: nil)

      let toolColor = NSColor(ConversationUtilityRowModels.color(for: model.colorKey))
      iconImage.contentTintColor = toolColor
      currentCapsuleColor = toolColor
      baseCapsuleAlpha = model.isExpanded ? 0.06 : 0.08
      baseSummaryColor = model.isExpanded ? NSColor(Color.textTertiary) : NSColor(Color.textSecondary)
      summaryLabel.textColor = baseSummaryColor
      capsuleBackground.layer?.backgroundColor = toolColor.withAlphaComponent(baseCapsuleAlpha).cgColor

      if let duration = model.durationText, !duration.isEmpty {
        durationLabel.isHidden = false
        durationLabel.stringValue = duration
      } else {
        durationLabel.isHidden = true
        durationLabel.stringValue = ""
      }
    }
  }

  // MARK: - Load More Cell

  final class NativeLoadMoreCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeLoadMoreCell")

    private let button = NSButton(title: "", target: nil, action: nil)
    var onLoadMore: (() -> Void)?

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

      button.translatesAutoresizingMaskIntoConstraints = false
      button.isBordered = false
      button.font = NSFont.systemFont(ofSize: TypeScale.meta, weight: .medium)
      button.contentTintColor = NSColor(Color.accent)
      button.target = self
      button.action = #selector(handleClick)
      addSubview(button)

      NSLayoutConstraint.activate([
        button.centerXAnchor.constraint(equalTo: centerXAnchor),
        button.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    @objc private func handleClick() {
      onLoadMore?()
    }

    func configure(remainingCount: Int) {
      button.title = "Load \(remainingCount) earlier messages"
    }
  }

  // MARK: - Message Count Cell

  final class NativeMessageCountCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeMessageCountCell")

    private let label = NSTextField(labelWithString: "")

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

      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      label.textColor = NSColor(Color.textTertiary)
      label.alignment = .center
      addSubview(label)

      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: centerXAnchor),
        label.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    func configure(displayedCount: Int, totalCount: Int) {
      label.stringValue = "Showing \(displayedCount) of \(totalCount) messages"
    }
  }

  // MARK: - Live Indicator Cell

  final class NativeLiveIndicatorCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeLiveIndicatorCell")

    private let orbitalHost = NSView()
    private var orbitalLayer: OrbitalAnimationLayer?
    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

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

      // Orbital animation host
      orbitalHost.wantsLayer = true
      orbitalHost.translatesAutoresizingMaskIntoConstraints = false
      addSubview(orbitalHost)

      iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      iconView.contentTintColor = NSColor(Color.statusPermission)
      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.isHidden = true
      addSubview(iconView)

      primaryLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      primaryLabel.translatesAutoresizingMaskIntoConstraints = false
      addSubview(primaryLabel)

      detailLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      detailLabel.textColor = NSColor(Color.textTertiary)
      detailLabel.lineBreakMode = .byTruncatingTail
      detailLabel.translatesAutoresizingMaskIntoConstraints = false
      addSubview(detailLabel)

      let orbitalSize: CGFloat = 20

      NSLayoutConstraint.activate([
        orbitalHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        orbitalHost.centerYAnchor.constraint(equalTo: centerYAnchor),
        orbitalHost.widthAnchor.constraint(equalToConstant: orbitalSize),
        orbitalHost.heightAnchor.constraint(equalToConstant: orbitalSize),

        iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        iconView.widthAnchor.constraint(equalToConstant: 16),

        primaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

        detailLabel.leadingAnchor.constraint(equalTo: primaryLabel.trailingAnchor, constant: Spacing.xs),
        detailLabel.centerYAnchor.constraint(equalTo: primaryLabel.centerYAnchor),
        detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
      ])
    }

    override func layout() {
      super.layout()
      orbitalLayer?.frame = orbitalHost.bounds
    }

    func configure(model: ConversationUtilityRowModels.LiveIndicatorModel) {
      iconView.isHidden = true
      orbitalHost.isHidden = true
      detailLabel.isHidden = true
      primaryLabel.stringValue = ""
      detailLabel.stringValue = ""

      let hasOrbital: Bool
      switch model.barStyle {
        case let .orbiting(colorKey, secondary):
          orbitalHost.isHidden = false
          ensureOrbitalLayer()
          let color = NSColor(ConversationUtilityRowModels.color(for: colorKey)).cgColor
          let secondaryColor = secondary.map { NSColor(ConversationUtilityRowModels.color(for: $0)).cgColor }
          orbitalLayer?.configure(state: .orbiting, color: color, secondaryColor: secondaryColor)
          hasOrbital = true

        case let .holding(colorKey):
          orbitalHost.isHidden = false
          ensureOrbitalLayer()
          let color = NSColor(ConversationUtilityRowModels.color(for: colorKey)).cgColor
          orbitalLayer?.configure(state: .holding, color: color)
          hasOrbital = true

        case let .parked(colorKey):
          orbitalHost.isHidden = false
          ensureOrbitalLayer()
          let color = NSColor(ConversationUtilityRowModels.color(for: colorKey)).cgColor
          orbitalLayer?.configure(state: .parked, color: color)
          hasOrbital = true

        case .none:
          orbitalLayer?.configure(state: .hidden, color: CGColor(gray: 0, alpha: 0))
          hasOrbital = false
      }

      if let iconName = model.iconName {
        iconView.isHidden = false
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        if let iconColorKey = model.iconColorKey {
          iconView.contentTintColor = NSColor(ConversationUtilityRowModels.color(for: iconColorKey))
        }
      }

      primaryLabel.stringValue = model.primaryText
      primaryLabel.textColor = NSColor(ConversationUtilityRowModels.color(for: model.primaryColorKey))
        .withAlphaComponent(0.8)
      primaryLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      updateLabelLeadingConstraint(hasIcon: model.iconName != nil, hasOrbital: hasOrbital)

      if let detailText = model.detailText, !detailText.isEmpty {
        detailLabel.isHidden = false
        detailLabel.stringValue = detailText
        detailLabel.textColor = NSColor(ConversationUtilityRowModels.color(for: model.detailColorKey))
        switch model.detailStyle {
          case .none:
            detailLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .regular)
          case .regular:
            detailLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .regular)
          case .monospaced:
            detailLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
          case .emphasis:
            detailLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .bold)
        }
      }
    }

    private var primaryLeadingConstraint: NSLayoutConstraint?

    private func updateLabelLeadingConstraint(hasIcon: Bool, hasOrbital: Bool) {
      let inset = ConversationLayout.laneHorizontalInset
      primaryLeadingConstraint?.isActive = false
      if hasIcon {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: iconView.trailingAnchor, constant: Spacing.xs
        )
      } else if hasOrbital {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: orbitalHost.trailingAnchor, constant: Spacing.xs
        )
      } else {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: leadingAnchor, constant: inset
        )
      }
      primaryLeadingConstraint?.isActive = true
    }

    private func ensureOrbitalLayer() {
      guard orbitalLayer == nil else { return }
      orbitalHost.layoutSubtreeIfNeeded()
      let layer = OrbitalAnimationLayer()
      layer.frame = orbitalHost.bounds
      orbitalHost.layer?.addSublayer(layer)
      orbitalLayer = layer
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      orbitalLayer?.removeAllOrbitalAnimations()
      orbitalLayer?.removeFromSuperlayer()
      orbitalLayer = nil
    }
  }

  // MARK: - Compact Tool Cell

  final class NativeCompactToolCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeCompactToolCell")

    // Strip card container
    private let stripContainer = NSView()
    private let accentBar = NSView()
    private let glyphImage = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let dotSeparator = NSTextField(labelWithString: "\u{00B7}")
    private let subtitleField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()

    // Detail area (below title row)
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

      // Strip container — rounded card background
      stripContainer.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.wantsLayer = true
      stripContainer.layer?.cornerRadius = CGFloat(Radius.md)
      stripContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
      addSubview(stripContainer)

      // Accent bar — left edge color indicator
      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.wantsLayer = true
      accentBar.layer?.cornerRadius = CGFloat(Radius.xs)
      stripContainer.addSubview(accentBar)

      // Icon
      glyphImage.translatesAutoresizingMaskIntoConstraints = false
      glyphImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
      stripContainer.addSubview(glyphImage)

      // Title — primary identifier (filename, command, pattern)
      titleField.translatesAutoresizingMaskIntoConstraints = false
      titleField.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      titleField.textColor = NSColor(Color.textPrimary)
      titleField.lineBreakMode = .byTruncatingTail
      titleField.maximumNumberOfLines = 1
      titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      stripContainer.addSubview(titleField)

      // Dot separator
      dotSeparator.translatesAutoresizingMaskIntoConstraints = false
      dotSeparator.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      dotSeparator.textColor = NSColor(Color.textQuaternary)
      dotSeparator.setContentCompressionResistancePriority(.required, for: .horizontal)
      dotSeparator.isHidden = true
      stripContainer.addSubview(dotSeparator)

      // Subtitle — secondary context
      subtitleField.translatesAutoresizingMaskIntoConstraints = false
      subtitleField.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      subtitleField.textColor = NSColor(Color.textTertiary)
      subtitleField.lineBreakMode = .byTruncatingTail
      subtitleField.maximumNumberOfLines = 1
      subtitleField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
      subtitleField.isHidden = true
      stripContainer.addSubview(subtitleField)

      // Meta — right-aligned stats
      metaField.translatesAutoresizingMaskIntoConstraints = false
      metaField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
      metaField.textColor = NSColor(Color.textTertiary)
      metaField.lineBreakMode = .byTruncatingTail
      metaField.alignment = .right
      metaField.setContentCompressionResistancePriority(.required, for: .horizontal)
      stripContainer.addSubview(metaField)

      // Chevron — expand indicator
      chevronView.translatesAutoresizingMaskIntoConstraints = false
      chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
      chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
      chevronView.contentTintColor = NSColor(Color.textQuaternary)
      chevronView.alphaValue = 0.25
      stripContainer.addSubview(chevronView)

      // Detail area subviews — positioned below title row inside strip
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

      // Content leading anchor (after icon)
      let contentLeading = glyphImage.trailingAnchor

      NSLayoutConstraint.activate([
        // Strip container — inset from cell edges
        stripContainer.topAnchor.constraint(equalTo: topAnchor, constant: ConversationStripRowMetrics.verticalInset),
        stripContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ConversationStripRowMetrics.verticalInset),
        stripContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        stripContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

        // Accent bar — left edge
        accentBar.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor, constant: ConversationStripRowMetrics.accentLeadingInset),
        accentBar.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.accentVerticalInset),
        accentBar.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor, constant: -ConversationStripRowMetrics.accentVerticalInset),
        accentBar.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.accentWidth),

        // Icon
        glyphImage.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: Spacing.sm),
        glyphImage.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.iconTopInset),
        glyphImage.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.iconSize),

        // Title
        titleField.leadingAnchor.constraint(equalTo: contentLeading, constant: Spacing.xs),
        titleField.centerYAnchor.constraint(equalTo: glyphImage.centerYAnchor),

        // Dot separator
        dotSeparator.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: Spacing.xs),
        dotSeparator.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

        // Subtitle
        subtitleField.leadingAnchor.constraint(equalTo: dotSeparator.trailingAnchor, constant: Spacing.xs),
        subtitleField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
        subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: metaField.leadingAnchor, constant: -Spacing.sm),

        // Meta — right side
        metaField.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -Spacing.sm_),
        metaField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

        // Chevron — far right
        chevronView.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor, constant: -Spacing.md_),
        chevronView.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
        chevronView.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.chevronWidth),

        // When no subtitle, title can stretch to meta
        titleField.trailingAnchor.constraint(lessThanOrEqualTo: metaField.leadingAnchor, constant: -Spacing.sm),

        // Detail area — context below title
        contextField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        contextField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: ConversationStripRowMetrics.detailTopSpacing),
        contextField.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -Spacing.sm),

        // Snippet below context
        snippetField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        snippetField.topAnchor.constraint(equalTo: contextField.bottomAnchor, constant: 0),
        snippetField.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -Spacing.sm),

        // Output preview below title
        outputPreviewField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        outputPreviewField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: ConversationStripRowMetrics.detailTopSpacing),
        outputPreviewField.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -Spacing.sm),

        // Diff bar below snippet
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

    static func requiredHeight(model: NativeCompactToolRowModel, width: CGFloat) -> CGFloat {
      NativeCompactToolRowModel.requiredHeight(for: model, width: width)
    }

    func configure(model: NativeCompactToolRowModel) {
      // Icon + accent bar — tool-colored
      glyphImage.image = NSImage(systemSymbolName: model.glyphSymbol, accessibilityDescription: nil)
      glyphImage.contentTintColor = model.glyphColor.withAlphaComponent(0.8)
      accentBar.layer?.backgroundColor = model.glyphColor.withAlphaComponent(0.6).cgColor
      glyphImage.alphaValue = model.isInProgress ? 0.5 : 1.0

      // Title — monospace for bash commands, system font for everything else
      if model.toolType == .bash {
        titleField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .semibold)
      } else {
        titleField.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      }
      titleField.stringValue = model.summary

      // Subtitle
      if let sub = model.subtitle, !sub.isEmpty {
        dotSeparator.isHidden = false
        subtitleField.isHidden = false
        subtitleField.stringValue = sub
      } else {
        dotSeparator.isHidden = true
        subtitleField.isHidden = true
      }

      // Meta
      if let meta = model.rightMeta {
        metaField.isHidden = false
        metaField.stringValue = meta
      } else {
        metaField.isHidden = true
      }

      // Reset detail fields
      contextField.isHidden = true
      snippetField.isHidden = true
      diffBarContainer.isHidden = true
      outputPreviewField.isHidden = true

      // Per-tool detail rendering
      if let preview = model.diffPreview {
        configureDiffPreview(preview)
      } else if let livePreview = model.liveOutputPreview {
        configureLivePreview(livePreview)
      } else if let items = model.todoItems, !items.isEmpty {
        configureTodoPreview(items)
      } else if let output = model.outputPreview {
        outputPreviewField.stringValue = output
        outputPreviewField.isHidden = false
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onTap = nil
      isHovering = false
      stripContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
      chevronView.alphaValue = 0.25
    }

    private func configureDiffPreview(_ preview: DiffPreviewInfo) {
      if let ctx = preview.contextLine {
        contextField.stringValue = "  \(ctx)"
        contextField.isHidden = false
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
      let color = NSColor(Color.toolBash).withAlphaComponent(0.72)
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
      let attributed = NSMutableAttributedString()
      let font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
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
  }

  // MARK: - Collapsed Turn Cell

  /// Single-line summary of a collapsed turn in focus mode.
  /// Layout: ▸ "User preview..." → "Assistant preview..." (N ops, Xs)
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

      // Strip container
      stripContainer.wantsLayer = true
      stripContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
      stripContainer.layer?.cornerRadius = CGFloat(Radius.md)
      stripContainer.translatesAutoresizingMaskIntoConstraints = false
      addSubview(stripContainer)

      // Accent bar
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

  // MARK: - Live Progress Cell

  /// Shows a progress bar during active work: current operation + completed count + elapsed time.
  final class NativeLiveProgressCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeLiveProgressCell")

    private let orbitalHost = NSView()
    private var orbitalLayer: OrbitalAnimationLayer?
    private let operationLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")

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

      orbitalHost.wantsLayer = true
      orbitalHost.translatesAutoresizingMaskIntoConstraints = false
      addSubview(orbitalHost)

      operationLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .medium)
      operationLabel.textColor = NSColor(Color.statusWorking).withAlphaComponent(0.8)
      operationLabel.lineBreakMode = .byTruncatingTail
      operationLabel.translatesAutoresizingMaskIntoConstraints = false
      addSubview(operationLabel)

      statsLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
      statsLabel.textColor = NSColor(Color.textTertiary)
      statsLabel.alignment = .right
      statsLabel.translatesAutoresizingMaskIntoConstraints = false
      addSubview(statsLabel)

      let orbitalSize: CGFloat = 20

      NSLayoutConstraint.activate([
        orbitalHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        orbitalHost.centerYAnchor.constraint(equalTo: centerYAnchor),
        orbitalHost.widthAnchor.constraint(equalToConstant: orbitalSize),
        orbitalHost.heightAnchor.constraint(equalToConstant: orbitalSize),

        operationLabel.leadingAnchor.constraint(equalTo: orbitalHost.trailingAnchor, constant: Spacing.xs),
        operationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        operationLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsLabel.leadingAnchor, constant: -Spacing.sm),

        statsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        statsLabel.centerYAnchor.constraint(equalTo: operationLabel.centerYAnchor),
      ])
    }

    override func layout() {
      super.layout()
      orbitalLayer?.frame = orbitalHost.bounds
    }

    func configure(model: ConversationUtilityRowModels.LiveProgressModel) {
      operationLabel.stringValue = model.operationText
      statsLabel.stringValue = model.statsText
      ensureOrbitalLayer()
      let primary = NSColor(Color.statusWorking).cgColor
      let secondary = NSColor(Color.composerSteer).cgColor
      orbitalLayer?.configure(state: .orbiting, color: primary, secondaryColor: secondary)
    }

    private func ensureOrbitalLayer() {
      guard orbitalLayer == nil else { return }
      orbitalHost.layoutSubtreeIfNeeded()
      let layer = OrbitalAnimationLayer()
      layer.frame = orbitalHost.bounds
      orbitalHost.layer?.addSublayer(layer)
      orbitalLayer = layer
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      orbitalLayer?.removeAllOrbitalAnimations()
      orbitalLayer?.removeFromSuperlayer()
      orbitalLayer = nil
    }
  }

#endif
