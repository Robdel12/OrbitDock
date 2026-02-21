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
    private static let thinkingColor = PlatformColor.calibrated(red: 0.65, green: 0.6, blue: 0.85, alpha: 1)
    private static let thinkingShowMoreHeight: CGFloat = 32
    private static let thinkingFadeHeight: CGFloat = 28

    // MARK: - Subviews

    private let headerContainer = UIView()
    private let glyphImage = UIImageView()
    private let speakerLabel = UILabel()
    private let bodyContainer = UIView()
    private let markdownContentView = NativeMarkdownContentView()

    // User-specific
    private let bubbleBackground = UIView()
    private let accentBar = UIView()

    // Thinking-specific
    private let thinkingBackground = UIView()
    private let thinkingSeparator = UIView()
    private let thinkingFadeOverlay = UIView()
    private let thinkingShowMoreButton = UIButton(type: .system)

    var onThinkingExpandToggle: ((String) -> Void)?

    private static let logger = TimelineFileLogger.shared
    private var currentModel: NativeRichMessageRowModel?
    private var currentBlocks: [MarkdownBlock] = []
    private var currentImages: [MessageImage] = []

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
      bubbleBackground.backgroundColor = PlatformColor(Color.backgroundTertiary).withAlphaComponent(0.68)
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
    }

    // MARK: - Prepare for Reuse

    override func prepareForReuse() {
      super.prepareForReuse()
      bodyContainer.subviews.forEach { $0.removeFromSuperview() }
      bubbleBackground.isHidden = true
      accentBar.isHidden = true
      thinkingBackground.isHidden = true
      thinkingSeparator.isHidden = true
      thinkingFadeOverlay.isHidden = true
      thinkingShowMoreButton.isHidden = true
      currentModel = nil
      currentBlocks = []
      currentImages = []
    }

    // MARK: - Configure

    private static func f(_ v: CGFloat) -> String {
      String(format: "%.1f", v)
    }

    func configure(model: NativeRichMessageRowModel, width: CGFloat) {
      currentModel = model

      configureHeader(model: model, width: width)

      let style: ContentStyle = model.messageType == .thinking ? .thinking : .standard
      currentBlocks = MarkdownAttributedStringRenderer.parse(model.displayContent, style: style)

      rebuildBody(model: model, width: width)

      // Overflow detection — check if subviews exceed cell bounds
      let cellHeight = bounds.height
      let maxSubviewBottom = contentView.subviews.reduce(CGFloat(0)) { maxY, sub in
        max(maxY, sub.frame.maxY)
      }
      let bodyMaxBottom = bodyContainer.subviews.reduce(CGFloat(0)) { maxY, sub in
        max(maxY, sub.frame.maxY)
      }
      let bodyBudget = Self.bodyHeight(for: width, model: model, blocks: currentBlocks)

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

    private func configureHeader(model: NativeRichMessageRowModel, width: CGFloat) {
      let symbolName = model.glyphSymbol
      let isThinking = model.messageType == .thinking
      let symbolConfig = UIImage.SymbolConfiguration(
        pointSize: isThinking ? 8 : 10,
        weight: isThinking ? .regular : .medium
      )
      glyphImage.preferredSymbolConfiguration = symbolConfig
      glyphImage.image = UIImage(systemName: symbolName)
      glyphImage.tintColor = model.glyphColor

      let fontSize: CGFloat = isThinking ? 9 : TypeScale.chatLabel
      let fontWeight: PlatformFont.Weight = isThinking ? .medium : .semibold
      let kern: CGFloat = isThinking ? 0.3 : 0.5

      let font: PlatformFont = if let roundedDesc = PlatformFont.systemFont(ofSize: fontSize, weight: fontWeight)
        .fontDescriptor.withDesign(.rounded)
      {
        UIFont(descriptor: roundedDesc, size: fontSize)
      } else {
        PlatformFont.systemFont(ofSize: fontSize, weight: fontWeight)
      }

      let attrs: [NSAttributedString.Key: Any] = [
        .kern: kern,
        .font: font,
        .foregroundColor: model.speakerColor,
      ]
      speakerLabel.attributedText = NSAttributedString(string: model.speaker, attributes: attrs)

      // Layout header
      let glyphSize: CGFloat = 20
      if model.isUserAligned {
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

      headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: Self.headerHeight)
    }

    // MARK: - Body Layout

    private func rebuildBody(model: NativeRichMessageRowModel, width: CGFloat) {
      bodyContainer.subviews.forEach { $0.removeFromSuperview() }
      bubbleBackground.isHidden = true
      accentBar.isHidden = true
      thinkingBackground.isHidden = true
      markdownContentView.layer.mask = nil

      let bodyY = Self.headerHeight + Self.headerToBodySpacing
      let contentWidth: CGFloat

      if model.isUserAligned {
        contentWidth = min(width - Self.laneHorizontalInset * 2, Self.userRailMaxWidth)
        rebuildUserBody(model: model, contentWidth: contentWidth, totalWidth: width)
      } else if model.messageType == .steer {
        contentWidth = min(width - Self.laneHorizontalInset * 2, Self.assistantRailMaxWidth)
        rebuildSteerBody(model: model, contentWidth: contentWidth)
      } else if model.messageType == .thinking {
        contentWidth = min(width - Self.laneHorizontalInset * 2, Self.thinkingRailMaxWidth)
        rebuildThinkingBody(model: model, contentWidth: contentWidth)
      } else {
        contentWidth = min(width - Self.laneHorizontalInset * 2, Self.assistantRailMaxWidth)
        rebuildAssistantBody(model: model, contentWidth: contentWidth)
      }

      // Body container starts after header + spacing
      let bodyHeight = Self.bodyHeight(for: width, model: model, blocks: currentBlocks)
      bodyContainer.frame = CGRect(x: 0, y: bodyY, width: width, height: bodyHeight)
    }

    private func rebuildAssistantBody(model: NativeRichMessageRowModel, contentWidth: CGFloat) {
      let mdHeight = NativeMarkdownContentView.requiredHeight(for: currentBlocks, width: contentWidth)
      markdownContentView.frame = CGRect(
        x: Self.laneHorizontalInset, y: 0,
        width: contentWidth, height: mdHeight
      )
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

      let bubbleWidth = min(contentWidth, innerWidth + Self.userBubbleHorizontalPad * 2 + Self.userAccentBarWidth)
      let bubbleX = totalWidth - Self.laneHorizontalInset - bubbleWidth

      bubbleBackground.frame = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
      bubbleBackground.isHidden = false
      bodyContainer.addSubview(bubbleBackground)

      accentBar.frame = CGRect(
        x: bubbleX + bubbleWidth - Self.userAccentBarWidth,
        y: 0,
        width: Self.userAccentBarWidth,
        height: bubbleHeight
      )
      accentBar.isHidden = false
      bodyContainer.addSubview(accentBar)

      markdownContentView.frame = CGRect(
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
      let font = PlatformFont.systemFont(ofSize: TypeScale.subhead).withItalic()
      let para = NSMutableParagraphStyle()
      para.lineSpacing = 3
      let attrStr = NSAttributedString(string: model.content, attributes: [
        .font: font,
        .foregroundColor: UIColor.secondaryLabel,
        .paragraphStyle: para,
      ])

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

    private func rebuildThinkingBody(model: NativeRichMessageRowModel, contentWidth: CGFloat) {
      let hPad = Self.thinkingHPad
      let vTop = Self.thinkingVPadTop
      let vBottom = Self.thinkingVPadBottom
      let innerWidth = contentWidth - hPad * 2
      let displayBlocks = MarkdownAttributedStringRenderer.parse(model.displayContent, style: .thinking)
      let mdHeight = NativeMarkdownContentView.requiredHeight(for: displayBlocks, width: innerWidth)

      let hasShowMore = model.isThinkingLong
      let isCollapsed = hasShowMore && !model.isThinkingExpanded

      // Bottom area: show more button only (fade mask handles the transition)
      let bottomZoneHeight: CGFloat = hasShowMore ? Self.thinkingShowMoreHeight : 0
      let containerHeight = vTop + mdHeight + vBottom + bottomZoneHeight

      // Purple background
      thinkingBackground.frame = CGRect(
        x: Self.laneHorizontalInset, y: 0,
        width: contentWidth, height: containerHeight
      )
      thinkingBackground.isHidden = false
      bodyContainer.addSubview(thinkingBackground)

      // Markdown content
      let contentX = Self.laneHorizontalInset + hPad
      markdownContentView.frame = CGRect(x: contentX, y: vTop, width: innerWidth, height: mdHeight)
      markdownContentView.configure(blocks: displayBlocks)
      bodyContainer.addSubview(markdownContentView)

      // Gradient mask: fade text to transparent over the last lines when collapsed
      if isCollapsed {
        let maskLayer = CAGradientLayer()
        maskLayer.frame = markdownContentView.bounds
        let fadeStart = max(0, 1.0 - Double(Self.thinkingFadeHeight) / Double(mdHeight))
        maskLayer.colors = [
          UIColor.white.cgColor,
          UIColor.white.cgColor,
          UIColor.clear.cgColor,
        ]
        maskLayer.locations = [0, NSNumber(value: fadeStart), 1.0]
        markdownContentView.layer.mask = maskLayer
      }

      thinkingFadeOverlay.isHidden = true
      thinkingSeparator.isHidden = true

      // "Show more / Show less" button
      if hasShowMore {
        let buttonY = vTop + mdHeight + vBottom
        thinkingShowMoreButton.setTitle(
          model.isThinkingExpanded ? "Show less" : "Show more\u{2026}",
          for: .normal
        )
        thinkingShowMoreButton.frame = CGRect(
          x: Self.laneHorizontalInset + hPad,
          y: buttonY,
          width: innerWidth,
          height: Self.thinkingShowMoreHeight
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
        let displayImage = cached.displayImage

        let aspect = displayImage.size.width / max(displayImage.size.height, 1)
        let displayWidth = min(Self.imageMaxWidth, availableWidth)
        let displayHeight = min(Self.imageMaxHeight, displayWidth / aspect)
        let finalWidth = displayHeight * aspect

        let imageX: CGFloat = isUserAligned
          ? leadingX + availableWidth - finalWidth
          : leadingX

        let container = makeImageContainer(
          frame: CGRect(x: imageX, y: currentY, width: finalWidth, height: displayHeight),
          shadowRadius: 8, shadowOffset: 4, shadowOpacity: 0.3
        )
        let imageView = makeClippedImageView(in: container)
        imageView.image = displayImage
        imageView.contentMode = .scaleAspectFit
        addFullscreenTap(to: container, imageIndex: 0)
        bodyContainer.addSubview(container)

        currentY += displayHeight + Self.imageDimensionSpacing

        let dimText = Self.formatDimensions(
          width: cached.originalWidth,
          height: cached.originalHeight,
          bytes: image.byteCount
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
          guard let displayImage = ImageCache.shared.image(for: image) else { continue }

          let size = Self.imageThumbnailSize
          if x + size > leadingX + availableWidth, x > leadingX {
            x = leadingX
            y += size + Self.imageSpacing
          }

          let container = makeImageContainer(
            frame: CGRect(x: x, y: y, width: size, height: size),
            shadowRadius: 6, shadowOffset: 3, shadowOpacity: 0.25
          )
          let imageView = makeClippedImageView(in: container)
          imageView.image = displayImage
          imageView.contentMode = .scaleAspectFill
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
      let sizeText = Self.formatBytes(totalBytes)
      let label = UILabel()
      label.text = "\(countText)  \u{00B7}  \(sizeText)"
      label.font = .systemFont(ofSize: 12, weight: .medium)
      label.textColor = .secondaryLabel
      label.sizeToFit()
      label.frame.origin = CGPoint(x: 34, y: (Self.imageHeaderHeight - label.frame.height) / 2)
      bar.addSubview(label)

      return bar
    }

    private static func makeDimensionLabel(text: String) -> UILabel {
      let label = UILabel()
      label.text = text
      label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
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
      label.font = .systemFont(ofSize: 11, weight: .bold)
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
      guard !images.isEmpty else { return 0 }

      let headerTotal = imageSpacing + imageHeaderHeight + imageSpacing

      if images.count == 1 {
        let image = images[0]
        guard let displayImage = ImageCache.shared.image(for: image) else { return 0 }
        let aspect = displayImage.size.width / max(displayImage.size.height, 1)
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

    static func requiredHeight(for width: CGFloat, model: NativeRichMessageRowModel) -> CGFloat {
      guard width > 1 else { return 1 }
      let blocks = MarkdownAttributedStringRenderer.parse(
        model.displayContent,
        style: model.messageType == .thinking ? .thinking : .standard
      )
      let body = bodyHeight(for: width, model: model, blocks: blocks)
      let total = max(1, ceil(headerHeight + headerToBodySpacing + body + entryBottomSpacing))
      logger.debug(
        "requiredHeight-rich[\(model.messageID.prefix(8))] \(model.messageType) "
          + "header=\(f(headerHeight)) body=\(f(body)) total=\(f(total)) "
          + "w=\(f(width)) blocks=\(blocks.count)"
      )
      return total
    }

    private static func bodyHeight(
      for width: CGFloat,
      model: NativeRichMessageRowModel,
      blocks: [MarkdownBlock]
    ) -> CGFloat {
      if model.isUserAligned {
        let contentWidth = min(width - laneHorizontalInset * 2, userRailMaxWidth)
        let innerWidth = contentWidth - userBubbleHorizontalPad * 2 - userAccentBarWidth
        let mdHeight = NativeMarkdownContentView.requiredHeight(for: blocks, width: innerWidth)
        let bubbleHeight = mdHeight + userBubbleVerticalPad * 2
        let imgHeight = imageBlockHeight(for: model.images, availableWidth: contentWidth)
        return bubbleHeight + imgHeight
      } else if model.messageType == .steer {
        let contentWidth = min(width - laneHorizontalInset * 2, assistantRailMaxWidth)
        let font = PlatformFont.systemFont(ofSize: TypeScale.subhead).withItalic()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attrStr = NSAttributedString(string: model.content, attributes: [
          .font: font,
          .foregroundColor: UIColor.secondaryLabel,
          .paragraphStyle: para,
        ])
        return NativeMarkdownContentView.measureTextHeight(attrStr, width: contentWidth)
      } else if model.messageType == .thinking {
        let contentWidth = min(width - laneHorizontalInset * 2, thinkingRailMaxWidth)
        let innerWidth = contentWidth - thinkingHPad * 2
        let mdHeight = NativeMarkdownContentView.requiredHeight(for: blocks, width: innerWidth)
        let bottomZone: CGFloat = model.isThinkingLong ? thinkingShowMoreHeight : 0
        return thinkingVPadTop + mdHeight + thinkingVPadBottom + bottomZone
      } else {
        let contentWidth = min(width - laneHorizontalInset * 2, assistantRailMaxWidth)
        let mdHeight = NativeMarkdownContentView.requiredHeight(for: blocks, width: contentWidth)
        let imgHeight = imageBlockHeight(for: model.images, availableWidth: contentWidth)
        return mdHeight + imgHeight
      }
    }
  }

#endif
