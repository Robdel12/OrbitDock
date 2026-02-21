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
        summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -6),

        metaLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        metaLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
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
    }

    static func requiredHeight(for width: CGFloat, summary: String) -> CGFloat {
      let inset = ConversationLayout.laneHorizontalInset
      let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      // glyph leading: inset + 16 + 18 (glyph) + 4 (gap) = inset + 38
      // meta trailing area ~ 60pt reserve
      let textWidth = max(60, width - inset * 2 - 38 - 60)
      let textH = ExpandedToolLayout.measuredTextHeight(summary, font: font, maxWidth: textWidth)
      return max(ConversationLayout.compactToolRowHeight, textH + 12)
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
    }
  }

#endif
