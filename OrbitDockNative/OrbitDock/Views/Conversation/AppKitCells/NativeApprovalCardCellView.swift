//
//  NativeApprovalCardCellView.swift
//  OrbitDock
//
//  Slim macOS approval indicator for the conversation timeline.
//  Detailed interaction lives in the composer's inline pending zone.
//

#if os(macOS)

  import AppKit
  import SwiftUI

  final class NativeApprovalCardCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeApprovalCardCell")

    /// Fixed height for the slim indicator strip (matches compact tool base).
    static let stripHeight: CGFloat = 34

    private let stripContainer = NSView()
    private let accentBar = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let dotLabel = NSTextField(labelWithString: "\u{00B7}")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var currentModel: ApprovalCardModel?
    private var isHovering = false {
      didSet {
        guard isHovering != oldValue else { return }
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.15
          ctx.allowsImplicitAnimation = true
          stripContainer.layer?.backgroundColor = isHovering
            ? NSColor(Color.backgroundSecondary).withAlphaComponent(0.65).cgColor
            : NSColor(Color.backgroundSecondary).withAlphaComponent(0.5).cgColor
          chevronView.animator().alphaValue = isHovering ? 0.6 : 0.25
        }
        if isHovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    }

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

      // Strip container — full-width rounded rect
      stripContainer.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.wantsLayer = true
      stripContainer.layer?.cornerRadius = CGFloat(Radius.md)
      addSubview(stripContainer)

      // Clickable gesture on the whole strip
      let click = NSClickGestureRecognizer(target: self, action: #selector(stripClicked))
      stripContainer.addGestureRecognizer(click)

      // Left accent edge bar (3pt)
      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.wantsLayer = true
      accentBar.layer?.cornerRadius = CGFloat(Radius.xs)
      stripContainer.addSubview(accentBar)

      // Icon
      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.imageScaling = .scaleProportionallyDown
      stripContainer.addSubview(iconView)

      // Title (tool name / mode)
      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      titleLabel.textColor = NSColor(Color.textPrimary)
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
      stripContainer.addSubview(titleLabel)

      // Dot separator
      dotLabel.translatesAutoresizingMaskIntoConstraints = false
      dotLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      dotLabel.textColor = NSColor(Color.textQuaternary)
      dotLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      stripContainer.addSubview(dotLabel)

      // Subtitle (brief summary)
      subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
      subtitleLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      subtitleLabel.textColor = NSColor(Color.textTertiary)
      subtitleLabel.lineBreakMode = .byTruncatingTail
      subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      stripContainer.addSubview(subtitleLabel)

      // Chevron
      chevronView.translatesAutoresizingMaskIntoConstraints = false
      chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
      chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
      chevronView.contentTintColor = NSColor(Color.textQuaternary)
      chevronView.alphaValue = 0.25
      stripContainer.addSubview(chevronView)

      let inset = ConversationLayout.laneHorizontalInset
      NSLayoutConstraint.activate([
        stripContainer.topAnchor.constraint(equalTo: topAnchor, constant: ConversationStripRowMetrics.verticalInset),
        stripContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        stripContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        stripContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ConversationStripRowMetrics.verticalInset),

        accentBar.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.accentVerticalInset),
        accentBar.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor, constant: ConversationStripRowMetrics.accentLeadingInset),
        accentBar.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor, constant: -ConversationStripRowMetrics.accentVerticalInset),
        accentBar.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.accentWidth),

        iconView.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        iconView.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: Spacing.sm),
        iconView.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.iconSize),

        titleLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Spacing.xs),

        dotLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        dotLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: Spacing.xs),

        subtitleLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        subtitleLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: Spacing.xs),
        subtitleLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: chevronView.leadingAnchor, constant: -Spacing.sm
        ),

        chevronView.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        chevronView.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor, constant: -Spacing.md_),
        chevronView.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.chevronWidth),
      ])
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let existing = trackingArea {
        removeTrackingArea(existing)
      }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInActiveApp],
        owner: self,
        userInfo: nil
      )
      addTrackingArea(area)
      trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
      isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
      isHovering = false
    }

    func configure(model: ApprovalCardModel) {
      currentModel = model

      let stripConfig = ApprovalCardConfiguration.stripConfig(for: model)
      let tint = NSColor(stripConfig.iconTint)

      // Background + accent
      stripContainer.layer?.backgroundColor = NSColor(stripConfig.backgroundColor)
        .withAlphaComponent(stripConfig.backgroundOpacity).cgColor
      accentBar.layer?.backgroundColor = tint.withAlphaComponent(stripConfig.accentOpacity).cgColor

      // Icon
      iconView.image = NSImage(systemSymbolName: stripConfig.iconName, accessibilityDescription: nil)
      iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
      iconView.contentTintColor = tint

      titleLabel.stringValue = stripConfig.title
      subtitleLabel.stringValue = stripConfig.subtitle
    }

    @objc private func stripClicked() {
      guard let model = currentModel else { return }
      NotificationCenter.default.post(
        name: .openPendingActionPanel,
        object: nil,
        userInfo: ["sessionId": model.sessionId]
      )
    }

    static func requiredHeight(for model: ApprovalCardModel?, availableWidth: CGFloat) -> CGFloat {
      ConversationStripRowMetrics.totalHeight(forContentHeight: stripHeight)
    }
  }

#endif
