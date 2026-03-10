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
    private static let imageCornerRadius = ConversationImageLayout.cornerRadius
    private static let imageSpacing = ConversationImageLayout.spacing
    private static let imageThumbnailSize = ConversationImageLayout.thumbnailSize
    private static let imageHeaderHeight = ConversationImageLayout.headerHeight
    private static let imageDimensionLabelHeight = ConversationImageLayout.dimensionLabelHeight
    private static let imageDimensionSpacing = ConversationImageLayout.dimensionSpacing

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
    private let streamingTextView = NSTextView()

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

      streamingTextView.drawsBackground = false
      streamingTextView.isEditable = false
      streamingTextView.isSelectable = true
      streamingTextView.textContainerInset = .zero
      streamingTextView.textContainer?.lineFragmentPadding = 0
      streamingTextView.textContainer?.widthTracksTextView = true
      streamingTextView.isVerticallyResizable = false
      streamingTextView.isHorizontallyResizable = false
      streamingTextView.wantsLayer = true

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

      currentBlocks = RichMessageRenderPlanning.parsedBlocks(for: model, presentation: presentation)

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
      streamingTextView.layer?.mask = nil

      let renderPlan = RichMessageRenderPlanning.bodyRenderPlan(
        for: model,
        presentation: presentation,
        width: width,
        blocks: currentBlocks,
        imageHeightProvider: { availableWidth in
          Self.imageBlockHeight(for: model.images, availableWidth: availableWidth)
        }
      )

      switch renderPlan.layoutPlan {
        case let .assistant(contentFrame, imagePlacement):
          rebuildAssistantBody(
            contentFrame: contentFrame,
            imagePlacement: imagePlacement,
            content: renderPlan.content,
            model: model
          )

        case let .userBubble(backgroundFrame, accentFrame, contentFrame, imagePlacement):
          rebuildUserBody(
            backgroundFrame: backgroundFrame,
            accentFrame: accentFrame,
            contentFrame: contentFrame,
            imagePlacement: imagePlacement,
            content: renderPlan.content,
            model: model
          )

        case let .steer(contentFrame):
          rebuildSteerBody(contentFrame: contentFrame, content: renderPlan.content)

        case let .thinking(backgroundFrame, contentFrame, footerFrame, isCollapsed, fadeHeight):
          rebuildThinkingBody(
            backgroundFrame: backgroundFrame,
            contentFrame: contentFrame,
            footerFrame: footerFrame,
            isCollapsed: isCollapsed,
            fadeHeight: fadeHeight,
            content: renderPlan.content,
            model: model,
            presentation: presentation
          )

        case let .error(backgroundFrame, accentFrame, contentFrame):
          rebuildErrorBody(
            backgroundFrame: backgroundFrame,
            accentFrame: accentFrame,
            contentFrame: contentFrame,
            content: renderPlan.content
          )
      }
    }

    private func configureStreamingTextView(_ attributedText: NSAttributedString, frame: NSRect) {
      streamingTextView.textStorage?.setAttributedString(attributedText)
      streamingTextView.frame = frame
    }

    private func applyBodyContent(_ content: RichMessageRenderableContent, frame: NSRect) {
      switch content {
        case let .markdown(blocks, style):
          markdownContentView.frame = frame
          markdownContentView.configure(blocks: blocks, style: style)
          bodyContainer.addSubview(markdownContentView)
        case let .attributedText(attributedText):
          configureStreamingTextView(attributedText, frame: frame)
          bodyContainer.addSubview(streamingTextView)
      }
    }

    private func rebuildAssistantBody(
      contentFrame: NSRect,
      imagePlacement: RichMessageImagePlacementPlan?,
      content: RichMessageRenderableContent,
      model: NativeRichMessageRowModel
    ) {
      applyBodyContent(content, frame: contentFrame)
      if let imagePlacement {
        addImageViews(
          images: model.images,
          below: imagePlacement.offsetY,
          leadingX: imagePlacement.leadingX,
          availableWidth: imagePlacement.availableWidth,
          isUserAligned: imagePlacement.isUserAligned
        )
      }
    }

    private func rebuildUserBody(
      backgroundFrame: NSRect,
      accentFrame: NSRect,
      contentFrame: NSRect,
      imagePlacement: RichMessageImagePlacementPlan?,
      content: RichMessageRenderableContent,
      model: NativeRichMessageRowModel
    ) {
      bubbleBackground.frame = backgroundFrame
      bubbleBackground.isHidden = false
      bodyContainer.addSubview(bubbleBackground)
      accentBar.frame = accentFrame
      accentBar.isHidden = false
      bodyContainer.addSubview(accentBar)
      applyBodyContent(content, frame: contentFrame)
      if let imagePlacement {
        addImageViews(
          images: model.images,
          below: imagePlacement.offsetY,
          leadingX: imagePlacement.leadingX,
          availableWidth: imagePlacement.availableWidth,
          isUserAligned: imagePlacement.isUserAligned
        )
      }
    }

    private func rebuildSteerBody(
      contentFrame: NSRect,
      content: RichMessageRenderableContent
    ) {
      guard case let .attributedText(attrStr) = content else { return }
      let textView = NSTextView(frame: contentFrame)
      textView.drawsBackground = false
      textView.isEditable = false
      textView.isSelectable = true
      textView.textContainerInset = .zero
      textView.textContainer?.lineFragmentPadding = 0

      textView.textStorage?.setAttributedString(attrStr)
      textView.frame = contentFrame
      bodyContainer.addSubview(textView)
    }

    private func rebuildThinkingBody(
      backgroundFrame: NSRect,
      contentFrame: NSRect,
      footerFrame: NSRect?,
      isCollapsed: Bool,
      fadeHeight: CGFloat,
      content: RichMessageRenderableContent,
      model: NativeRichMessageRowModel,
      presentation: RichMessagePresentation
    ) {
      thinkingBackground.frame = backgroundFrame
      thinkingBackground.isHidden = false
      bodyContainer.addSubview(thinkingBackground)

      applyBodyContent(content, frame: contentFrame)

      // Gradient mask: fade text to transparent over the last lines when collapsed
      if isCollapsed {
        let maskLayer = CAGradientLayer()
        let maskTarget: NSView = switch content {
          case .attributedText: streamingTextView
          case .markdown: markdownContentView
        }
        maskLayer.frame = maskTarget.bounds
        let renderedHeight = max(contentFrame.height, 1)
        let fadeStart = max(0, 1.0 - Double(fadeHeight) / Double(renderedHeight))
        maskLayer.colors = [
          NSColor.white.cgColor,
          NSColor.white.cgColor,
          NSColor.clear.cgColor,
        ]
        maskLayer.locations = [0, NSNumber(value: fadeStart), 1.0]
        maskTarget.layer?.mask = maskLayer
      }

      thinkingFadeOverlay.isHidden = true
      thinkingSeparator.isHidden = true

      if let buttonTitle = presentation.thinkingButtonTitle, let footerFrame {
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: TypeScale.body, weight: .medium),
          .foregroundColor: Self.thinkingColor.withAlphaComponent(0.65),
          .kern: 0.2,
        ]
        thinkingShowMoreButton.attributedTitle = NSAttributedString(string: buttonTitle, attributes: attrs)
        thinkingShowMoreButton.frame = footerFrame
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
      backgroundFrame: NSRect,
      accentFrame: NSRect,
      contentFrame: NSRect,
      content: RichMessageRenderableContent
    ) {
      errorBackground.frame = backgroundFrame
      errorBackground.isHidden = false
      bodyContainer.addSubview(errorBackground)
      errorAccentBar.frame = accentFrame
      errorAccentBar.isHidden = false
      bodyContainer.addSubview(errorAccentBar)
      applyBodyContent(content, frame: contentFrame)
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
        let cached = ImageCache.shared.cachedImage(for: image)
        let metrics = ConversationImageLayout.displayMetrics(
          for: image,
          availableWidth: availableWidth,
          displaySize: cached?.displayImage.size
        )

        let imageX: CGFloat = isUserAligned
          ? leadingX + availableWidth - metrics.width
          : leadingX

        // Shadow container + clipped image inside
        let container = makeImageContainer(
          frame: NSRect(x: imageX, y: currentY, width: metrics.width, height: metrics.height),
          shadowRadius: 8, shadowOffset: 4, shadowOpacity: 0.3
        )
        if let cached {
          let imageView = makeClippedImageView(in: container)
          imageView.image = cached.displayImage
        } else {
          addImagePlaceholder(to: container, title: "Loading image")
        }
        addFullscreenClick(to: container, imageIndex: 0)
        bodyContainer.addSubview(container)

        currentY += metrics.height + Self.imageDimensionSpacing

        // Dimension + size label (original pixel dimensions, not display-scaled)
        let dimText = Self.formatImageMetadata(
          for: image,
          originalWidth: cached?.originalWidth,
          originalHeight: cached?.originalHeight
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
          let size = Self.imageThumbnailSize
          if x + size > leadingX + availableWidth, x > leadingX {
            x = leadingX
            y += size + Self.imageSpacing
          }

          let container = makeImageContainer(
            frame: NSRect(x: x, y: y, width: size, height: size),
            shadowRadius: 6, shadowOffset: 3, shadowOpacity: 0.25
          )
          if let nsImage = ImageCache.shared.image(for: image) {
            let imageView = makeClippedImageView(in: container)
            imageView.image = nsImage
            imageView.imageScaling = .scaleProportionallyUpOrDown
          } else {
            addImagePlaceholder(to: container, title: nil)
          }
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

    private func addImagePlaceholder(to container: NSView, title: String?) {
      let placeholder = NSView(frame: container.bounds)
      placeholder.wantsLayer = true
      placeholder.layer?.cornerRadius = Self.imageCornerRadius
      placeholder.layer?.masksToBounds = true
      placeholder.layer?.backgroundColor = NSColor(Color.backgroundSecondary).cgColor
      placeholder.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
      placeholder.layer?.borderWidth = 1

      let icon = NSImageView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
      icon.image = NSImage(systemSymbolName: "photo.badge.arrow.down", accessibilityDescription: nil)
      icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
      icon.contentTintColor = NSColor(Color.textSecondary)
      icon.frame.origin = CGPoint(
        x: (placeholder.bounds.width - icon.frame.width) / 2,
        y: title == nil
          ? (placeholder.bounds.height - icon.frame.height) / 2
          : placeholder.bounds.height / 2 - 18
      )
      placeholder.addSubview(icon)

      if let title, !title.isEmpty {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: TypeScale.meta, weight: .semibold)
        label.textColor = NSColor(Color.textSecondary)
        label.alignment = .center
        label.sizeToFit()
        label.frame = NSRect(
          x: 8,
          y: max(8, icon.frame.minY - label.frame.height - 8),
          width: max(0, placeholder.bounds.width - 16),
          height: label.frame.height
        )
        placeholder.addSubview(label)
      }

      container.addSubview(placeholder)
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
      let sizeText = ConversationImageLayout.formattedByteCount(totalBytes)

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

    private static func formatImageMetadata(
      for image: MessageImage,
      originalWidth: Int?,
      originalHeight: Int?
    ) -> String {
      ConversationRichMessageSupport.imageMetadata(
        for: image,
        originalWidth: originalWidth,
        originalHeight: originalHeight
      )
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
      ConversationRichMessageSupport.imageBlockHeight(for: images, availableWidth: availableWidth) { image in
        ImageCache.shared.image(for: image)?.size
      }
    }

    // MARK: - Height Calculation (Deterministic)

    /// Calculate required height for this cell given width and model.
    /// Fully deterministic — no SwiftUI measurement involved.
    static func requiredHeight(for width: CGFloat, model: NativeRichMessageRowModel) -> CGFloat {
      guard width > 1 else { return 1 }

      let presentation = ConversationRichMessageLayout.presentation(for: model)
      let blocks = RichMessageRenderPlanning.parsedBlocks(for: model, presentation: presentation)
      return requiredHeight(for: width, model: model, blocks: blocks)
    }

    private static func requiredHeight(
      for width: CGFloat,
      model: NativeRichMessageRowModel,
      blocks: [MarkdownBlock]
    ) -> CGFloat {
      let totalHeight = RichMessageRenderPlanning.requiredHeight(
        for: width,
        model: model,
        blocks: blocks
      ) { availableWidth in
        imageBlockHeight(for: model.images, availableWidth: availableWidth)
      }
      logger.debug(
        "requiredHeight-rich[\(model.messageID)] \(model.messageType) "
          + "total=\(f(totalHeight)) w=\(f(width)) "
          + "blocks=\(blocks.count) chars=\(model.displayContent.count)"
      )
      return totalHeight
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
