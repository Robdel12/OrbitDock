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

    /// Fixed height for the slim indicator strip.
    static let stripHeight: CGFloat = 36

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
          stripContainer.animator().alphaValue = isHovering ? 1.0 : 0.92
          chevronView.animator().alphaValue = isHovering ? 0.7 : 0.3
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
      stripContainer.alphaValue = 0.92
      addSubview(stripContainer)

      // Clickable gesture on the whole strip
      let click = NSClickGestureRecognizer(target: self, action: #selector(stripClicked))
      stripContainer.addGestureRecognizer(click)

      // Left accent edge bar (3pt)
      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.wantsLayer = true
      accentBar.layer?.cornerRadius = 1.5
      stripContainer.addSubview(accentBar)

      // Icon
      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.imageScaling = .scaleProportionallyDown
      stripContainer.addSubview(iconView)

      // Title (tool name / mode)
      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
      titleLabel.textColor = NSColor(Color.textPrimary)
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
      stripContainer.addSubview(titleLabel)

      // Dot separator
      dotLabel.translatesAutoresizingMaskIntoConstraints = false
      dotLabel.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      dotLabel.textColor = NSColor(Color.textQuaternary)
      dotLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      stripContainer.addSubview(dotLabel)

      // Subtitle (brief summary)
      subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
      subtitleLabel.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      subtitleLabel.textColor = NSColor(Color.textTertiary)
      subtitleLabel.lineBreakMode = .byTruncatingTail
      subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      stripContainer.addSubview(subtitleLabel)

      // Chevron
      chevronView.translatesAutoresizingMaskIntoConstraints = false
      chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
      chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.mini, weight: .bold)
      chevronView.contentTintColor = NSColor(Color.textQuaternary)
      chevronView.alphaValue = 0.3
      stripContainer.addSubview(chevronView)

      let inset = ConversationLayout.laneHorizontalInset
      let hPad = CGFloat(Spacing.sm)
      NSLayoutConstraint.activate([
        stripContainer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        stripContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        stripContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        stripContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

        accentBar.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: 6),
        accentBar.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor, constant: 6),
        accentBar.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor, constant: -6),
        accentBar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        iconView.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        iconView.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: hPad),
        iconView.widthAnchor.constraint(equalToConstant: 13),
        iconView.heightAnchor.constraint(equalToConstant: 13),

        titleLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),

        dotLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        dotLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 5),

        subtitleLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        subtitleLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: 5),
        subtitleLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: chevronView.leadingAnchor, constant: -hPad
        ),

        chevronView.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        chevronView.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor, constant: -hPad),
        chevronView.widthAnchor.constraint(equalToConstant: 8),
        chevronView.heightAnchor.constraint(equalToConstant: 10),
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

      let header = ApprovalCardConfiguration.headerConfig(for: model, mode: model.mode)
      let tint = NSColor(model.risk.tintColor)

      // Background + accent
      stripContainer.layer?.backgroundColor = NSColor(Color.backgroundSecondary).withAlphaComponent(0.5).cgColor
      accentBar.layer?.backgroundColor = tint.withAlphaComponent(0.72).cgColor

      // Icon
      iconView.image = NSImage(systemSymbolName: header.iconName, accessibilityDescription: nil)
      iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.micro, weight: .semibold)
      iconView.contentTintColor = tint

      // Title: tool name or mode label
      titleLabel.stringValue = switch model.mode {
        case .permission: model.toolName ?? "Tool"
        case .question: "Question"
        case .takeover: model.toolName ?? "Takeover"
        case .none: ""
      }

      // Subtitle: brief context
      subtitleLabel.stringValue = switch model.mode {
        case .permission:
          ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model).count > 1
            ? "\(ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model).count)-step chain awaiting approval"
            : "Awaiting approval"
        case .question:
          model.questions.count > 1
            ? "\(model.questions.count) questions waiting"
            : "Awaiting your response"
        case .takeover: "Manual takeover required"
        case .none: ""
      }
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
      stripHeight + 8 // 4pt top + 4pt bottom inset
    }
  }

#endif
