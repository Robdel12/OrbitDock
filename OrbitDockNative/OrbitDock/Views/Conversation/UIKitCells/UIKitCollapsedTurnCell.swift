//
//  UIKitCollapsedTurnCell.swift
//  OrbitDock
//
//  Collapsed turn summary row for iOS focus mode.
//

#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitCollapsedTurnCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitCollapsedTurnCell"

    private let stripContainer = UIView()
    private let accentBar = UIView()
    private let disclosureIcon = UIImageView()
    private let userLabel = UILabel()
    private let dotLabel = UILabel()
    private let assistantLabel = UILabel()
    private let statsLabel = UILabel()

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

      stripContainer.backgroundColor = UIColor.white.withAlphaComponent(0.02)
      stripContainer.layer.cornerRadius = Radius.md
      stripContainer.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(stripContainer)

      accentBar.backgroundColor = UIColor(Color.textTertiary).withAlphaComponent(0.2)
      accentBar.layer.cornerRadius = Radius.xs
      accentBar.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(accentBar)

      disclosureIcon.image = UIImage(systemName: "chevron.right")
      disclosureIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
      disclosureIcon.tintColor = UIColor(Color.textTertiary)
      disclosureIcon.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(disclosureIcon)

      userLabel.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      userLabel.textColor = UIColor(Color.textSecondary)
      userLabel.lineBreakMode = .byTruncatingTail
      userLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(userLabel)

      dotLabel.text = "·"
      dotLabel.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      dotLabel.textColor = UIColor(Color.textQuaternary)
      dotLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(dotLabel)

      assistantLabel.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .regular)
      assistantLabel.textColor = UIColor(Color.textTertiary)
      assistantLabel.lineBreakMode = .byTruncatingTail
      assistantLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(assistantLabel)

      statsLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
      statsLabel.textColor = UIColor(Color.textQuaternary)
      statsLabel.textAlignment = .right
      statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      statsLabel.translatesAutoresizingMaskIntoConstraints = false
      stripContainer.addSubview(statsLabel)

      NSLayoutConstraint.activate([
        stripContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: ConversationStripRowMetrics.verticalInset),
        stripContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -ConversationStripRowMetrics.verticalInset),
        stripContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        stripContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),

        accentBar.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor, constant: ConversationStripRowMetrics.accentLeadingInset),
        accentBar.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: ConversationStripRowMetrics.accentVerticalInset),
        accentBar.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor, constant: -ConversationStripRowMetrics.accentVerticalInset),
        accentBar.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.accentWidth),

        disclosureIcon.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: Spacing.sm),
        disclosureIcon.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        disclosureIcon.widthAnchor.constraint(equalToConstant: ConversationStripRowMetrics.disclosureWidth),

        userLabel.leadingAnchor.constraint(equalTo: disclosureIcon.trailingAnchor, constant: Spacing.sm_),
        userLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        userLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

        dotLabel.leadingAnchor.constraint(equalTo: userLabel.trailingAnchor, constant: Spacing.xs),
        dotLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),

        assistantLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: Spacing.xs),
        assistantLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        assistantLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsLabel.leadingAnchor, constant: -Spacing.sm),

        statsLabel.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor, constant: -Spacing.md_),
        statsLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
      ])

      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
      contentView.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
      onTap?()
    }

    func configure(model: ConversationUtilityRowModels.CollapsedTurnModel) {
      userLabel.text = model.userPreview
      assistantLabel.text = model.assistantPreview
      statsLabel.text = model.statsText
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onTap = nil
      userLabel.text = nil
      assistantLabel.text = nil
      statsLabel.text = nil
    }
  }

#endif
