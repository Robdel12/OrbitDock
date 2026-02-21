//
//  NativeRichMessageCellView.swift
//  OrbitDock
//
//  Native table cell for ALL .message rows. Replaces the SwiftUI
//  HostingTableCellView fallback for messages. Zero hosting view instances.
//
//  Structure:
//    - Speaker header: timestamp + glyph + label (26pt fixed height)
//    - Body: NativeMarkdownContentView (deterministic height via NSLayoutManager)
//    - User messages: right-aligned with accent bar
//    - Assistant: left-aligned, optional thinking disclosure
//    - Thinking: purple-tinted, compact
//    - Steer: italic secondary
//    - Shell: green-tinted
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import SwiftUI

// MARK: - Rich Message Row Model

struct NativeRichMessageRowModel {
  let messageID: String
  let speaker: String
  let content: String
  let thinking: String?
  let messageType: MessageType
  let timestamp: Date
  let hasImages: Bool
  let images: [MessageImage]
  /// Whether thinking content is expanded (only relevant for .thinking type)
  var isThinkingExpanded: Bool = false

  /// Max characters to show in collapsed thinking preview (matches SwiftUI)
  static let maxThinkingPreviewLength = 600

  enum MessageType {
    case user
    case assistant
    case thinking
    case steer
    case shell
  }

  /// The display content for this row — truncated for collapsed thinking.
  var displayContent: String {
    if messageType == .thinking, !isThinkingExpanded,
       content.count > Self.maxThinkingPreviewLength
    {
      return String(content.prefix(Self.maxThinkingPreviewLength))
    }
    return content
  }

  /// Whether the thinking content is long enough to truncate.
  var isThinkingLong: Bool {
    messageType == .thinking && content.count > Self.maxThinkingPreviewLength
  }

  var speakerColor: PlatformColor {
    switch messageType {
      case .user:
        PlatformColor(Color.accent).withAlphaComponent(0.8)
      case .assistant:
        PlatformColor(Color.textSecondary)
      case .thinking:
        PlatformColor.calibrated(red: 0.65, green: 0.6, blue: 0.85, alpha: 0.9)
      case .steer:
        PlatformColor(Color.accent).withAlphaComponent(0.85)
      case .shell:
        PlatformColor(Color.accent).withAlphaComponent(0.8)
    }
  }

  var glyphSymbol: String {
    switch messageType {
      case .user: "arrow.right"
      case .assistant: "sparkle"
      case .thinking: "brain.head.profile"
      case .steer: "arrow.turn.down.right"
      case .shell: "terminal"
    }
  }

  var glyphColor: PlatformColor {
    switch messageType {
      case .user: PlatformColor(Color.accent).withAlphaComponent(0.7)
      case .assistant: PlatformColor.white.withAlphaComponent(0.85)
      case .thinking: PlatformColor.calibrated(red: 0.6, green: 0.55, blue: 0.8, alpha: 1)
      case .steer: PlatformColor(Color.accent)
      case .shell: PlatformColor(Color.shellAccent)
    }
  }

  var isUserAligned: Bool {
    messageType == .user || messageType == .shell
  }
}

// MARK: - Cell View

