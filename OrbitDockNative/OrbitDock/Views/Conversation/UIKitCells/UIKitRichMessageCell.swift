//
//  UIKitRichMessageCell.swift
//  OrbitDock
//
//  Native UICollectionViewCell for ALL .message rows on iOS.
//  Ports NativeRichMessageCellView (macOS NSTableCellView) to UIKit.
//  Manual frame layout, deterministic height via NativeMarkdownContentView.
//
//  Structure:
//    - Speaker header: glyph + label (26pt fixed height)
//    - Body: NativeMarkdownContentView (deterministic via TextKit 1)
//    - User messages: right-aligned with accent bar
//    - Assistant: left-aligned markdown
//    - Thinking: purple-tinted, compact
//    - Steer: italic secondary
//    - Shell: green-tinted
//

#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitRichMessageCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitRichMessageCell"

    // MARK: - Layout Constants

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
    private static let thinkingColor = PlatformColor(Color.textTertiary)
    private static let thinkingShowMoreHeight = ConversationRichMessageLayout.thinkingShowMoreHeight
    private static let thinkingFadeHeight = ConversationRichMessageLayout.thinkingFadeHeight

    // Error containment
    private static let errorCornerRadius: CGFloat = Radius.lg
    private static let errorHPad = ConversationRichMessageLayout.errorHPad
    private static let errorVPadTop = ConversationRichMessageLayout.errorVPadTop
    private static let errorVPadBottom = ConversationRichMessageLayout.errorVPadBottom
    private static let errorAccentBarWidth = ConversationRichMessageLayout.errorAccentBarWidth
    private static let errorColor = PlatformColor(Color.statusPermission)

    // MARK: - Subviews

    private let headerContainer = UIView()
    private let glyphImage = UIImageView()
    private let speakerLabel = UILabel()
    private let bodyContainer = UIView()
    private let markdownContentView = NativeMarkdownContentView()
    private let streamingTextView = UITextView()

    // User-specific
    private let bubbleBackground = UIView()
    private let accentBar = UIView()

    // Thinking-specific
    private let thinkingBackground = UIView()
    private let thinkingSeparator = UIView()
    private let thinkingFadeOverlay = UIView()
    private let thinkingShowMoreButton = UIButton(type: .system)

    // Error-specific
    private let errorBackground = UIView()
    private let errorAccentBar = UIView()

    var onThinkingExpandToggle: ((String) -> Void)?

    private let cardBg = CellCardBackground()
    private static let logger = TimelineFileLogger.shared
    private var currentModel: NativeRichMessageRowModel?
    private var currentBlocks: [MarkdownBlock] = []
    private var currentImages: [MessageImage] = []
    private var currentContentStyle: ContentStyle = .standard

    // MARK: - Init

    override init(frame: CGRect) {
      super.init(frame: frame)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    // MARK: - Setup

    private func setup() {
      backgroundColor = .clear
      contentView.backgroundColor = .clear

      cardBg.install(in: contentView)

      // Header
      contentView.addSubview(headerContainer)

      let symbolConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
      glyphImage.preferredSymbolConfiguration = symbolConfig
      headerContainer.addSubview(glyphImage)

      speakerLabel.lineBreakMode = .byTruncatingTail
      headerContainer.addSubview(speakerLabel)

      // Body
      contentView.addSubview(bodyContainer)

      // Bubble background
      bubbleBackground.layer.cornerRadius = Self.userBubbleCornerRadius
      bubbleBackground.layer.masksToBounds = true
      bubbleBackground.backgroundColor = PlatformColor(Color.accent).withAlphaComponent(OpacityTier.tint)
      bubbleBackground.isHidden = true

      // Accent bar
      accentBar.backgroundColor = PlatformColor(Color.accent).withAlphaComponent(OpacityTier.strong)
      accentBar.isHidden = true

      // Thinking background
      thinkingBackground.backgroundColor = Self.thinkingColor.withAlphaComponent(0.06)
      thinkingBackground.layer.cornerRadius = Self.thinkingCornerRadius
      thinkingBackground.layer.masksToBounds = true
      thinkingBackground.layer.borderColor = Self.thinkingColor.withAlphaComponent(0.10).cgColor
      thinkingBackground.layer.borderWidth = 1
      thinkingBackground.isHidden = true

      // Separator
      thinkingSeparator.backgroundColor = Self.thinkingColor.withAlphaComponent(0.12)
      thinkingSeparator.isHidden = true

      // Fade overlay
      thinkingFadeOverlay.isHidden = true

      // Show more button
      thinkingShowMoreButton.titleLabel?.font = PlatformFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      thinkingShowMoreButton.setTitleColor(Self.thinkingColor.withAlphaComponent(0.65), for: .normal)
      thinkingShowMoreButton.addTarget(self, action: #selector(handleThinkingExpandToggle), for: .touchUpInside)
      thinkingShowMoreButton.isHidden = true
      thinkingShowMoreButton.contentHorizontalAlignment = .left

      streamingTextView.backgroundColor = .clear
      streamingTextView.isEditable = false
      streamingTextView.isSelectable = true
      streamingTextView.isScrollEnabled = false
      streamingTextView.textContainerInset = .zero
      streamingTextView.textContainer.lineFragmentPadding = 0

      // Error background
      errorBackground.backgroundColor = Self.errorColor.withAlphaComponent(0.08)
      errorBackground.layer.cornerRadius = Self.errorCornerRadius
      errorBackground.layer.masksToBounds = true
      errorBackground.layer.borderColor = Self.errorColor.withAlphaComponent(0.10).cgColor
      errorBackground.layer.borderWidth = 1
      errorBackground.isHidden = true

      // Error accent bar
      errorAccentBar.backgroundColor = Self.errorColor
      errorAccentBar.isHidden = true
    }

    // MARK: - Card Background

    override func layoutSubviews() {
      super.layoutSubviews()
      cardBg.layoutInBounds(contentView.bounds)
    }

    func configureCardPosition(_ position: CardPosition, topInset: CGFloat, bottomInset: CGFloat) {
      cardBg.configure(position: position, topInset: topInset, bottomInset: bottomInset)
    }

    // MARK: - Prepare for Reuse

    override func prepareForReuse() {
      super.prepareForReuse()
      cardBg.reset()
      bodyContainer.subviews.forEach { $0.removeFromSuperview() }
      headerContainer.isHidden = false
      speakerLabel.isHidden = false
      bubbleBackground.isHidden = true
      accentBar.isHidden = true
      thinkingBackground.isHidden = true
      thinkingSeparator.isHidden = true
      thinkingFadeOverlay.isHidden = true
      thinkingShowMoreButton.isHidden = true
      errorBackground.isHidden = true
      errorAccentBar.isHidden = true
      currentModel = nil
      currentBlocks = []
      currentImages = []
      currentContentStyle = .standard
      streamingTextView.attributedText = nil
    }

    // MARK: - Configure

    private static func f(_ v: CGFloat) -> String {
      String(format: "%.1f", v)
    }

    func configure(model: NativeRichMessageRowModel, width: CGFloat) {
      currentModel = model
      let presentation = ConversationRichMessageLayout.presentation(for: model)

      configureHeader(model: model, presentation: presentation, width: width)

      currentContentStyle = presentation.contentStyle
      currentBlocks = if model.usesStreamingTextRenderer {
        []
      } else {
        MarkdownSystemParser.parse(model.displayContent, style: presentation.contentStyle)
      }

      rebuildBody(model: model, presentation: presentation, width: width)

      // Overflow detection — check if subviews exceed cell bounds
      let cellHeight = bounds.height
      let maxSubviewBottom = contentView.subviews.reduce(CGFloat(0)) { maxY, sub in
        max(maxY, sub.frame.maxY)
      }
      let bodyMaxBottom = bodyContainer.subviews.reduce(CGFloat(0)) { maxY, sub in
        max(maxY, sub.frame.maxY)
      }
      let bodyBudget = ConversationRichMessageLayout.bodyHeight(
        for: width,
        model: model,
        blocks: currentBlocks
      ) { availableWidth in
        Self.imageBlockHeight(for: model.images, availableWidth: availableWidth)
      }

      if bodyMaxBottom > bodyBudget + 1 {
        Self.logger.info(
          "⚠️ OVERFLOW rich[\(model.messageID.prefix(8))] \(model.messageType) "
            + "bodyBudget=\(Self.f(bodyBudget)) maxBody=\(Self.f(bodyMaxBottom)) "
            + "overflow=\(Self.f(bodyMaxBottom - bodyBudget)) w=\(Self.f(width))"
        )
      }

      Self.logger.debug(
        "configure-rich[\(model.messageID.prefix(8))] \(model.messageType) "
          + "cellH=\(Self.f(cellHeight)) bodyH=\(Self.f(bodyBudget)) "
          + "maxSubview=\(Self.f(maxSubviewBottom)) bodyMax=\(Self.f(bodyMaxBottom)) "
          + "w=\(Self.f(width)) blocks=\(currentBlocks.count)"
      )
    }

    private func configureHeader(
      model: NativeRichMessageRowModel,
      presentation: RichMessagePresentation,
      width: CGFloat
    ) {
      let header = presentation.header
      guard header.isVisible else {
        headerContainer.isHidden = true
        speakerLabel.isHidden = true
        headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        return
      }

      headerContainer.isHidden = false
      let symbolConfig = UIImage.SymbolConfiguration(
        pointSize: header.glyphPointSize,
        weight: header.glyphWeight.platformWeight
      )
      glyphImage.preferredSymbolConfiguration = symbolConfig
      glyphImage.image = UIImage(systemName: header.glyphSymbol)
      glyphImage.tintColor = header.glyphColor

      if let labelText = header.labelText, let labelAttributes = header.labelAttributes {
        speakerLabel.attributedText = NSAttributedString(string: labelText, attributes: labelAttributes)
        speakerLabel.isHidden = false
      } else {
        speakerLabel.attributedText = nil
        speakerLabel.isHidden = true
      }

      // Layout header
      let glyphSize = header.glyphFrameSize
      if header.isRightAligned {
        glyphImage.frame = CGRect(
          x: width - Self.laneHorizontalInset - glyphSize,
          y: (Self.headerHeight - glyphSize) / 2,
          width: glyphSize,
          height: glyphSize
        )
        let labelSize = speakerLabel.sizeThatFits(CGSize(width: 200, height: Self.headerHeight))
        speakerLabel.frame = CGRect(
          x: glyphImage.frame.minX - Spacing.xs - labelSize.width,
          y: (Self.headerHeight - labelSize.height) / 2,
          width: labelSize.width,
          height: labelSize.height
        )
      } else {
        glyphImage.frame = CGRect(
          x: Self.metadataHorizontalInset,
          y: (Self.headerHeight - glyphSize) / 2,
          width: glyphSize,
          height: glyphSize
        )
        let labelSize = speakerLabel.sizeThatFits(CGSize(width: 200, height: Self.headerHeight))
        speakerLabel.frame = CGRect(
          x: glyphImage.frame.maxX + Spacing.xs,
          y: (Self.headerHeight - labelSize.height) / 2,
          width: labelSize.width,
          height: labelSize.height
        )
      }

      headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: presentation.actualHeaderHeight)
    }

    // MARK: - Body Layout

    private func rebuildBody(
      model: NativeRichMessageRowModel,
      presentation: RichMessagePresentation,
      width: CGFloat
    ) {
      bodyContainer.subviews.forEach { $0.removeFromSuperview() }
      bubbleBackground.isHidden = true
      accentBar.isHidden = true
      thinkingBackground.isHidden = true
      errorBackground.isHidden = true
      errorAccentBar.isHidden = true
      markdownContentView.layer.mask = nil
      streamingTextView.layer.mask = nil

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

      // Body container starts after header + spacing
      let bodyHeight = ConversationRichMessageLayout.bodyHeight(
        for: width,
        model: model,
        blocks: currentBlocks
      ) { availableWidth in
        Self.imageBlockHeight(for: model.images, availableWidth: availableWidth)
      }
      bodyContainer.frame = CGRect(x: 0, y: presentation.bodyOriginY, width: width, height: bodyHeight)
    }

    private func configureStreamingTextView(_ attributedText: NSAttributedString, frame: CGRect) {
      streamingTextView.attributedText = attributedText
      streamingTextView.frame = frame
    }

    private func rebuildAssistantBody(model: NativeRichMessageRowModel, contentWidth: CGFloat) {
      if model.usesStreamingTextRenderer {
        let attrStr = ConversationRichMessageLayout.streamingAttributedText(for: model, style: currentContentStyle)
        let textHeight = NativeMarkdownContentView.measureTextHeight(attrStr, width: contentWidth)
        configureStreamingTextView(
          attrStr,
          frame: CGRect(
            x: Self.laneHorizontalInset,
            y: 0,
            width: contentWidth,
            height: textHeight
          )
        )
        bodyContainer.addSubview(streamingTextView)

        if !model.images.isEmpty {
          addImageViews(
            images: model.images,
            below: textHeight,
            leadingX: Self.laneHorizontalInset,
            availableWidth: contentWidth,
            isUserAligned: false
          )
        }
        return
      }

      let mdHeight = NativeMarkdownContentView.requiredHeight(
        for: currentBlocks,
        width: contentWidth,
        style: currentContentStyle
      )
      markdownContentView.frame = CGRect(
        x: Self.laneHorizontalInset, y: 0,
        width: contentWidth, height: mdHeight
      )
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

      let bubbleWidth = min(contentWidth, innerWidth + horizontalPadding * 2 + accentBarWidth)
      let bubbleX = totalWidth - Self.laneHorizontalInset - bubbleWidth

      bubbleBackground.frame = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
      bubbleBackground.isHidden = false
      bodyContainer.addSubview(bubbleBackground)

      accentBar.frame = CGRect(
        x: bubbleX + bubbleWidth - accentBarWidth,
        y: 0,
        width: accentBarWidth,
        height: bubbleHeight
      )
      accentBar.isHidden = false
      bodyContainer.addSubview(accentBar)

      markdownContentView.frame = CGRect(
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
      let attrStr = ConversationRichMessageLayout.steerAttributedText(model.content, lineSpacing: lineSpacing)
      let height = NativeMarkdownContentView.measureTextHeight(attrStr, width: contentWidth)

      let textView = UITextView(frame: CGRect(
        x: Self.laneHorizontalInset, y: 0,
        width: contentWidth, height: height
      ))
      textView.backgroundColor = .clear
      textView.isEditable = false
      textView.isSelectable = true
      textView.isScrollEnabled = false
      textView.textContainerInset = .zero
      textView.textContainer.lineFragmentPadding = 0
      textView.attributedText = attrStr
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
      let mdHeight: CGFloat
      if model.usesStreamingTextRenderer {
        let attrStr = ConversationRichMessageLayout.streamingAttributedText(for: model, style: .thinking)
        mdHeight = NativeMarkdownContentView.measureTextHeight(attrStr, width: innerWidth)
      } else {
        mdHeight = NativeMarkdownContentView.requiredHeight(for: currentBlocks, width: innerWidth, style: .thinking)
      }

      let hasShowMore = buttonTitle != nil
      let isCollapsed = hasShowMore && !model.isThinkingExpanded

      // Bottom area: show more button only (fade mask handles the transition)
      let bottomZoneHeight: CGFloat = hasShowMore ? footerHeight : 0
      let containerHeight = verticalTop + mdHeight + verticalBottom + bottomZoneHeight

      // Purple background
      thinkingBackground.frame = CGRect(
        x: Self.laneHorizontalInset, y: 0,
        width: contentWidth, height: containerHeight
      )
      thinkingBackground.isHidden = false
      bodyContainer.addSubview(thinkingBackground)

      // Markdown content
      let contentX = Self.laneHorizontalInset + horizontalPadding
      if model.usesStreamingTextRenderer {
        let attrStr = ConversationRichMessageLayout.streamingAttributedText(for: model, style: .thinking)
        configureStreamingTextView(
          attrStr,
          frame: CGRect(x: contentX, y: verticalTop, width: innerWidth, height: mdHeight)
        )
        bodyContainer.addSubview(streamingTextView)
      } else {
        markdownContentView.frame = CGRect(x: contentX, y: verticalTop, width: innerWidth, height: mdHeight)
        markdownContentView.configure(blocks: currentBlocks, style: .thinking)
        bodyContainer.addSubview(markdownContentView)
      }

      // Gradient mask: fade text to transparent over the last lines when collapsed
      if isCollapsed {
        let maskLayer = CAGradientLayer()
        let maskTarget: UIView = model.usesStreamingTextRenderer ? streamingTextView : markdownContentView
        maskLayer.frame = maskTarget.bounds
        let fadeStart = max(0, 1.0 - Double(fadeHeight) / Double(mdHeight))
        maskLayer.colors = [
          UIColor.white.cgColor,
          UIColor.white.cgColor,
          UIColor.clear.cgColor,
        ]
        maskLayer.locations = [0, NSNumber(value: fadeStart), 1.0]
        maskTarget.layer.mask = maskLayer
      }

      thinkingFadeOverlay.isHidden = true
      thinkingSeparator.isHidden = true

      // "Show more / Show less" button
      if let buttonTitle {
        let buttonY = verticalTop + mdHeight + verticalBottom
        thinkingShowMoreButton.setTitle(buttonTitle, for: .normal)
        thinkingShowMoreButton.frame = CGRect(
          x: Self.laneHorizontalInset + horizontalPadding,
          y: buttonY,
          width: innerWidth,
          height: footerHeight
        )
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
      errorBackground.frame = CGRect(
        x: Self.laneHorizontalInset,
        y: 0,
        width: contentWidth,
        height: containerHeight
      )
      errorBackground.isHidden = false
      bodyContainer.addSubview(errorBackground)

      // Solid coral accent bar on left edge
      errorAccentBar.frame = CGRect(
        x: Self.laneHorizontalInset,
        y: 0,
        width: accentBarWidth,
        height: containerHeight
      )
      errorAccentBar.isHidden = false
      bodyContainer.addSubview(errorAccentBar)

      // Content inside the container
      let contentX = Self.laneHorizontalInset + accentBarWidth + horizontalPadding
      markdownContentView.frame = CGRect(
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
        let cached = ImageCache.shared.cachedImage(for: image)
        let metrics = ConversationImageLayout.displayMetrics(
          for: image,
          availableWidth: availableWidth,
          displaySize: cached?.displayImage.size
        )

        let imageX: CGFloat = isUserAligned
          ? leadingX + availableWidth - metrics.width
          : leadingX

        let container = makeImageContainer(
          frame: CGRect(x: imageX, y: currentY, width: metrics.width, height: metrics.height),
          shadowRadius: 8, shadowOffset: 4, shadowOpacity: 0.3
        )
        if let cached {
          let imageView = makeClippedImageView(in: container)
          imageView.image = cached.displayImage
          imageView.contentMode = .scaleAspectFit
        } else {
          addImagePlaceholder(to: container, title: "Loading image")
        }
        addFullscreenTap(to: container, imageIndex: 0)
        bodyContainer.addSubview(container)

        currentY += metrics.height + Self.imageDimensionSpacing

        let dimText = Self.formatImageMetadata(
          for: image,
          originalWidth: cached?.originalWidth,
          originalHeight: cached?.originalHeight
        )
        let dimLabel = Self.makeDimensionLabel(text: dimText)
        dimLabel.sizeToFit()
        let labelWidth = dimLabel.frame.width
        let labelX: CGFloat = isUserAligned
          ? leadingX + availableWidth - labelWidth
          : leadingX
        dimLabel.frame = CGRect(x: labelX, y: currentY, width: labelWidth, height: Self.imageDimensionLabelHeight)
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
            frame: CGRect(x: x, y: y, width: size, height: size),
            shadowRadius: 6, shadowOffset: 3, shadowOpacity: 0.25
          )
          if let displayImage = ImageCache.shared.image(for: image) {
            let imageView = makeClippedImageView(in: container)
            imageView.image = displayImage
            imageView.contentMode = .scaleAspectFill
          } else {
            addImagePlaceholder(to: container, title: nil)
          }
          addFullscreenTap(to: container, imageIndex: index)
          bodyContainer.addSubview(container)

          // Number badge
          let badge = Self.makeNumberBadge(number: index + 1)
          let badgeSize: CGFloat = 22
          badge.frame = CGRect(x: x + size - badgeSize - 8, y: y + 8, width: badgeSize, height: badgeSize)
          bodyContainer.addSubview(badge)

          x += size + Self.imageSpacing
        }
      }
    }

    private func makeImageContainer(
      frame: CGRect,
      shadowRadius: CGFloat,
      shadowOffset: CGFloat,
      shadowOpacity: Float
    ) -> UIView {
      let container = UIView(frame: frame)
      container.layer.cornerRadius = Self.imageCornerRadius
      container.layer.shadowColor = UIColor.black.cgColor
      container.layer.shadowRadius = shadowRadius
      container.layer.shadowOffset = CGSize(width: 0, height: shadowOffset)
      container.layer.shadowOpacity = shadowOpacity
      container.layer.shadowPath = UIBezierPath(
        roundedRect: CGRect(origin: .zero, size: frame.size),
        cornerRadius: Self.imageCornerRadius
      ).cgPath
      return container
    }

    private func makeClippedImageView(in container: UIView) -> UIImageView {
      let iv = UIImageView(frame: container.bounds)
      iv.clipsToBounds = true
      iv.layer.cornerRadius = Self.imageCornerRadius
      iv.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
      iv.layer.borderWidth = 1
      container.addSubview(iv)
      return iv
    }

    private func addImagePlaceholder(to container: UIView, title: String?) {
      let placeholder = UIView(frame: container.bounds)
      placeholder.clipsToBounds = true
      placeholder.layer.cornerRadius = Self.imageCornerRadius
      placeholder.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
      placeholder.layer.borderWidth = 1
      placeholder.backgroundColor = PlatformColor(Color.backgroundSecondary)

      let icon = UIImageView(image: UIImage(systemName: "photo.badge.arrow.down"))
      icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
      icon.tintColor = PlatformColor(Color.textSecondary)
      icon.frame = CGRect(
        x: (placeholder.bounds.width - 24) / 2,
        y: title == nil ? (placeholder.bounds.height - 24) / 2 : placeholder.bounds.height / 2 - 18,
        width: 24,
        height: 24
      )
      placeholder.addSubview(icon)

      if let title, !title.isEmpty {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: TypeScale.meta, weight: .semibold)
        label.textColor = PlatformColor(Color.textSecondary)
        label.textAlignment = .center
        label.frame = CGRect(
          x: 8,
          y: max(8, icon.frame.minY - 24),
          width: max(0, placeholder.bounds.width - 16),
          height: 20
        )
        placeholder.addSubview(label)
      }

      container.addSubview(placeholder)
    }

    private func makeImageHeaderBar(imageCount: Int, totalBytes: Int, width: CGFloat) -> UIView {
      let bar = UIView(frame: CGRect(x: 0, y: 0, width: width, height: Self.imageHeaderHeight))
      bar.layer.cornerRadius = 8
      bar.backgroundColor = PlatformColor(Color.backgroundTertiary).withAlphaComponent(0.5)

      let icon = UIImageView(frame: CGRect(x: 12, y: 8, width: 16, height: 16))
      icon.image = UIImage(systemName: "photo.on.rectangle.angled")
      icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      icon.tintColor = .secondaryLabel
      bar.addSubview(icon)

      let countText = imageCount == 1 ? "1 image" : "\(imageCount) images"
      let sizeText = ConversationImageLayout.formattedByteCount(totalBytes)
      let label = UILabel()
      label.text = "\(countText)  \u{00B7}  \(sizeText)"
      label.font = .systemFont(ofSize: TypeScale.caption, weight: .medium)
      label.textColor = .secondaryLabel
      label.sizeToFit()
      label.frame.origin = CGPoint(x: 34, y: (Self.imageHeaderHeight - label.frame.height) / 2)
      bar.addSubview(label)

      return bar
    }

    private static func makeDimensionLabel(text: String) -> UILabel {
      let label = UILabel()
      label.text = text
      label.font = .monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
      label.textColor = PlatformColor(Color.textQuaternary)
      return label
    }

    private static func makeNumberBadge(number: Int) -> UIView {
      let size: CGFloat = 22
      let badge = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
      badge.layer.cornerRadius = size / 2
      badge.backgroundColor = PlatformColor(Color.accent).withAlphaComponent(0.9)

      let label = UILabel()
      label.text = "\(number)"
      label.font = .systemFont(ofSize: TypeScale.meta, weight: .bold)
      label.textColor = .white
      label.textAlignment = .center
      label.sizeToFit()
      label.frame = CGRect(
        x: (size - label.frame.width) / 2,
        y: (size - label.frame.height) / 2,
        width: label.frame.width,
        height: label.frame.height
      )
      badge.addSubview(label)
      return badge
    }

    private static func formatDimensions(width: Int, height: Int, bytes: Int) -> String {
      "\(width) \u{00D7} \(height)  \u{00B7}  \(ConversationImageLayout.formattedByteCount(bytes))"
    }

    private static func formatImageMetadata(
      for image: MessageImage,
      originalWidth: Int?,
      originalHeight: Int?
    ) -> String {
      let width = originalWidth ?? image.pixelWidth
      let height = originalHeight ?? image.pixelHeight
      guard let width, let height, width > 0, height > 0 else {
        return ConversationImageLayout.formattedByteCount(image.byteCount)
      }
      return formatDimensions(width: width, height: height, bytes: image.byteCount)
    }

    private func addFullscreenTap(to container: UIView, imageIndex: Int) {
      container.tag = imageIndex + 1_000 // offset to avoid tag=0 ambiguity
      container.isUserInteractionEnabled = true
      let tap = UITapGestureRecognizer(target: self, action: #selector(imageContainerTapped(_:)))
      container.addGestureRecognizer(tap)
    }

    @objc private func imageContainerTapped(_ gesture: UITapGestureRecognizer) {
      guard let container = gesture.view,
            !currentImages.isEmpty
      else { return }

      let index = container.tag - 1_000
      guard index >= 0, index < currentImages.count else { return }

      guard let vc = findViewController() else { return }
      let fullscreen = ImageFullscreen(images: currentImages, currentIndex: index)
      let host = UIHostingController(rootView: fullscreen)
      host.modalPresentationStyle = .fullScreen
      vc.present(host, animated: true)
    }

    private func findViewController() -> UIViewController? {
      var responder: UIResponder? = self
      while let next = responder?.next {
        if let vc = next as? UIViewController { return vc }
        responder = next
      }
      return nil
    }

    static func imageBlockHeight(for images: [MessageImage], availableWidth: CGFloat) -> CGFloat {
      ConversationImageLayout.blockHeight(for: images, availableWidth: availableWidth) { image in
        ImageCache.shared.image(for: image)?.size
      }
    }

    // MARK: - Height Calculation (Deterministic)

    static func requiredHeight(for width: CGFloat, model: NativeRichMessageRowModel) -> CGFloat {
      guard width > 1 else { return 1 }
      var blocks: [MarkdownBlock] = []
      if !model.usesStreamingTextRenderer {
        let presentation = ConversationRichMessageLayout.presentation(for: model)
        blocks = MarkdownSystemParser.parse(model.displayContent, style: presentation.contentStyle)
      }
      let body = bodyHeight(for: width, model: model, blocks: blocks)
      let total = ConversationRichMessageLayout.requiredHeight(
        for: width,
        model: model,
        blocks: blocks
      ) { availableWidth in
        imageBlockHeight(for: model.images, availableWidth: availableWidth)
      }
      logger.debug(
        "requiredHeight-rich[\(model.messageID.prefix(8))] \(model.messageType) "
          + "body=\(f(body)) total=\(f(total)) "
          + "w=\(f(width)) blocks=\(blocks.count)"
      )
      return total
    }

    private static func bodyHeight(
      for width: CGFloat,
      model: NativeRichMessageRowModel,
      blocks: [MarkdownBlock]
    ) -> CGFloat {
      ConversationRichMessageLayout.bodyHeight(
        for: width,
        model: model,
        blocks: blocks
      ) { availableWidth in
        imageBlockHeight(for: model.images, availableWidth: availableWidth)
      }
    }
  }

#endif
