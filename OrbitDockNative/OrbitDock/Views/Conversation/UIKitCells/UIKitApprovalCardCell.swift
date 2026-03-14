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
    static let cardHeight: CGFloat = 88

    private let card = UIKitConversationUtilityCardView()

    private var currentModel: ApprovalCardModel?
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
      card.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(card)

      NSLayoutConstraint.activate([
        card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        card.topAnchor.constraint(equalTo: contentView.topAnchor),
        card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      ])

      let tap = UITapGestureRecognizer(target: self, action: #selector(stripTapped))
      card.addGestureRecognizer(tap)
      card.isAccessibilityElement = true
      card.accessibilityTraits = [.button]
    }

    func configure(model: ApprovalCardModel) {
      currentModel = model
      let stripConfig = ApprovalCardConfiguration.stripConfig(for: model)
      let headerConfig = ApprovalCardConfiguration.headerConfig(for: model, mode: model.mode)
      let tint = UIColor(stripConfig.iconTint)
      let badge: String = switch model.mode {
        case .permission: model.approvalType == .permissions ? "Grant" : "Review"
        case .question: "Reply"
        case .takeover: "Take over"
        case .none: ""
      }
      let spotlight: String? = switch model.mode {
        case .permission: "Open the pending panel to keep the turn moving."
        case .question: "Open the pending panel to answer and resume the run."
        case .takeover: "Open the pending panel to step in manually."
        case .none: nil
      }
      card.configureChrome(
        accentColor: tint,
        iconName: stripConfig.iconName,
        eyebrow: headerConfig.label,
        title: stripConfig.title,
        subtitle: stripConfig.subtitle,
        spotlight: spotlight,
        badge: badge,
        emphasizesBorder: true
      )
      card.accessibilityLabel = "\(stripConfig.title). \(stripConfig.subtitle)."
    }

    @objc private func stripTapped() {
      guard currentModel != nil else { return }
      onTap?()
    }

    static func requiredHeight(for model: ApprovalCardModel?, availableWidth: CGFloat) -> CGFloat {
      cardHeight
    }
  }

#endif
