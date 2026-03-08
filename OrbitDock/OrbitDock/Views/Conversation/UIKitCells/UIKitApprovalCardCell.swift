//
//  UIKitApprovalCardCell.swift
//  OrbitDock
//
//  Slim iOS approval indicator for the conversation timeline.
//  Detailed interaction lives in the composer's inline pending zone.
//

#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitApprovalCardCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitApprovalCardCell"

    /// Fixed height for the slim indicator strip.
    static let stripHeight: CGFloat = 34

    private let stripContainer = UIView()
    private let accentBar = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let dotLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevronView = UIImageView()

    private var currentModel: ApprovalCardModel?

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

      // Strip container
      stripContainer.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.layer.cornerRadius = CGFloat(Radius.md)
      stripContainer.clipsToBounds = true
      contentView.addSubview(stripContainer)

      // Tap gesture on entire strip
      let tap = UITapGestureRecognizer(target: self, action: #selector(stripTapped))
      stripContainer.addGestureRecognizer(tap)

      // Left accent edge bar (3pt)
      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.layer.cornerRadius = CGFloat(Radius.xs)
      stripContainer.addSubview(accentBar)

      // Icon
      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.contentMode = .scaleAspectFit
      stripContainer.addSubview(iconView)

      // Title
      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      titleLabel.textColor = UIColor(Color.textPrimary)
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
      stripContainer.addSubview(titleLabel)

      // Dot separator
      dotLabel.translatesAutoresizingMaskIntoConstraints = false
      dotLabel.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      dotLabel.textColor = UIColor(Color.textQuaternary)
      dotLabel.text = "\u{00B7}"
      dotLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      stripContainer.addSubview(dotLabel)

      // Subtitle
      subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
      subtitleLabel.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      subtitleLabel.textColor = UIColor(Color.textTertiary)
      subtitleLabel.lineBreakMode = .byTruncatingTail
      subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      stripContainer.addSubview(subtitleLabel)

      // Chevron
      chevronView.translatesAutoresizingMaskIntoConstraints = false
      chevronView.image = UIImage(systemName: "chevron.right")
      chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 8, weight: .bold
      )
      chevronView.tintColor = UIColor(Color.textQuaternary)
      chevronView.alpha = 0.25
      stripContainer.addSubview(chevronView)

      let inset = ConversationLayout.laneHorizontalInset
      NSLayoutConstraint.activate([
        stripContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: ConversationStripRowMetrics.verticalInset),
        stripContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        stripContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        stripContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -ConversationStripRowMetrics.verticalInset),

        accentBar.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.accentVerticalInset),
        accentBar.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor, constant: ConversationStripRowMetrics.accentLeadingInset),
        accentBar.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor, constant: -ConversationStripRowMetrics.accentVerticalInset),
        accentBar.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.accentWidth),

        iconView.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        iconView.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: CGFloat(Spacing.sm)),
        iconView.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.iconSize),
        iconView.heightAnchor.constraint(equalToConstant: ConversationStripRowMetrics.iconSize),

        titleLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: CGFloat(Spacing.xs)),

        dotLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        dotLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: CGFloat(Spacing.xs)),

        subtitleLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        subtitleLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: CGFloat(Spacing.xs)),
        subtitleLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: chevronView.leadingAnchor, constant: -CGFloat(Spacing.sm)
        ),

        chevronView.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        chevronView.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor, constant: -CGFloat(Spacing.md_)),
        chevronView.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.chevronWidth),
        chevronView.heightAnchor.constraint(equalToConstant: ConversationStripRowMetrics.chevronHeight),
      ])
    }

    func configure(model: ApprovalCardModel) {
      currentModel = model

      let stripConfig = ApprovalCardConfiguration.stripConfig(for: model)
      let tint = UIColor(stripConfig.iconTint)

      // Background + accent
      stripContainer.backgroundColor = UIColor(stripConfig.backgroundColor).withAlphaComponent(stripConfig.backgroundOpacity)
      accentBar.backgroundColor = tint.withAlphaComponent(stripConfig.accentOpacity)

      // Icon
      iconView.image = UIImage(systemName: stripConfig.iconName)
      iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 12, weight: .semibold
      )
      iconView.tintColor = tint

      titleLabel.text = stripConfig.title
      subtitleLabel.text = stripConfig.subtitle
    }

    @objc private func stripTapped() {
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