#if os(macOS)

  final class NativeRichMessageCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeRichMessageCell")

    private static let logger = TimelineFileLogger.shared

    // MARK: - Layout Constants

    private static let headerHeight: CGFloat = 26
    private static let laneHorizontalInset = ConversationLayout.laneHorizontalInset
    private static let metadataHorizontalInset = ConversationLayout.metadataHorizontalInset
    private static let headerToBodySpacing = ConversationLayout.headerToBodySpacing
    private static let entryBottomSpacing = ConversationLayout.entryBottomSpacing
    private static let assistantRailMaxWidth = ConversationLayout.assistantRailMaxWidth
    private static let thinkingRailMaxWidth = ConversationLayout.thinkingRailMaxWidth
    private static let userRailMaxWidth = ConversationLayout.userRailMaxWidth

    // User bubble
    private static let userBubbleCornerRadius: CGFloat = Radius.lg
    private static let userBubbleHorizontalPad: CGFloat = 14
    private static let userBubbleVerticalPad: CGFloat = 10
    private static let userAccentBarWidth: CGFloat = EdgeBar.width

    // Image gallery
    private static let imageMaxWidth: CGFloat = 400
    private static let imageMaxHeight: CGFloat = 300
    private static let imageCornerRadius: CGFloat = 10
    private static let imageSpacing: CGFloat = 8
    private static let imageThumbnailSize: CGFloat = 150
    private static let imageHeaderHeight: CGFloat = 32
    private static let imageDimensionLabelHeight: CGFloat = 16
    private static let imageDimensionSpacing: CGFloat = 6

    // Thinking containment
    private static let thinkingCornerRadius: CGFloat = Radius.lg
    private static let thinkingHPad: CGFloat = 16
    private static let thinkingVPadTop: CGFloat = 14
    private static let thinkingVPadBottom: CGFloat = 12
    private static let thinkingColor = NSColor(calibratedRed: 0.65, green: 0.6, blue: 0.85, alpha: 1)
    private static let thinkingShowMoreHeight: CGFloat = 32
    private static let thinkingFadeHeight: CGFloat = 28

    // MARK: - Subviews

    private let headerContainer = FlippedContainerView()
    private let glyphImage = NSImageView()
    private let speakerLabel = NSTextField(labelWithString: "")
    private let bodyContainer = FlippedContainerView()
    private let markdownContentView = NativeMarkdownContentView()

    // User-specific: bubble background + accent bar
    private let bubbleBackground = NSView()
    private let accentBar = NSView()

    // Thinking-specific: purple-tinted containment + show more
    private let thinkingBackground = NSView()
    private let thinkingSeparator = NSView()
    private let thinkingFadeOverlay = NSView()
    private let thinkingShowMoreButton = NSButton(title: "", target: nil, action: nil)

    /// Callback when thinking expansion is toggled. Parent should update model + invalidate row.
    var onThinkingExpandToggle: ((String) -> Void)?

    private var currentModel: NativeRichMessageRowModel?
    private var currentBlocks: [MarkdownBlock] = []
    private var currentImages: [MessageImage] = []

    // MARK: - Init

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    // MARK: - Setup

    private func setup() {
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor

      // Header container
      headerContainer.translatesAutoresizingMaskIntoConstraints = false
      addSubview(headerContainer)

      glyphImage.translatesAutoresizingMaskIntoConstraints = false
      glyphImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
      headerContainer.addSubview(glyphImage)

      speakerLabel.translatesAutoresizingMaskIntoConstraints = false
      speakerLabel.lineBreakMode = .byTruncatingTail
      headerContainer.addSubview(speakerLabel)

      // Body container
      bodyContainer.translatesAutoresizingMaskIntoConstraints = false
      addSubview(bodyContainer)

      // Bubble background (for user messages)
      bubbleBackground.wantsLayer = true
      bubbleBackground.layer?.cornerRadius = Self.userBubbleCornerRadius
      bubbleBackground.layer?.masksToBounds = true
      bubbleBackground.layer?.backgroundColor = NSColor(Color.backgroundTertiary).withAlphaComponent(0.68).cgColor
      bubbleBackground.translatesAutoresizingMaskIntoConstraints = false
      bubbleBackground.isHidden = true

      // Accent bar (for user messages)
      accentBar.wantsLayer = true
      accentBar.layer?.backgroundColor = NSColor(Color.accent).withAlphaComponent(OpacityTier.strong).cgColor
      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.isHidden = true

      // Thinking background (purple-tinted containment)
      thinkingBackground.wantsLayer = true
      thinkingBackground.layer?.backgroundColor = Self.thinkingColor.withAlphaComponent(0.06).cgColor
      thinkingBackground.layer?.cornerRadius = Self.thinkingCornerRadius
      thinkingBackground.layer?.masksToBounds = true
      thinkingBackground.layer?.borderColor = Self.thinkingColor.withAlphaComponent(0.10).cgColor
      thinkingBackground.layer?.borderWidth = 1
      thinkingBackground.translatesAutoresizingMaskIntoConstraints = false
      thinkingBackground.isHidden = true

      // Separator line above "Show more/less"
      thinkingSeparator.wantsLayer = true
      thinkingSeparator.layer?.backgroundColor = Self.thinkingColor.withAlphaComponent(0.12).cgColor
      thinkingSeparator.translatesAutoresizingMaskIntoConstraints = false
      thinkingSeparator.isHidden = true

      // Gradient fade for truncated collapsed content
      thinkingFadeOverlay.wantsLayer = true
      thinkingFadeOverlay.translatesAutoresizingMaskIntoConstraints = false
      thinkingFadeOverlay.isHidden = true

      // Thinking "Show more" button
      thinkingShowMoreButton.isBordered = false
      thinkingShowMoreButton.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      thinkingShowMoreButton.contentTintColor = Self.thinkingColor.withAlphaComponent(0.65)
      thinkingShowMoreButton.target = self
      thinkingShowMoreButton.action = #selector(handleThinkingExpandToggle)
      thinkingShowMoreButton.translatesAutoresizingMaskIntoConstraints = false
      thinkingShowMoreButton.isHidden = true

      // Markdown content
      markdownContentView.translatesAutoresizingMaskIntoConstraints = false

      NSLayoutConstraint.activate([
        headerContainer.topAnchor.constraint(equalTo: topAnchor),
        headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
        headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        headerContainer.heightAnchor.constraint(equalToConstant: Self.headerHeight),

        bodyContainer.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: Self.headerToBodySpacing),
        bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
        bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    // MARK: - Configure

    func configure(model: NativeRichMessageRowModel, width: CGFloat) {
      currentModel = model

      // Configure header
      configureHeader(model: model)

      // Parse markdown — use displayContent (truncated for thinking)
      let style: ContentStyle = model.messageType == .thinking ? .thinking : .standard
      currentBlocks = MarkdownAttributedStringRenderer.parse(model.displayContent, style: style)

      // Configure body based on message type
      rebuildBody(model: model, width: width)

      // ── Diagnostic: detect body overflow ──
      let expectedTotal = Self.requiredHeight(for: width, model: model)
      let maxBodyBottom = bodyContainer.subviews
        .map(\.frame.maxY)
        .max() ?? 0
      let bodyBudget = expectedTotal - Self.headerHeight - Self.headerToBodySpacing - Self.entryBottomSpacing
      let msgType = "\(model.messageType)"
      if maxBodyBottom > bodyBudget + 1 {
        Self.logger.info(
          "⚠️ OVERFLOW rich[\(model.messageID)] \(msgType) "
            + "bodyBudget=\(Self.f(bodyBudget)) maxBody=\(Self.f(maxBodyBottom)) "
            + "overflow=\(Self.f(maxBodyBottom - bodyBudget)) "
            + "expectedTotal=\(Self.f(expectedTotal)) w=\(Self.f(width)) "
            + "blocks=\(currentBlocks.count) chars=\(model.displayContent.count)"
        )
      }
    }

    private func configureHeader(model: NativeRichMessageRowModel) {
      glyphImage.image = NSImage(systemSymbolName: model.glyphSymbol, accessibilityDescription: nil)
      glyphImage.contentTintColor = model.glyphColor

      // Thinking headers are softer — smaller, lighter, less tracking
      let isThinking = model.messageType == .thinking
      let fontSize: CGFloat = isThinking ? 9 : TypeScale.chatLabel
      let fontWeight: NSFont.Weight = isThinking ? .medium : .semibold
      let kern: CGFloat = isThinking ? 0.3 : 0.5

      if let roundedFont = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        .fontDescriptor.withDesign(.rounded)
      {
        speakerLabel.font = NSFont(descriptor: roundedFont, size: fontSize)
          ?? NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
      } else {
        speakerLabel.font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
      }

      // Glyph size: smaller for thinking
      glyphImage.symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: isThinking ? 8 : 10,
        weight: isThinking ? .regular : .medium
      )

      let attrs: [NSAttributedString.Key: Any] = [
        .kern: kern,
        .font: speakerLabel.font as Any,
        .foregroundColor: model.speakerColor,
      ]
      speakerLabel.attributedStringValue = NSAttributedString(string: model.speaker, attributes: attrs)

      // Layout header based on alignment
      configureHeaderLayout(isUserAligned: model.isUserAligned)
    }

    private func configureHeaderLayout(isUserAligned: Bool) {
      // Remove existing header constraints
      for constraint in headerContainer.constraints {
        if constraint.firstItem === glyphImage
          || constraint.firstItem === speakerLabel
        {
          constraint.isActive = false
        }
      }

      if isUserAligned {
        // Right-aligned: ... SPEAKER GLYPH
        NSLayoutConstraint.activate([
          glyphImage.trailingAnchor.constraint(
            equalTo: headerContainer.trailingAnchor,
            constant: -Self.laneHorizontalInset
          ),
          glyphImage.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
          glyphImage.widthAnchor.constraint(equalToConstant: 20),

          speakerLabel.trailingAnchor.constraint(equalTo: glyphImage.leadingAnchor, constant: -Spacing.xs),
          speakerLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
        ])
      } else {
        // Left-aligned: GLYPH SPEAKER ...
        NSLayoutConstraint.activate([
          glyphImage.leadingAnchor.constraint(
            equalTo: headerContainer.leadingAnchor,
            constant: Self.metadataHorizontalInset
          ),
          glyphImage.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
          glyphImage.widthAnchor.constraint(equalToConstant: 20),

          speakerLabel.leadingAnchor.constraint(equalTo: glyphImage.trailingAnchor, constant: Spacing.xs),
          speakerLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
        ])
      }
    }

    // MARK: - Body Layout

    private func rebuildBody(model: NativeRichMessageRowModel, width: CGFloat) {
      bodyContainer.subviews.forEach { $0.removeFromSuperview() }
      bubbleBackground.isHidden = true
      accentBar.isHidden = true
      thinkingBackground.isHidden = true

      let contentWidth: CGFloat

      if model.isUserAligned {
        // User: right-aligned bubble with accent bar
        contentWidth = min(width - Self.laneHorizontalInset * 2, Self.userRailMaxWidth)
        rebuildUserBody(model: model, contentWidth: contentWidth, totalWidth: width)
      } else if model.messageType == .steer {
        // Steer: italic text, left-aligned
        contentWidth = min(width - Self.laneHorizontalInset * 2, Self.assistantRailMaxWidth)
        rebuildSteerBody(model: model, contentWidth: contentWidth)
      } else if model.messageType == .thinking {
        // Thinking: compact, narrower, left-aligned
        contentWidth = min(width - Self.laneHorizontalInset * 2, Self.thinkingRailMaxWidth)
        rebuildThinkingBody(model: model, contentWidth: contentWidth)
      } else {
        // Assistant: markdown content, left-aligned
        contentWidth = min(width - Self.laneHorizontalInset * 2, Self.assistantRailMaxWidth)
        rebuildAssistantBody(model: model, contentWidth: contentWidth)
      }
    }

    private func rebuildAssistantBody(model: NativeRichMessageRowModel, contentWidth: CGFloat) {
      let mdHeight = NativeMarkdownContentView.requiredHeight(for: currentBlocks, width: contentWidth)
      markdownContentView.frame = NSRect(x: Self.laneHorizontalInset, y: 0, width: contentWidth, height: mdHeight)
      markdownContentView.configure(blocks: currentBlocks)
      bodyContainer.addSubview(markdownContentView)

      if !model.images.isEmpty {
        addImageViews(
          images: model.images,
          below: mdHeight,
          leadingX: Self.laneHorizontalInset,
          availableWidth: contentWidth,
          isUserAligned: false
        )
      }
    }

    private func rebuildUserBody(model: NativeRichMessageRowModel, contentWidth: CGFloat, totalWidth: CGFloat) {
      let innerWidth = contentWidth - Self.userBubbleHorizontalPad * 2 - Self.userAccentBarWidth
      let mdHeight = NativeMarkdownContentView.requiredHeight(for: currentBlocks, width: innerWidth)
      let bubbleHeight = mdHeight + Self.userBubbleVerticalPad * 2

      // Position bubble right-aligned
      let bubbleWidth = min(contentWidth, innerWidth + Self.userBubbleHorizontalPad * 2 + Self.userAccentBarWidth)
      let bubbleX = totalWidth - Self.laneHorizontalInset - bubbleWidth

      bubbleBackground.frame = NSRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
      bubbleBackground.isHidden = false
      bodyContainer.addSubview(bubbleBackground)

      // Accent bar on right edge of bubble
      accentBar.frame = NSRect(
        x: bubbleX + bubbleWidth - Self.userAccentBarWidth,
        y: 0,
        width: Self.userAccentBarWidth,
        height: bubbleHeight
      )
      accentBar.isHidden = false
      bodyContainer.addSubview(accentBar)

      // Content inside bubble
      markdownContentView.frame = NSRect(
        x: bubbleX + Self.userBubbleHorizontalPad,
        y: Self.userBubbleVerticalPad,
        width: innerWidth,
        height: mdHeight
      )
      markdownContentView.configure(blocks: currentBlocks)
      bodyContainer.addSubview(markdownContentView)

      if !model.images.isEmpty {
        addImageViews(
          images: model.images,
          below: bubbleHeight,
          leadingX: bubbleX,
          availableWidth: bubbleWidth,
          isUserAligned: true
        )
      }
    }

    private func rebuildSteerBody(model: NativeRichMessageRowModel, contentWidth: CGFloat) {
      let font: NSFont = {
        let descriptor = NSFont.systemFont(ofSize: TypeScale.subhead).fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: TypeScale.subhead)
          ?? NSFont.systemFont(ofSize: TypeScale.subhead)
      }()

      let textView = NSTextView(frame: NSRect(x: Self.laneHorizontalInset, y: 0, width: contentWidth, height: 0))
      textView.drawsBackground = false
      textView.isEditable = false
      textView.isSelectable = true
      textView.textContainerInset = .zero
      textView.textContainer?.lineFragmentPadding = 0

      let para = NSMutableParagraphStyle()
      para.lineSpacing = 3
      let attrStr = NSAttributedString(string: model.content, attributes: [
        .font: font,
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: para,
      ])
      textView.textStorage?.setAttributedString(attrStr)

      let height = NativeMarkdownContentView.measureTextHeight(attrStr, width: contentWidth)
      textView.frame.size.height = height
      bodyContainer.addSubview(textView)
    }

    private func rebuildThinkingBody(model: NativeRichMessageRowModel, contentWidth: CGFloat) {
      let hPad = Self.thinkingHPad
      let vTop = Self.thinkingVPadTop
      let vBottom = Self.thinkingVPadBottom
      let innerWidth = contentWidth - hPad * 2
      let displayBlocks = MarkdownAttributedStringRenderer.parse(model.displayContent, style: .thinking)
      let mdHeight = NativeMarkdownContentView.requiredHeight(for: displayBlocks, width: innerWidth)

      let hasShowMore = model.isThinkingLong
      let isCollapsed = hasShowMore && !model.isThinkingExpanded

      // Bottom area: separator (1pt) + show more button, or just bottom padding
      let bottomZoneHeight: CGFloat = hasShowMore
        ? 1 + Self.thinkingShowMoreHeight
        : 0
      let containerHeight = vTop + mdHeight + vBottom + bottomZoneHeight

      // Purple-tinted background with subtle border
      thinkingBackground.frame = NSRect(
        x: Self.laneHorizontalInset,
        y: 0,
        width: contentWidth,
        height: containerHeight
      )
      thinkingBackground.isHidden = false
      bodyContainer.addSubview(thinkingBackground)

      // Content inside the container
      let contentX = Self.laneHorizontalInset + hPad
      markdownContentView.frame = NSRect(
        x: contentX,
        y: vTop,
        width: innerWidth,
        height: mdHeight
      )
      markdownContentView.configure(blocks: displayBlocks)
      bodyContainer.addSubview(markdownContentView)

      // Gradient fade for collapsed truncated content
      if isCollapsed {
        let fadeY = vTop + mdHeight - Self.thinkingFadeHeight
        thinkingFadeOverlay.frame = NSRect(
          x: Self.laneHorizontalInset,
          y: max(vTop, fadeY),
          width: contentWidth,
          height: Self.thinkingFadeHeight
        )
        // Rebuild gradient layer (size may have changed)
        thinkingFadeOverlay.layer?.sublayers?.removeAll()
        let gradient = CAGradientLayer()
        gradient.frame = thinkingFadeOverlay.bounds
        gradient.colors = [
          NSColor.clear.cgColor,
          Self.thinkingColor.withAlphaComponent(0.06).cgColor,
        ]
        gradient.locations = [0, 1]
        thinkingFadeOverlay.layer?.addSublayer(gradient)
        thinkingFadeOverlay.isHidden = false
        bodyContainer.addSubview(thinkingFadeOverlay)
      } else {
        thinkingFadeOverlay.isHidden = true
      }

      // Separator + "Show more / Show less" button
      if hasShowMore {
        let separatorY = vTop + mdHeight + vBottom
        thinkingSeparator.frame = NSRect(
          x: Self.laneHorizontalInset + hPad,
          y: separatorY,
          width: innerWidth,
          height: 1
        )
        thinkingSeparator.isHidden = false
        bodyContainer.addSubview(thinkingSeparator)

        let buttonTitle = model.isThinkingExpanded ? "Show less" : "Show more\u{2026}"
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: TypeScale.body, weight: .medium),
          .foregroundColor: Self.thinkingColor.withAlphaComponent(0.65),
          .kern: 0.2,
        ]
        thinkingShowMoreButton.attributedTitle = NSAttributedString(string: buttonTitle, attributes: attrs)
        thinkingShowMoreButton.frame = NSRect(
          x: Self.laneHorizontalInset + hPad,
          y: separatorY + 1,
          width: innerWidth,
          height: Self.thinkingShowMoreHeight
        )
        thinkingShowMoreButton.alignment = .left
        thinkingShowMoreButton.isHidden = false
        bodyContainer.addSubview(thinkingShowMoreButton)
      } else {
        thinkingSeparator.isHidden = true
        thinkingShowMoreButton.isHidden = true
      }
    }

    @objc private func handleThinkingExpandToggle() {
      guard let model = currentModel else { return }
      onThinkingExpandToggle?(model.messageID)
    }

    // MARK: - Image Layout

    private func addImageViews(
      images: [MessageImage],
      below yOffset: CGFloat,
      leadingX: CGFloat,
      availableWidth: CGFloat,
      isUserAligned: Bool
    ) {
      guard !images.isEmpty else { return }
      currentImages = images

      var currentY = yOffset + Self.imageSpacing

      // Header bar: [photo icon] N image(s) • total size
      let header = makeImageHeaderBar(
        imageCount: images.count,
        totalBytes: images.reduce(0) { $0 + $1.byteCount },
        width: availableWidth
      )
      header.frame.origin = CGPoint(x: leadingX, y: currentY)
      bodyContainer.addSubview(header)
      currentY += Self.imageHeaderHeight + Self.imageSpacing

      if images.count == 1 {
        let image = images[0]
        guard let cached = ImageCache.shared.cachedImage(for: image) else { return }
        let nsImage = cached.displayImage

        let aspect = nsImage.size.width / max(nsImage.size.height, 1)
        let displayWidth = min(Self.imageMaxWidth, availableWidth)
        let displayHeight = min(Self.imageMaxHeight, displayWidth / aspect)
        let finalWidth = displayHeight * aspect

        let imageX: CGFloat = isUserAligned
          ? leadingX + availableWidth - finalWidth
          : leadingX

        // Shadow container + clipped image inside
        let container = makeImageContainer(
          frame: NSRect(x: imageX, y: currentY, width: finalWidth, height: displayHeight),
          shadowRadius: 8, shadowOffset: 4, shadowOpacity: 0.3
        )
        let imageView = makeClippedImageView(in: container)
        imageView.image = nsImage
        addFullscreenClick(to: container, imageIndex: 0)
        bodyContainer.addSubview(container)

        currentY += displayHeight + Self.imageDimensionSpacing

        // Dimension + size label (original pixel dimensions, not display-scaled)
        let dimText = Self.formatDimensions(
          width: cached.originalWidth,
          height: cached.originalHeight,
          bytes: image.byteCount
        )
        let dimLabel = Self.makeDimensionLabel(text: dimText)
        let labelWidth = dimLabel.intrinsicContentSize.width
        let labelX: CGFloat = isUserAligned
          ? leadingX + availableWidth - labelWidth
          : leadingX
        dimLabel.frame = NSRect(x: labelX, y: currentY, width: labelWidth, height: Self.imageDimensionLabelHeight)
        bodyContainer.addSubview(dimLabel)
      } else {
        var x: CGFloat = leadingX
        var y = currentY

        for (index, image) in images.enumerated() {
          guard let nsImage = ImageCache.shared.image(for: image) else { continue }

          let size = Self.imageThumbnailSize
          if x + size > leadingX + availableWidth, x > leadingX {
            x = leadingX
            y += size + Self.imageSpacing
          }

          let container = makeImageContainer(
            frame: NSRect(x: x, y: y, width: size, height: size),
            shadowRadius: 6, shadowOffset: 3, shadowOpacity: 0.25
          )
          let imageView = makeClippedImageView(in: container)
          imageView.image = nsImage
          imageView.imageScaling = .scaleProportionallyUpOrDown
          addFullscreenClick(to: container, imageIndex: index)
          bodyContainer.addSubview(container)

          // Number badge
          let badge = Self.makeNumberBadge(number: index + 1)
          let badgeSize: CGFloat = 22
          badge.frame = NSRect(x: x + size - badgeSize - 8, y: y + 8, width: badgeSize, height: badgeSize)
          bodyContainer.addSubview(badge)

          x += size + Self.imageSpacing
        }
      }
    }

    /// Container view that renders the shadow (masksToBounds = false).
    private func makeImageContainer(
      frame: CGRect,
      shadowRadius: CGFloat,
      shadowOffset: CGFloat,
      shadowOpacity: Float
    ) -> NSView {
      let container = NSView(frame: frame)
      container.wantsLayer = true
      container.layer?.cornerRadius = Self.imageCornerRadius
      container.layer?.shadowColor = NSColor.black.cgColor
      container.layer?.shadowRadius = shadowRadius
      container.layer?.shadowOffset = CGSize(width: 0, height: -shadowOffset)
      container.layer?.shadowOpacity = shadowOpacity
      container.layer?.shadowPath = CGPath(
        roundedRect: CGRect(origin: .zero, size: frame.size),
        cornerWidth: Self.imageCornerRadius,
        cornerHeight: Self.imageCornerRadius,
        transform: nil
      )
      return container
    }

    /// Image view inside a container — clips to rounded rect + thin border.
    private func makeClippedImageView(in container: NSView) -> NSImageView {
      let iv = NSImageView(frame: container.bounds)
      iv.imageScaling = .scaleProportionallyUpOrDown
      iv.wantsLayer = true
      iv.layer?.cornerRadius = Self.imageCornerRadius
      iv.layer?.masksToBounds = true
      iv.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
      iv.layer?.borderWidth = 1
      container.addSubview(iv)
      return iv
    }

    /// Header bar: [photo icon] N image(s) • total size
    private func makeImageHeaderBar(imageCount: Int, totalBytes: Int, width: CGFloat) -> NSView {
      let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Self.imageHeaderHeight))
      bar.wantsLayer = true
      bar.layer?.cornerRadius = 8
      bar.layer?.backgroundColor = NSColor(Color.backgroundTertiary).withAlphaComponent(0.5).cgColor

      // Icon
      let icon = NSImageView(frame: NSRect(x: 12, y: 8, width: 16, height: 16))
      icon.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
      icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      icon.contentTintColor = NSColor.secondaryLabelColor
      bar.addSubview(icon)

      // "N image(s) • size"
      let countText = imageCount == 1 ? "1 image" : "\(imageCount) images"
      let sizeText = Self.formatBytes(totalBytes)

      let label = NSTextField(labelWithString: "\(countText)  \u{00B7}  \(sizeText)")
      label.font = .systemFont(ofSize: 12, weight: .medium)
      label.textColor = NSColor.secondaryLabelColor
      label.sizeToFit()
      label.frame.origin = CGPoint(x: 34, y: (Self.imageHeaderHeight - label.frame.height) / 2)
      bar.addSubview(label)

      return bar
    }

    /// Monospaced dimension label: "1234 × 567 • 50.3 KB"
    private static func makeDimensionLabel(text: String) -> NSTextField {
      let label = NSTextField(labelWithString: text)
      label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
      label.textColor = NSColor(Color.textQuaternary)
      label.sizeToFit()
      return label
    }

    /// Circular number badge for multi-image thumbnails.
    private static func makeNumberBadge(number: Int) -> NSView {
      let size: CGFloat = 22
      let badge = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
      badge.wantsLayer = true
      badge.layer?.cornerRadius = size / 2
      badge.layer?.backgroundColor = NSColor(Color.accent).withAlphaComponent(0.9).cgColor

      let label = NSTextField(labelWithString: "\(number)")
      label.font = .systemFont(ofSize: 11, weight: .bold)
      label.textColor = .white
      label.alignment = .center
      label.sizeToFit()
      label.frame = NSRect(
        x: (size - label.frame.width) / 2,
        y: (size - label.frame.height) / 2,
        width: label.frame.width,
        height: label.frame.height
      )
      badge.addSubview(label)
      return badge
    }

    private static func formatDimensions(width: Int, height: Int, bytes: Int) -> String {
      "\(width) \u{00D7} \(height)  \u{00B7}  \(formatBytes(bytes))"
    }

    private static func formatBytes(_ bytes: Int) -> String {
      if bytes < 1_024 {
        "\(bytes) B"
      } else if bytes < 1_024 * 1_024 {
        String(format: "%.1f KB", Double(bytes) / 1_024)
      } else {
        String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
      }
    }

    /// Click handler to open fullscreen image viewer.
    private func addFullscreenClick(to container: NSView, imageIndex: Int) {
      let click = NSClickGestureRecognizer(target: self, action: #selector(imageContainerClicked(_:)))
      container.addGestureRecognizer(click)
      // Store index via accessibility identifier
      container.identifier = NSUserInterfaceItemIdentifier("imageContainer_\(imageIndex)")
    }

    @objc private func imageContainerClicked(_ gesture: NSClickGestureRecognizer) {
      guard let container = gesture.view,
            let idStr = container.identifier?.rawValue,
            let indexStr = idStr.split(separator: "_").last,
            let index = Int(indexStr),
            !currentImages.isEmpty,
            let presenter = self.window?.contentViewController
      else { return }

      let fullscreen = ImageFullscreen(images: currentImages, currentIndex: index)
      let hostingController = NSHostingController(rootView: fullscreen)
      // Set dismiss after creation so the closure can capture hostingController
      hostingController.rootView.onDismiss = { [weak hostingController] in
        guard let window = hostingController?.view.window else { return }
        window.sheetParent?.endSheet(window)
      }
      presenter.presentAsSheet(hostingController)
    }

    static func imageBlockHeight(for images: [MessageImage], availableWidth: CGFloat) -> CGFloat {
      guard !images.isEmpty else { return 0 }

      // Header bar
      let headerTotal = imageSpacing + imageHeaderHeight + imageSpacing

      if images.count == 1 {
        let image = images[0]
        guard let nsImage = ImageCache.shared.image(for: image) else { return 0 }
        let aspect = nsImage.size.width / max(nsImage.size.height, 1)
        let displayWidth = min(imageMaxWidth, availableWidth)
        let displayHeight = min(imageMaxHeight, displayWidth / aspect)
        return headerTotal + displayHeight + imageDimensionSpacing + imageDimensionLabelHeight
      } else {
        let size = imageThumbnailSize
        let cols = max(1, Int((availableWidth + imageSpacing) / (size + imageSpacing)))
        let rows = (images.count + cols - 1) / cols
        let gridHeight = CGFloat(rows) * size + CGFloat(max(0, rows - 1)) * imageSpacing
        return headerTotal + gridHeight
      }
    }

    // MARK: - Height Calculation (Deterministic)

    /// Calculate required height for this cell given width and model.
    /// Fully deterministic — no SwiftUI measurement involved.
    static func requiredHeight(for width: CGFloat, model: NativeRichMessageRowModel) -> CGFloat {
      guard width > 1 else { return 1 }

      let style: ContentStyle = model.messageType == .thinking ? .thinking : .standard
      let blocks = MarkdownAttributedStringRenderer.parse(model.displayContent, style: style)
      let bodyHeight: CGFloat

      if model.isUserAligned {
        let contentWidth = min(width - laneHorizontalInset * 2, userRailMaxWidth)
        let innerWidth = contentWidth - userBubbleHorizontalPad * 2 - userAccentBarWidth
        let mdHeight = NativeMarkdownContentView.requiredHeight(for: blocks, width: innerWidth)
        let bubbleHeight = mdHeight + userBubbleVerticalPad * 2
        let imgHeight = imageBlockHeight(for: model.images, availableWidth: contentWidth)
        bodyHeight = bubbleHeight + imgHeight
      } else if model.messageType == .steer {
        let contentWidth = min(width - laneHorizontalInset * 2, assistantRailMaxWidth)
        let font: NSFont = {
          let descriptor = NSFont.systemFont(ofSize: TypeScale.subhead).fontDescriptor.withSymbolicTraits(.italic)
          return NSFont(descriptor: descriptor, size: TypeScale.subhead)
            ?? NSFont.systemFont(ofSize: TypeScale.subhead)
        }()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attrStr = NSAttributedString(string: model.content, attributes: [
          .font: font,
          .foregroundColor: NSColor.secondaryLabelColor,
          .paragraphStyle: para,
        ])
        bodyHeight = NativeMarkdownContentView.measureTextHeight(attrStr, width: contentWidth)
      } else if model.messageType == .thinking {
        let contentWidth = min(width - laneHorizontalInset * 2, thinkingRailMaxWidth)
        let innerWidth = contentWidth - thinkingHPad * 2
        let mdHeight = NativeMarkdownContentView.requiredHeight(for: blocks, width: innerWidth)
        let bottomZoneHeight: CGFloat = model.isThinkingLong
          ? 1 + thinkingShowMoreHeight // separator + button
          : 0
        bodyHeight = thinkingVPadTop + mdHeight + thinkingVPadBottom + bottomZoneHeight
      } else {
        let contentWidth = min(width - laneHorizontalInset * 2, assistantRailMaxWidth)
        let mdHeight = NativeMarkdownContentView.requiredHeight(for: blocks, width: contentWidth)
        let imgHeight = imageBlockHeight(for: model.images, availableWidth: contentWidth)
        bodyHeight = mdHeight + imgHeight
      }

      let total = max(1, ceil(headerHeight + headerToBodySpacing + bodyHeight + entryBottomSpacing))
      logger.debug(
        "requiredHeight-rich[\(model.messageID)] \(model.messageType) "
          + "body=\(f(bodyHeight)) total=\(f(total)) w=\(f(width)) "
          + "blocks=\(blocks.count) chars=\(model.displayContent.count)"
      )
      return total
    }

    private static func f(_ v: CGFloat) -> String {
      String(format: "%.1f", v)
    }
  }

  // MARK: - Flipped Container (top-left origin)

  private final class FlippedContainerView: NSView {
    override var isFlipped: Bool {
      true
    }
  }

#endif
