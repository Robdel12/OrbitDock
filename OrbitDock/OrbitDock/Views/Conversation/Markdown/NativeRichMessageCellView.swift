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

// MARK: - Cell View

#if os(macOS)

  final class NativeRichMessageCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeRichMessageCell")

    private static let logger = TimelineFileLogger.shared

    // MARK: - Layout Constants

    /// Header height when visible — glyph only, no label (except error)
    private static let headerHeight = ConversationRichMessageLayout.headerHeight
    private static let laneHorizontalInset = ConversationRichMessageLayout.laneHorizontalInset
    private static let metadataHorizontalInset = ConversationRichMessageLayout.metadataHorizontalInset
    private static let headerToBodySpacing = ConversationRichMessageLayout.headerToBodySpacing
    private static let entryBottomSpacing = ConversationRichMessageLayout.entryBottomSpacing
    private static let assistantRailMaxWidth = ConversationRichMessageLayout.assistantRailMaxWidth
    private static let thinkingRailMaxWidth = ConversationRichMessageLayout.thinkingRailMaxWidth
    private static let userRailMaxWidth = ConversationRichMessageLayout.userRailMaxWidth

    // User bubble
    private static let userBubbleCornerRadius: CGFloat = Radius.lg
    private static let userBubbleHorizontalPad = ConversationRichMessageLayout.userBubbleHorizontalPad
    private static let userBubbleVerticalPad = ConversationRichMessageLayout.userBubbleVerticalPad
    private static let userAccentBarWidth = ConversationRichMessageLayout.userAccentBarWidth

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
    private static let thinkingHPad = ConversationRichMessageLayout.thinkingHPad
    private static let thinkingVPadTop = ConversationRichMessageLayout.thinkingVPadTop
    private static let thinkingVPadBottom = ConversationRichMessageLayout.thinkingVPadBottom
    private static let thinkingColor = NSColor(Color.textTertiary)
    private static let thinkingShowMoreHeight = ConversationRichMessageLayout.thinkingShowMoreHeight
    private static let thinkingFadeHeight = ConversationRichMessageLayout.thinkingFadeHeight

    // Error containment
    private static let errorCornerRadius: CGFloat = Radius.lg
    private static let errorHPad = ConversationRichMessageLayout.errorHPad
    private static let errorVPadTop = ConversationRichMessageLayout.errorVPadTop
    private static let errorVPadBottom = ConversationRichMessageLayout.errorVPadBottom
    private static let errorAccentBarWidth = ConversationRichMessageLayout.errorAccentBarWidth
    private static let errorColor = NSColor(Color.statusPermission)

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

    // Error-specific: coral-tinted containment + accent bar
    private let errorBackground = NSView()
    private let errorAccentBar = NSView()

    /// Callback when thinking expansion is toggled. Parent should update model + invalidate row.
    var onThinkingExpandToggle: ((String) -> Void)?

    private var currentModel: NativeRichMessageRowModel?
    private var currentBlocks: [MarkdownBlock] = []
    private var currentImages: [MessageImage] = []
    private var currentContentStyle: ContentStyle = .standard

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
      bubbleBackground.layer?.backgroundColor = NSColor(Color.accent).withAlphaComponent(0.04).cgColor
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

      // Error background (coral-tinted containment)
      errorBackground.wantsLayer = true
      errorBackground.layer?.backgroundColor = Self.errorColor.withAlphaComponent(0.08).cgColor
      errorBackground.layer?.cornerRadius = Self.errorCornerRadius
      errorBackground.layer?.masksToBounds = true
      errorBackground.layer?.borderColor = Self.errorColor.withAlphaComponent(0.10).cgColor
      errorBackground.layer?.borderWidth = 1
      errorBackground.translatesAutoresizingMaskIntoConstraints = false
      errorBackground.isHidden = true

      // Error accent bar (solid coral on left edge)
      errorAccentBar.wantsLayer = true
      errorAccentBar.layer?.backgroundColor = Self.errorColor.cgColor
      errorAccentBar.translatesAutoresizingMaskIntoConstraints = false
      errorAccentBar.isHidden = true

      // Markdown content
      markdownContentView.wantsLayer = true
      markdownContentView.translatesAutoresizingMaskIntoConstraints = false

      headerHeightConstraint = headerContainer.heightAnchor.constraint(equalToConstant: Self.headerHeight)
      bodyTopConstraint = bodyContainer.topAnchor.constraint(
        equalTo: headerContainer.bottomAnchor, constant: Self.headerToBodySpacing
      )

      NSLayoutConstraint.activate([
        headerContainer.topAnchor.constraint(equalTo: topAnchor),
        headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
        headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        headerHeightConstraint!,

        bodyTopConstraint!,
        bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
        bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    private var headerHeightConstraint: NSLayoutConstraint?
    private var bodyTopConstraint: NSLayoutConstraint?

    // MARK: - Configure

    func configure(model: NativeRichMessageRowModel, width: CGFloat) {
      currentModel = model
      let presentation = ConversationRichMessageLayout.presentation(for: model)

      // Configure header
      configureHeader(model: model, presentation: presentation)

      // Adjust header height + body spacing based on showHeader
      if presentation.header.isVisible {
        headerHeightConstraint?.constant = Self.headerHeight
        bodyTopConstraint?.constant = Self.headerToBodySpacing
      } else {
        headerHeightConstraint?.constant = 0
        bodyTopConstraint?.constant = 0
      }

      // Parse markdown — use displayContent (truncated for thinking)
      currentContentStyle = presentation.contentStyle
      currentBlocks = MarkdownSystemParser.parse(model.displayContent, style: presentation.contentStyle)

      // Configure body based on message type
      rebuildBody(model: model, presentation: presentation, width: width)

      // ── Diagnostic: detect body overflow ──
      let expectedTotal = ConversationRichMessageLayout.requiredHeight(
        for: width,
        model: model,
        blocks: currentBlocks
      ) { availableWidth in
        Self.imageBlockHeight(for: model.images, availableWidth: availableWidth)
      }
      let maxBodyBottom = bodyContainer.subviews
        .map(\.frame.maxY)
        .max() ?? 0
      let actualHeaderHeight = presentation.actualHeaderHeight
      let actualSpacing = presentation.actualHeaderSpacing
      let bodyBudget = expectedTotal - actualHeaderHeight - actualSpacing - Self.entryBottomSpacing
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

    private func configureHeader(model: NativeRichMessageRowModel, presentation: RichMessagePresentation) {
      let header = presentation.header
      if !header.isVisible {
        headerContainer.isHidden = true
        return
      }
      headerContainer.isHidden = false

      glyphImage.image = NSImage(systemSymbolName: header.glyphSymbol, accessibilityDescription: nil)
      glyphImage.contentTintColor = header.glyphColor
      glyphImage.symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: header.glyphPointSize,
        weight: header.glyphWeight.platformWeight
      )

      if let labelText = header.labelText, let labelAttributes = header.labelAttributes {
        speakerLabel.isHidden = false
        speakerLabel.attributedStringValue = NSAttributedString(string: labelText, attributes: labelAttributes)
      } else {
        speakerLabel.isHidden = true
      }

      configureHeaderLayout(isRightAligned: header.isRightAligned, glyphFrameSize: header.glyphFrameSize)
    }

    private func configureHeaderLayout(isRightAligned: Bool, glyphFrameSize: CGFloat) {
      // Remove existing header constraints
      for constraint in headerContainer.constraints {
        if constraint.firstItem === glyphImage
          || constraint.firstItem === speakerLabel
        {
          constraint.isActive = false
        }
      }

      if isRightAligned {
        // Right-aligned: ... SPEAKER GLYPH
        NSLayoutConstraint.activate([
          glyphImage.trailingAnchor.constraint(
            equalTo: headerContainer.trailingAnchor,
            constant: -Self.laneHorizontalInset
          ),
          glyphImage.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
          glyphImage.widthAnchor.constraint(equalToConstant: glyphFrameSize),

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
          glyphImage.widthAnchor.constraint(equalToConstant: glyphFrameSize),

          speakerLabel.leadingAnchor.constraint(equalTo: glyphImage.trailingAnchor, constant: Spacing.xs),
          speakerLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
        ])
      }
    }

    // MARK: - Body Layout

    private func rebuildBody(model: NativeRichMessageRowModel, presentation: RichMessagePresentation, width: CGFloat) {
      bodyContainer.subviews.forEach { $0.removeFromSuperview() }
      bubbleBackground.isHidden = true
      accentBar.isHidden = true
      thinkingBackground.isHidden = true
      errorBackground.isHidden = true
      errorAccentBar.isHidden = true
      markdownContentView.layer?.mask = nil

      let contentWidth = ConversationRichMessageLayout.contentWidth(for: width, presentation: presentation)

      switch presentation.bodyChrome {
        case .assistant:
          rebuildAssistantBody(model: model, contentWidth: contentWidth)

        case let .userBubble(horizontalPadding, verticalPadding, accentBarWidth):
          rebuildUserBody(
            model: model,
            contentWidth: contentWidth,
            totalWidth: width,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            accentBarWidth: accentBarWidth
          )

        case let .steer(lineSpacing):
          rebuildSteerBody(model: model, contentWidth: contentWidth, lineSpacing: lineSpacing)

        case let .thinking(horizontalPadding, verticalTop, verticalBottom, footerHeight, fadeHeight):
          rebuildThinkingBody(
            model: model,
            contentWidth: contentWidth,
            horizontalPadding: horizontalPadding,
            verticalTop: verticalTop,
            verticalBottom: verticalBottom,
            footerHeight: footerHeight,
            fadeHeight: fadeHeight,
            buttonTitle: presentation.thinkingButtonTitle
          )

        case let .error(horizontalPadding, verticalTop, verticalBottom, accentBarWidth):
          rebuildErrorBody(
            model: model,
            contentWidth: contentWidth,
            horizontalPadding: horizontalPadding,
            verticalTop: verticalTop,
            verticalBottom: verticalBottom,
            accentBarWidth: accentBarWidth
          )
      }
    }

    private func rebuildAssistantBody(model: NativeRichMessageRowModel, contentWidth: CGFloat) {
      let mdHeight = NativeMarkdownContentView.requiredHeight(
        for: currentBlocks,
        width: contentWidth,
        style: currentContentStyle
      )
      markdownContentView.frame = NSRect(x: Self.laneHorizontalInset, y: 0, width: contentWidth, height: mdHeight)
      markdownContentView.configure(blocks: currentBlocks, style: currentContentStyle)
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

    private func rebuildUserBody(
      model: NativeRichMessageRowModel,
      contentWidth: CGFloat,
      totalWidth: CGFloat,
      horizontalPadding: CGFloat,
      verticalPadding: CGFloat,
      accentBarWidth: CGFloat
    ) {
      let innerWidth = contentWidth - horizontalPadding * 2 - accentBarWidth
      let mdHeight = NativeMarkdownContentView.requiredHeight(
        for: currentBlocks,
        width: innerWidth,
        style: currentContentStyle
      )
      let bubbleHeight = mdHeight + verticalPadding * 2

      // Position bubble right-aligned
      let bubbleWidth = min(contentWidth, innerWidth + horizontalPadding * 2 + accentBarWidth)
      let bubbleX = totalWidth - Self.laneHorizontalInset - bubbleWidth

      bubbleBackground.frame = NSRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
      bubbleBackground.isHidden = false
      bodyContainer.addSubview(bubbleBackground)

      // Accent bar on right edge of bubble
      accentBar.frame = NSRect(
        x: bubbleX + bubbleWidth - accentBarWidth,
        y: 0,
        width: accentBarWidth,
        height: bubbleHeight
      )
      accentBar.isHidden = false
      bodyContainer.addSubview(accentBar)

      // Content inside bubble
      markdownContentView.frame = NSRect(
        x: bubbleX + horizontalPadding,
        y: verticalPadding,
        width: innerWidth,
        height: mdHeight
      )
      markdownContentView.configure(blocks: currentBlocks, style: currentContentStyle)
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

    private func rebuildSteerBody(model: NativeRichMessageRowModel, contentWidth: CGFloat, lineSpacing: CGFloat) {
      let textView = NSTextView(frame: NSRect(x: Self.laneHorizontalInset, y: 0, width: contentWidth, height: 0))
      textView.drawsBackground = false
      textView.isEditable = false
      textView.isSelectable = true
      textView.textContainerInset = .zero
      textView.textContainer?.lineFragmentPadding = 0

      let attrStr = ConversationRichMessageLayout.steerAttributedText(model.content, lineSpacing: lineSpacing)
      textView.textStorage?.setAttributedString(attrStr)

      let height = NativeMarkdownContentView.measureTextHeight(attrStr, width: contentWidth)
      textView.frame.size.height = height
      bodyContainer.addSubview(textView)
    }

    private func rebuildThinkingBody(
      model: NativeRichMessageRowModel,
      contentWidth: CGFloat,
      horizontalPadding: CGFloat,
      verticalTop: CGFloat,
      verticalBottom: CGFloat,
      footerHeight: CGFloat,
      fadeHeight: CGFloat,
      buttonTitle: String?
    ) {
      let innerWidth = contentWidth - horizontalPadding * 2
      let mdHeight = NativeMarkdownContentView.requiredHeight(for: currentBlocks, width: innerWidth, style: .thinking)

      let hasShowMore = buttonTitle != nil
      let isCollapsed = hasShowMore && !model.isThinkingExpanded

      // Bottom area: show more button only (fade mask handles the transition)
      let bottomZoneHeight: CGFloat = hasShowMore ? footerHeight : 0
      let containerHeight = verticalTop + mdHeight + verticalBottom + bottomZoneHeight

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
      let contentX = Self.laneHorizontalInset + horizontalPadding
      markdownContentView.frame = NSRect(
        x: contentX,
        y: verticalTop,
        width: innerWidth,
        height: mdHeight
      )
      markdownContentView.configure(blocks: currentBlocks, style: .thinking)
      bodyContainer.addSubview(markdownContentView)

      // Gradient mask: fade text to transparent over the last lines when collapsed
      if isCollapsed {
        let maskLayer = CAGradientLayer()
        maskLayer.frame = markdownContentView.bounds
        let fadeStart = max(0, 1.0 - Double(fadeHeight) / Double(mdHeight))
        maskLayer.colors = [
          NSColor.white.cgColor,
          NSColor.white.cgColor,
          NSColor.clear.cgColor,
        ]
        maskLayer.locations = [0, NSNumber(value: fadeStart), 1.0]
        markdownContentView.layer?.mask = maskLayer
      }

      thinkingFadeOverlay.isHidden = true
      thinkingSeparator.isHidden = true

      // "Show more / Show less" button
      if let buttonTitle {
        let buttonY = verticalTop + mdHeight + verticalBottom
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: TypeScale.body, weight: .medium),
          .foregroundColor: Self.thinkingColor.withAlphaComponent(0.65),
          .kern: 0.2,
        ]
        thinkingShowMoreButton.attributedTitle = NSAttributedString(string: buttonTitle, attributes: attrs)
        thinkingShowMoreButton.frame = NSRect(
          x: Self.laneHorizontalInset + horizontalPadding,
          y: buttonY,
          width: innerWidth,
          height: footerHeight
        )
        thinkingShowMoreButton.alignment = .left
        thinkingShowMoreButton.isHidden = false
        bodyContainer.addSubview(thinkingShowMoreButton)
      } else {
        thinkingShowMoreButton.isHidden = true
      }
    }

    @objc private func handleThinkingExpandToggle() {
      guard let model = currentModel else { return }
      onThinkingExpandToggle?(model.messageID)
    }

    private func rebuildErrorBody(
      model: NativeRichMessageRowModel,
      contentWidth: CGFloat,
      horizontalPadding: CGFloat,
      verticalTop: CGFloat,
      verticalBottom: CGFloat,
      accentBarWidth: CGFloat
    ) {
      let innerWidth = contentWidth - horizontalPadding * 2 - accentBarWidth
      let mdHeight = NativeMarkdownContentView.requiredHeight(
        for: currentBlocks,
        width: innerWidth,
        style: currentContentStyle
      )
      let containerHeight = verticalTop + mdHeight + verticalBottom

      // Coral-tinted background with subtle border
      errorBackground.frame = NSRect(
        x: Self.laneHorizontalInset,
        y: 0,
        width: contentWidth,
        height: containerHeight
      )
      errorBackground.isHidden = false
      bodyContainer.addSubview(errorBackground)

      // Solid coral accent bar on left edge
      errorAccentBar.frame = NSRect(
        x: Self.laneHorizontalInset,
        y: 0,
        width: accentBarWidth,
        height: containerHeight
      )
      errorAccentBar.isHidden = false
      bodyContainer.addSubview(errorAccentBar)

      // Content inside the container (offset by accent bar + padding)
      let contentX = Self.laneHorizontalInset + accentBarWidth + horizontalPadding
      markdownContentView.frame = NSRect(
        x: contentX,
        y: verticalTop,
        width: innerWidth,
        height: mdHeight
      )
      markdownContentView.configure(blocks: currentBlocks, style: currentContentStyle)
      bodyContainer.addSubview(markdownContentView)
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
      label.font = .systemFont(ofSize: TypeScale.caption, weight: .medium)
      label.textColor = NSColor.secondaryLabelColor
      label.sizeToFit()
      label.frame.origin = CGPoint(x: 34, y: (Self.imageHeaderHeight - label.frame.height) / 2)
      bar.addSubview(label)

      return bar
    }

    /// Monospaced dimension label: "1234 × 567 • 50.3 KB"
    private static func makeDimensionLabel(text: String) -> NSTextField {
      let label = NSTextField(labelWithString: text)
      label.font = .monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
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
      label.font = .systemFont(ofSize: TypeScale.meta, weight: .bold)
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

      let presentation = ConversationRichMessageLayout.presentation(for: model)
      let blocks = MarkdownSystemParser.parse(model.displayContent, style: presentation.contentStyle)
      return requiredHeight(for: width, model: model, blocks: blocks)
    }

    private static func requiredHeight(
      for width: CGFloat,
      model: NativeRichMessageRowModel,
      blocks: [MarkdownBlock]
    ) -> CGFloat {
      let bodyHeight = ConversationRichMessageLayout.bodyHeight(
        for: width,
        model: model,
        blocks: blocks
      ) { availableWidth in
        imageBlockHeight(for: model.images, availableWidth: availableWidth)
      }
      let total = ConversationRichMessageLayout.requiredHeight(
        for: width,
        model: model,
        blocks: blocks
      ) { availableWidth in
        imageBlockHeight(for: model.images, availableWidth: availableWidth)
      }
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
