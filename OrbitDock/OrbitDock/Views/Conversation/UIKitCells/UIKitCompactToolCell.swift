//
//  UIKitCompactToolCell.swift
//  OrbitDock
//
//  Native UICollectionViewCell for compact (collapsed) tool rows on iOS.
//  Ports NativeCompactToolCellView (macOS NSTableCellView) to UIKit.
//  Dynamic height based on summary text wrapping.
//
//  Structure:
//    - Thread line (2pt vertical connector)
//    - Glyph icon (18pt)
//    - Summary label (monospaced, wrapping)
//    - Right metadata label (duration, line count, etc.)
//    - Tap to expand → onTap callback
//

#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitCompactToolCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitCompactToolCell"

    private let threadLine = UIView()
    private let glyphImage = UIImageView()
    private let summaryLabel = UILabel()
    private let metaLabel = UILabel()
    private let contextLabel = UILabel()
    private let snippetLabel = UILabel()
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

      let inset = ConversationLayout.laneHorizontalInset

      // Thread line
      threadLine.backgroundColor = PlatformColor(Color.textQuaternary).withAlphaComponent(0.4)
      threadLine.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(threadLine)

      // Glyph
      let symbolConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .medium)
      glyphImage.preferredSymbolConfiguration = symbolConfig
      glyphImage.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(glyphImage)

      // Summary
      summaryLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      summaryLabel.textColor = UIColor.white.withAlphaComponent(0.58)
      summaryLabel.lineBreakMode = .byCharWrapping
      summaryLabel.numberOfLines = 0
      summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      summaryLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(summaryLabel)

      // Meta
      metaLabel.font = UIFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
      metaLabel.textColor = PlatformColor(Color.textTertiary)
      metaLabel.lineBreakMode = .byTruncatingTail
      metaLabel.textAlignment = .right
      metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      metaLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(metaLabel)

      // Context label — unchanged line before the edit (dimmed)
      contextLabel.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
      contextLabel.textColor = UIColor.white.withAlphaComponent(0.25)
      contextLabel.lineBreakMode = .byTruncatingTail
      contextLabel.numberOfLines = 1
      contextLabel.isHidden = true
      contextLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(contextLabel)

      // Snippet label — first changed line preview
      snippetLabel.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
      snippetLabel.lineBreakMode = .byTruncatingTail
      snippetLabel.numberOfLines = 1
      snippetLabel.isHidden = true
      snippetLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(snippetLabel)

      // Diff bar — green/red ratio indicator
      diffBarContainer.isHidden = true
      diffBarContainer.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(diffBarContainer)

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
        threadLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset + 6),
        threadLine.widthAnchor.constraint(equalToConstant: 2),
        threadLine.topAnchor.constraint(equalTo: contentView.topAnchor),
        threadLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

        glyphImage.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset + 16),
        glyphImage.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
        glyphImage.widthAnchor.constraint(equalToConstant: 18),

        summaryLabel.leadingAnchor.constraint(equalTo: glyphImage.trailingAnchor, constant: 4),
        summaryLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
        summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -8),

        metaLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        metaLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

        // Context — below summary (shown when surrounding context exists)
        contextLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
        contextLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 2),
        contextLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -inset),

        // Snippet — below context
        snippetLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
        snippetLabel.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 0),
        snippetLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -inset),

        // Diff bar — below snippet
        diffBarContainer.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
        diffBarContainer.topAnchor.constraint(equalTo: snippetLabel.bottomAnchor, constant: 3),
        diffBarContainer.heightAnchor.constraint(equalToConstant: 3),
        diffBarContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 80),

        diffBarAdded.leadingAnchor.constraint(equalTo: diffBarContainer.leadingAnchor),
        diffBarAdded.topAnchor.constraint(equalTo: diffBarContainer.topAnchor),
        diffBarAdded.heightAnchor.constraint(equalToConstant: 3),
        addedW,

        diffBarRemoved.leadingAnchor.constraint(equalTo: diffBarAdded.trailingAnchor, constant: 1),
        diffBarRemoved.topAnchor.constraint(equalTo: diffBarContainer.topAnchor),
        diffBarRemoved.heightAnchor.constraint(equalToConstant: 3),
        removedW,
      ])

      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
      contentView.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
      onTap?()
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onTap = nil
      contextLabel.isHidden = true
      snippetLabel.isHidden = true
      diffBarContainer.isHidden = true
    }

    static func requiredHeight(
      for width: CGFloat,
      summary: String,
      hasDiffPreview: Bool = false,
      hasContextLine: Bool = false
    ) -> CGFloat {
      let inset = ConversationLayout.laneHorizontalInset
      let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      // glyph leading: inset + 16 + 18 (glyph) + 4 (gap) = inset + 38
      // meta trailing area ~ 60pt reserve
      let textWidth = max(60, width - inset * 2 - 38 - 60)
      let textH = ExpandedToolLayout.measuredTextHeight(summary, font: font, maxWidth: textWidth)
      let baseHeight = max(ConversationLayout.compactToolRowHeight, textH + 12)
      if hasDiffPreview {
        let contextExtra: CGFloat = hasContextLine ? 14 : 0
        return baseHeight + 22 + contextExtra
      }
      return baseHeight
    }

    func configure(model: NativeCompactToolRowModel) {
      glyphImage.image = UIImage(systemName: model.glyphSymbol)
      glyphImage.tintColor = model.glyphColor.withAlphaComponent(0.7)
      glyphImage.alpha = model.isInProgress ? 0.4 : 0.8
      summaryLabel.text = model.summary

      if let meta = model.rightMeta {
        metaLabel.isHidden = false
        metaLabel.text = meta
      } else {
        metaLabel.isHidden = true
      }

      if let preview = model.diffPreview {
        // Context line (unchanged code before the edit)
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
            .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: prefixColor.withAlphaComponent(0.7),
          ]
        ))
        attributed.append(NSAttributedString(
          string: preview.snippetText,
          attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: prefixColor.withAlphaComponent(0.7),
          ]
        ))
        snippetLabel.attributedText = attributed
        snippetLabel.isHidden = false

        // Diff bar
        let total = CGFloat(preview.additions + preview.deletions)
        let maxBarWidth: CGFloat = 80
        let addedFraction = total > 0 ? CGFloat(preview.additions) / total : 1
        let addedWidth = round(addedFraction * maxBarWidth)
        let removedWidth = max(0, maxBarWidth - addedWidth - 1)

        diffBarAddedWidth?.constant = addedWidth
        diffBarRemovedWidth?.constant = preview.deletions > 0 ? removedWidth : 0

        diffBarAdded.backgroundColor = ExpandedToolLayout.addedAccentColor.withAlphaComponent(0.6)
        diffBarRemoved.backgroundColor = ExpandedToolLayout.removedAccentColor.withAlphaComponent(0.6)
        diffBarRemoved.isHidden = preview.deletions == 0
        diffBarContainer.isHidden = false
      } else {
        contextLabel.isHidden = true
        snippetLabel.isHidden = true
        diffBarContainer.isHidden = true
      }
    }
  }

#endif
