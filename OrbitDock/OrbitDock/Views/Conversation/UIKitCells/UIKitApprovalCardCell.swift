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
    static let stripHeight: CGFloat = 40

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
      accentBar.layer.cornerRadius = 1.5
      stripContainer.addSubview(accentBar)

      // Icon
      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.contentMode = .scaleAspectFit
      stripContainer.addSubview(iconView)

      // Title
      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = UIFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
      titleLabel.textColor = UIColor(Color.textPrimary)
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
      stripContainer.addSubview(titleLabel)

      // Dot separator
      dotLabel.translatesAutoresizingMaskIntoConstraints = false
      dotLabel.font = UIFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      dotLabel.textColor = UIColor(Color.textQuaternary)
      dotLabel.text = "\u{00B7}"
      dotLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      stripContainer.addSubview(dotLabel)

      // Subtitle
      subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
      subtitleLabel.font = UIFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      subtitleLabel.textColor = UIColor(Color.textTertiary)
      subtitleLabel.lineBreakMode = .byTruncatingTail
      subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      stripContainer.addSubview(subtitleLabel)

      // Chevron
      chevronView.translatesAutoresizingMaskIntoConstraints = false
      chevronView.image = UIImage(systemName: "chevron.right")
      chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: TypeScale.mini, weight: .bold
      )
      chevronView.tintColor = UIColor(Color.textQuaternary)
      chevronView.alpha = 0.4
      stripContainer.addSubview(chevronView)

      let inset = ConversationLayout.laneHorizontalInset
      let hPad = CGFloat(Spacing.sm)
      NSLayoutConstraint.activate([
        stripContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
        stripContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        stripContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        stripContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

        accentBar.topAnchor.constraint(equalTo: stripContainer.topAnchor, constant: 7),
        accentBar.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor, constant: 7),
        accentBar.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor, constant: -7),
        accentBar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        iconView.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        iconView.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: hPad),
        iconView.widthAnchor.constraint(equalToConstant: 14),
        iconView.heightAnchor.constraint(equalToConstant: 14),

        titleLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),

        dotLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        dotLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 5),

        subtitleLabel.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        subtitleLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: 5),
        subtitleLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: chevronView.leadingAnchor, constant: -hPad
        ),

        chevronView.centerYAnchor.constraint(equalTo: stripContainer.centerYAnchor),
        chevronView.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor, constant: -hPad),
        chevronView.widthAnchor.constraint(equalToConstant: 8),
        chevronView.heightAnchor.constraint(equalToConstant: 10),
      ])
    }

    func configure(model: ApprovalCardModel) {
      currentModel = model

      let header = ApprovalCardConfiguration.headerConfig(for: model, mode: model.mode)
      let tint = UIColor(model.risk.tintColor)

      // Background + accent
      stripContainer.backgroundColor = UIColor(Color.backgroundSecondary).withAlphaComponent(0.5)
      accentBar.backgroundColor = tint.withAlphaComponent(0.72)

      // Icon
      iconView.image = UIImage(systemName: header.iconName)
      iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: TypeScale.micro, weight: .semibold
      )
      iconView.tintColor = tint

      // Title
      titleLabel.text = switch model.mode {
        case .permission: model.toolName ?? "Tool"
        case .question: "Question"
        case .takeover: model.toolName ?? "Takeover"
        case .none: ""
      }

      // Subtitle
      subtitleLabel.text = switch model.mode {
        case .permission:
          ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model).count > 1
            ? "\(ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model).count)-step chain awaiting approval"
            : "Awaiting approval"
        case .question:
          model.questions.count > 1
            ? "\(model.questions.count) questions waiting"
            : "Awaiting your response"
        case .takeover: "Manual takeover required"
        case .none: ""
      }
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
      stripHeight + 8 // 4pt top + 4pt bottom inset
    }
  }

#endif
