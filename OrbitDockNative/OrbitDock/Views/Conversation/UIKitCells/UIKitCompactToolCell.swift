//
//  UIKitCompactToolCell.swift
//  OrbitDock
//
//  Native UICollectionViewCell for compact (collapsed) tool rows on iOS.
//  Matches macOS NativeCompactToolCellView strip card pattern.
//
//  Structure:
//    - Strip card container (cornerRadius 6, subtle bg)
//    - Accent bar (3pt, tool-colored)
//    - Glyph icon (16pt)
//    - Title + dot + subtitle
//    - Right metadata label
//    - Chevron expand indicator
//    - Detail area: context/snippet/diff bar or todo/output preview
//

#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitCompactToolCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitCompactToolCell"

    private let cardBg = CellCardBackground()

    // Strip card
    private let stripContainer = UIView()
    private let accentBar = UIView()
    private let glyphImage = UIImageView()
    private let titleField = UILabel()
    private let dotSeparator = UILabel()
    private let subtitleField = UILabel()
    private let metaLabel = UILabel()
    private let chevronView = UIImageView()

    // Detail area
    private let contextLabel = UILabel()
    private let snippetLabel = UILabel()
    private let outputPreviewLabel = UILabel()
    private let todoPreviewLabel = UILabel()
    private let diffBarContainer = UIView()
    private let diffBarAdded = UIView()
    private let diffBarRemoved = UIView()
    private var diffBarAddedWidth: NSLayoutConstraint?
    private var diffBarRemovedWidth: NSLayoutConstraint?

    var onTap: (() -> Void)?

    override init(frame: CGRect) {
      super.init(frame: frame)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    private func setup() {
      backgroundColor = .clear
      contentView.backgroundColor = .clear

      cardBg.install(in: contentView)

      let inset = ConversationLayout.laneHorizontalInset

      // Strip container
      stripContainer.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.layer.cornerRadius = CGFloat(Radius.md)
      stripContainer.backgroundColor = UIColor.white.withAlphaComponent(0.035)
      contentView.addSubview(stripContainer)

      // Accent bar
      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.layer.cornerRadius = CGFloat(Radius.xs)
      stripContainer.addSubview(accentBar)

      // Glyph
      glyphImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 12, weight: .semibold
      )
      glyphImage.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(glyphImage)

      // Title
      titleField.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      titleField.textColor = PlatformColor(Color.textPrimary)
      titleField.lineBreakMode = .byTruncatingTail
      titleField.numberOfLines = 1
      titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      titleField.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(titleField)

      // Dot separator
      dotSeparator.font = UIFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      dotSeparator.textColor = PlatformColor(Color.textQuaternary)
      dotSeparator.text = "\u{00B7}"
      dotSeparator.isHidden = true
      dotSeparator.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(dotSeparator)

      // Subtitle
      subtitleField.font = UIFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      subtitleField.textColor = PlatformColor(Color.textTertiary)
      subtitleField.lineBreakMode = .byTruncatingTail
      subtitleField.numberOfLines = 1
      subtitleField.setContentCompressionResistancePriority(
        UILayoutPriority(UILayoutPriority.defaultLow.rawValue - 1), for: .horizontal
      )
      subtitleField.isHidden = true
      subtitleField.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(subtitleField)

      // Meta
      metaLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
      metaLabel.textColor = PlatformColor(Color.textTertiary)
      metaLabel.lineBreakMode = .byTruncatingTail
      metaLabel.textAlignment = .right
      metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      metaLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(metaLabel)

      // Chevron
      chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 8, weight: .bold
      )
      chevronView.image = UIImage(systemName: "chevron.right")
      chevronView.tintColor = PlatformColor(Color.textQuaternary)
      chevronView.alpha = 0.25
      chevronView.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(chevronView)

      // Context label — unchanged line before the edit (dimmed)
      contextLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
      contextLabel.textColor = UIColor.white.withAlphaComponent(0.25)
      contextLabel.lineBreakMode = .byTruncatingTail
      contextLabel.numberOfLines = 1
      contextLabel.isHidden = true
      contextLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(contextLabel)

      // Snippet label — first changed line preview
      snippetLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
      snippetLabel.lineBreakMode = .byTruncatingTail
      snippetLabel.numberOfLines = 1
      snippetLabel.isHidden = true
      snippetLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(snippetLabel)

      // Output preview — up to 3 lines
      outputPreviewLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
      outputPreviewLabel.textColor = PlatformColor(Color.textQuaternary)
      outputPreviewLabel.lineBreakMode = .byTruncatingTail
      outputPreviewLabel.numberOfLines = 3
      outputPreviewLabel.isHidden = true
      outputPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(outputPreviewLabel)

      // Todo preview — symbol sequence
      todoPreviewLabel.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      todoPreviewLabel.lineBreakMode = .byTruncatingTail
      todoPreviewLabel.numberOfLines = 1
      todoPreviewLabel.isHidden = true
      todoPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(todoPreviewLabel)

      // Diff bar — green/red ratio indicator
      diffBarContainer.isHidden = true
      diffBarContainer.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(diffBarContainer)

      diffBarAdded.layer.cornerRadius = 1.5
      diffBarAdded.translatesAutoresizingMaskIntoConstraints = false
      diffBarContainer.addSubview(diffBarAdded)

      diffBarRemoved.layer.cornerRadius = 1.5
      diffBarRemoved.translatesAutoresizingMaskIntoConstraints = false
      diffBarContainer.addSubview(diffBarRemoved)

      let addedW = diffBarAdded.widthAnchor.constraint(equalToConstant: 0)
      let removedW = diffBarRemoved.widthAnchor.constraint(equalToConstant: 0)
      diffBarAddedWidth = addedW
      diffBarRemovedWidth = removedW

      NSLayoutConstraint.activate([
        // Strip container: 3pt top/bottom, inset leading/trailing
        stripContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: ConversationStripRowMetrics.verticalInset),
        stripContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        stripContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        stripContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -ConversationStripRowMetrics.verticalInset),

        // Accent bar: 3pt wide, 6pt inset top/bottom, 5pt from leading
        accentBar.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.accentVerticalInset),
        accentBar.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor, constant: ConversationStripRowMetrics.accentLeadingInset),
        accentBar.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor, constant: -ConversationStripRowMetrics.accentVerticalInset),
        accentBar.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.accentWidth),

        // Icon: 16pt wide, top 9pt from strip top
        glyphImage.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: CGFloat(Spacing.sm)),
        glyphImage.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.iconTopInset),
        glyphImage.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.iconSize),

        // Title
        titleField.leadingAnchor.constraint(equalTo: glyphImage.trailingAnchor, constant: CGFloat(Spacing.xs)),
        titleField.centerYAnchor.constraint(equalTo: glyphImage.centerYAnchor),
        titleField.trailingAnchor.constraint(lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -CGFloat(Spacing.sm)),

        // Dot separator
        dotSeparator.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: CGFloat(Spacing.xs)),
        dotSeparator.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

        // Subtitle
        subtitleField.leadingAnchor.constraint(equalTo: dotSeparator.trailingAnchor, constant: CGFloat(Spacing.xs)),
        subtitleField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
        subtitleField.trailingAnchor.constraint(
          lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -CGFloat(Spacing.sm)
        ),

        // Meta — right-aligned
        metaLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -CGFloat(Spacing.sm_)),
        metaLabel.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

        // Chevron — far right
        chevronView.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor, constant: -CGFloat(Spacing.md_)),
        chevronView.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
        chevronView.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.chevronWidth),

        // Context — below title
        contextLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        contextLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: ConversationStripRowMetrics.detailTopSpacing),
        contextLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: chevronView.leadingAnchor, constant: -CGFloat(Spacing.sm)
        ),

        // Snippet — below context
        snippetLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        snippetLabel.topAnchor.constraint(equalTo: contextLabel.bottomAnchor),
        snippetLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: chevronView.leadingAnchor, constant: -CGFloat(Spacing.sm)
        ),

        // Output preview — below title (alternative to context/snippet)
        outputPreviewLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        outputPreviewLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: ConversationStripRowMetrics.detailTopSpacing),
        outputPreviewLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: chevronView.leadingAnchor, constant: -CGFloat(Spacing.sm)
        ),

        // Todo preview — below title (alternative to context/snippet)
        todoPreviewLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        todoPreviewLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: ConversationStripRowMetrics.detailTopSpacing),
        todoPreviewLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: chevronView.leadingAnchor, constant: -CGFloat(Spacing.sm)
        ),

        // Diff bar — below snippet
        diffBarContainer.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
        diffBarContainer.topAnchor.constraint(equalTo: snippetLabel.bottomAnchor, constant: 2),
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

      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
      contentView.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
      onTap?()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      cardBg.layoutInBounds(contentView.bounds)
    }

    func configureCardPosition(_ position: CardPosition, topInset: CGFloat, bottomInset: CGFloat) {
      cardBg.configure(position: position, topInset: topInset, bottomInset: bottomInset)
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      cardBg.reset()
      onTap = nil
      dotSeparator.isHidden = true
      subtitleField.isHidden = true
      contextLabel.isHidden = true
      snippetLabel.isHidden = true
      outputPreviewLabel.isHidden = true
      todoPreviewLabel.isHidden = true
      diffBarContainer.isHidden = true
    }

    static func requiredHeight(model: NativeCompactToolRowModel, width: CGFloat) -> CGFloat {
      NativeCompactToolRowModel.requiredHeight(for: model, width: width)
    }

    func configure(model: NativeCompactToolRowModel) {
      // Accent bar
      accentBar.backgroundColor = model.glyphColor.withAlphaComponent(0.6)

      // Icon
      glyphImage.image = UIImage(systemName: model.glyphSymbol)
      glyphImage.tintColor = model.glyphColor.withAlphaComponent(0.8)
      glyphImage.alpha = model.isInProgress ? 0.5 : 1.0

      // Title — monospaced for bash, system for others
      if model.toolType == .bash {
        titleField.font = UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .semibold)
      } else {
        titleField.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      }
      titleField.text = model.summary

      // Subtitle
      if let subtitle = model.subtitle {
        dotSeparator.isHidden = false
        subtitleField.isHidden = false
        subtitleField.text = subtitle
      } else {
        dotSeparator.isHidden = true
        subtitleField.isHidden = true
      }

      // Meta
      if let meta = model.rightMeta {
        metaLabel.isHidden = false
        metaLabel.text = meta
      } else {
        metaLabel.isHidden = true
      }

      // Detail area
      if let preview = model.diffPreview {
        configureDiffPreview(preview)
      } else if let livePreview = model.liveOutputPreview {
        configureLivePreview(livePreview)
      } else if let items = model.todoItems, !items.isEmpty {
        configureTodoPreview(items)
      } else if let preview = model.outputPreview {
        configureOutputPreview(preview)
      } else {
        contextLabel.isHidden = true
        snippetLabel.isHidden = true
        outputPreviewLabel.isHidden = true
        todoPreviewLabel.isHidden = true
        diffBarContainer.isHidden = true
      }
    }

    // MARK: - Detail Configurators

    private func configureDiffPreview(_ preview: DiffPreviewInfo) {
      outputPreviewLabel.isHidden = true
      todoPreviewLabel.isHidden = true

      // Context line
      if let ctx = preview.contextLine {
        contextLabel.text = "  \(ctx)"
        contextLabel.isHidden = false
      } else {
        contextLabel.isHidden = true
      }

      // Snippet
      let prefixColor = preview.isAddition
        ? ExpandedToolLayout.addedAccentColor
        : ExpandedToolLayout.removedAccentColor
      let attributed = NSMutableAttributedString()
      attributed.append(NSAttributedString(
        string: "\(preview.snippetPrefix) ",
        attributes: [
          .font: UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .bold),
          .foregroundColor: prefixColor.withAlphaComponent(0.7),
        ]
      ))
      attributed.append(NSAttributedString(
        string: preview.snippetText,
        attributes: [
          .font: UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular),
          .foregroundColor: prefixColor.withAlphaComponent(0.7),
        ]
      ))
      snippetLabel.attributedText = attributed
      snippetLabel.isHidden = false

      // Diff bar
      let widths = preview.barWidths(maxWidth: 100)
      diffBarAddedWidth?.constant = widths.added
      diffBarRemovedWidth?.constant = widths.removed
      diffBarAdded.backgroundColor = ExpandedToolLayout.addedAccentColor.withAlphaComponent(0.6)
      diffBarRemoved.backgroundColor = ExpandedToolLayout.removedAccentColor.withAlphaComponent(0.6)
      diffBarRemoved.isHidden = preview.deletions == 0
      diffBarContainer.isHidden = false
    }

    private func configureLivePreview(_ livePreview: String) {
      contextLabel.isHidden = true
      diffBarContainer.isHidden = true
      outputPreviewLabel.isHidden = true
      todoPreviewLabel.isHidden = true

      let color = PlatformColor(Color.toolBash).withAlphaComponent(0.72)
      let attributed = NSMutableAttributedString()
      attributed.append(NSAttributedString(
        string: "> ",
        attributes: [
          .font: UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .bold),
          .foregroundColor: color,
        ]
      ))
      attributed.append(NSAttributedString(
        string: livePreview,
        attributes: [
          .font: UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular),
          .foregroundColor: color,
        ]
      ))
      snippetLabel.attributedText = attributed
      snippetLabel.isHidden = false
    }

    private func configureTodoPreview(_ items: [CompactTodoItem]) {
      contextLabel.isHidden = true
      snippetLabel.isHidden = true
      diffBarContainer.isHidden = true
      outputPreviewLabel.isHidden = true

      let attributed = NSMutableAttributedString()
      let maxItems = min(items.count, 8)
      for i in 0 ..< maxItems {
        let item = items[i]
        let (symbol, color): (String, UIColor) = switch item.status {
          case .completed: ("\u{2713}", PlatformColor(Color.toolWrite).withAlphaComponent(0.7))
          case .inProgress: ("\u{25C9}", PlatformColor(Color.accent).withAlphaComponent(0.8))
          case .pending, .unknown: ("\u{25CB}", PlatformColor(Color.textQuaternary))
          case .blocked: ("\u{2298}", PlatformColor(Color.statusPermission).withAlphaComponent(0.7))
          case .canceled: ("\u{2298}", PlatformColor(Color.textQuaternary).withAlphaComponent(0.5))
        }
        if i > 0 { attributed.append(NSAttributedString(string: " ")) }
        attributed.append(NSAttributedString(
          string: symbol,
          attributes: [
            .font: UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium),
            .foregroundColor: color,
          ]
        ))
      }
      if items.count > maxItems {
        attributed.append(NSAttributedString(
          string: " +\(items.count - maxItems)",
          attributes: [
            .font: UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium),
            .foregroundColor: PlatformColor(Color.textQuaternary),
          ]
        ))
      }
      todoPreviewLabel.attributedText = attributed
      todoPreviewLabel.isHidden = false
    }

    private func configureOutputPreview(_ preview: String) {
      contextLabel.isHidden = true
      snippetLabel.isHidden = true
      diffBarContainer.isHidden = true
      todoPreviewLabel.isHidden = true

      outputPreviewLabel.text = preview
      outputPreviewLabel.isHidden = false
    }
  }

#endif
