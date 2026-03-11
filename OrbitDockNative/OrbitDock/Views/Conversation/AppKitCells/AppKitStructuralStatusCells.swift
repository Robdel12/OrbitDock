//
//  AppKitStructuralStatusCells.swift
//  OrbitDock
//
//  macOS-specific NSTableCellView subclasses for structural timeline status rows:
//  turn headers, rollup summaries, live indicators, and live progress rows.
//

#if os(macOS)

  import AppKit
  import SwiftUI

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
    private var currentCapsuleColor: NSColor = NSColor(Color.textTertiary)
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

      capsuleBackground.wantsLayer = true
      capsuleBackground.layer?.cornerRadius = ConversationLayout.capsuleCornerRadius
      capsuleBackground.translatesAutoresizingMaskIntoConstraints = false
      addSubview(capsuleBackground)

      iconImage.translatesAutoresizingMaskIntoConstraints = false
      iconImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
      addSubview(iconImage)

      summaryLabel.translatesAutoresizingMaskIntoConstraints = false
      summaryLabel.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
      summaryLabel.textColor = NSColor(Color.textSecondary)
      summaryLabel.lineBreakMode = .byTruncatingTail
      summaryLabel.maximumNumberOfLines = 1
      addSubview(summaryLabel)

      durationLabel.translatesAutoresizingMaskIntoConstraints = false
      durationLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
      durationLabel.textColor = NSColor(Color.textTertiary)
      durationLabel.alignment = .right
      addSubview(durationLabel)

      chevronImage.translatesAutoresizingMaskIntoConstraints = false
      chevronImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
      chevronImage.contentTintColor = NSColor(Color.textQuaternary)
      addSubview(chevronImage)

      NSLayoutConstraint.activate([
        capsuleBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        capsuleBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        capsuleBackground.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        capsuleBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

        iconImage.leadingAnchor.constraint(equalTo: capsuleBackground.leadingAnchor, constant: Spacing.sm),
        iconImage.centerYAnchor.constraint(equalTo: centerYAnchor),
        iconImage.widthAnchor.constraint(equalToConstant: 14),

        summaryLabel.leadingAnchor.constraint(equalTo: iconImage.trailingAnchor, constant: Spacing.sm_),
        summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

        durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: Spacing.sm),
        durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

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

  final class NativeWorkerOrchestrationCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeWorkerOrchestrationCell")

    private let capsuleBackground = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chipsStack = NSStackView()
    private var chipButtons: [NSButton] = []
    private var chipWorkerIDs: [String] = []
    var onSelectWorker: ((String) -> Void)?

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
      capsuleBackground.wantsLayer = true
      capsuleBackground.layer?.cornerRadius = ConversationLayout.cardCornerRadius
      capsuleBackground.layer?.backgroundColor = NSColor(Color.accent).withAlphaComponent(0.08).cgColor
      capsuleBackground.layer?.borderWidth = 1
      capsuleBackground.layer?.borderColor = NSColor(Color.accent).withAlphaComponent(0.12).cgColor
      capsuleBackground.translatesAutoresizingMaskIntoConstraints = false
      addSubview(capsuleBackground)

      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
      titleLabel.textColor = NSColor(Color.textPrimary)
      addSubview(titleLabel)

      subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
      subtitleLabel.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      subtitleLabel.textColor = NSColor(Color.textTertiary)
      addSubview(subtitleLabel)

      chipsStack.orientation = .horizontal
      chipsStack.alignment = .centerY
      chipsStack.spacing = Spacing.xs
      chipsStack.translatesAutoresizingMaskIntoConstraints = false
      addSubview(chipsStack)

      NSLayoutConstraint.activate([
        capsuleBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        capsuleBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        capsuleBackground.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        capsuleBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

        titleLabel.leadingAnchor.constraint(equalTo: capsuleBackground.leadingAnchor, constant: Spacing.md),
        titleLabel.topAnchor.constraint(equalTo: capsuleBackground.topAnchor, constant: Spacing.sm),

        subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

        chipsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        chipsStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: Spacing.sm_),
        chipsStack.trailingAnchor.constraint(lessThanOrEqualTo: capsuleBackground.trailingAnchor, constant: -Spacing.md),
      ])
    }

    func configure(model: ConversationUtilityRowModels.WorkerOrchestrationModel) {
      titleLabel.stringValue = model.titleText
      subtitleLabel.stringValue = model.subtitleText
      chipWorkerIDs = model.workers.map(\.id)

      for button in chipButtons {
        chipsStack.removeArrangedSubview(button)
        button.removeFromSuperview()
      }
      chipButtons.removeAll(keepingCapacity: true)

      for (index, worker) in model.workers.enumerated() {
        let button = NSButton(title: "", target: self, action: #selector(handleChipTap(_:)))
        button.tag = index
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.cornerRadius = ConversationLayout.capsuleCornerRadius
        button.layer?.backgroundColor = NSColor(
          ConversationUtilityRowModels.color(for: worker.statusColorKey)
        ).withAlphaComponent(0.12).cgColor
        button.contentTintColor = NSColor(ConversationUtilityRowModels.color(for: worker.statusColorKey))
        button.attributedTitle = NSAttributedString(
          string: "\(worker.title) · \(worker.statusText)",
          attributes: [
            .font: NSFont.systemFont(ofSize: TypeScale.micro, weight: .semibold),
            .foregroundColor: NSColor(Color.textSecondary),
          ]
        )
        button.image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          button.heightAnchor.constraint(equalToConstant: 22),
        ])
        chipButtons.append(button)
        chipsStack.addArrangedSubview(button)
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      chipWorkerIDs = []
      onSelectWorker = nil
      for button in chipButtons {
        chipsStack.removeArrangedSubview(button)
        button.removeFromSuperview()
      }
      chipButtons.removeAll(keepingCapacity: true)
    }

    @objc private func handleChipTap(_ sender: NSButton) {
      guard sender.tag >= 0, sender.tag < chipWorkerIDs.count else { return }
      onSelectWorker?(chipWorkerIDs[sender.tag])
    }
  }

  final class NativeLiveIndicatorCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeLiveIndicatorCell")
    private static let labelSpacing = Spacing.sm

    private let orbitalHost = NSView()
    private var orbitalLayer: OrbitalAnimationLayer?
    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var primaryLeadingConstraint: NSLayoutConstraint?

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

        primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

        detailLabel.leadingAnchor.constraint(equalTo: primaryLabel.trailingAnchor, constant: Spacing.xs),
        detailLabel.centerYAnchor.constraint(equalTo: primaryLabel.centerYAnchor),
        detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
      ])

      primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset)
      primaryLeadingConstraint?.isActive = true
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

    private func updateLabelLeadingConstraint(hasIcon: Bool, hasOrbital: Bool) {
      let inset = ConversationLayout.laneHorizontalInset
      primaryLeadingConstraint?.isActive = false
      if hasIcon {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: iconView.trailingAnchor, constant: Self.labelSpacing
        )
      } else if hasOrbital {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: orbitalHost.trailingAnchor, constant: Self.labelSpacing
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
