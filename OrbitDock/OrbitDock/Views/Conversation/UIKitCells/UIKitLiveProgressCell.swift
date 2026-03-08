//
//  UIKitLiveProgressCell.swift
//  OrbitDock
//
//  Live progress row for active work on iOS.
//

#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitLiveProgressCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitLiveProgressCell"

    private let cardBg = CellCardBackground()
    private let orbitalHost = UIView()
    private var orbitalLayer: OrbitalAnimationLayer?
    private let operationLabel = UILabel()
    private let statsLabel = UILabel()

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
      let orbitalSize: CGFloat = 20

      orbitalHost.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(orbitalHost)

      operationLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .medium)
      operationLabel.textColor = UIColor(Color.statusWorking).withAlphaComponent(0.8)
      operationLabel.lineBreakMode = .byTruncatingTail
      operationLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(operationLabel)

      statsLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
      statsLabel.textColor = UIColor(Color.textTertiary)
      statsLabel.textAlignment = .right
      statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      statsLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(statsLabel)

      NSLayoutConstraint.activate([
        orbitalHost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        orbitalHost.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        orbitalHost.widthAnchor.constraint(equalToConstant: orbitalSize),
        orbitalHost.heightAnchor.constraint(equalToConstant: orbitalSize),

        operationLabel.leadingAnchor.constraint(equalTo: orbitalHost.trailingAnchor, constant: Spacing.xs),
        operationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        operationLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsLabel.leadingAnchor, constant: -Spacing.sm),

        statsLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        statsLabel.centerYAnchor.constraint(equalTo: operationLabel.centerYAnchor),
      ])
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      cardBg.layoutInBounds(contentView.bounds)
      orbitalLayer?.frame = orbitalHost.bounds
    }

    func configureCardPosition(_ position: CardPosition, topInset: CGFloat, bottomInset: CGFloat) {
      cardBg.configure(position: position, topInset: topInset, bottomInset: bottomInset)
    }

    func configure(model: ConversationUtilityRowModels.LiveProgressModel) {
      operationLabel.text = model.operationText
      statsLabel.text = model.statsText
      ensureOrbitalLayer()
      let primary = UIColor(Color.statusWorking).cgColor
      let secondary = UIColor(Color.composerSteer).cgColor
      orbitalLayer?.configure(state: .orbiting, color: primary, secondaryColor: secondary)
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      cardBg.reset()
      orbitalLayer?.removeAllOrbitalAnimations()
      orbitalLayer?.removeFromSuperlayer()
      orbitalLayer = nil
      operationLabel.text = nil
      statsLabel.text = nil
    }

    private func ensureOrbitalLayer() {
      guard orbitalLayer == nil else { return }
      orbitalHost.layoutIfNeeded()
      let layer = OrbitalAnimationLayer()
      layer.frame = orbitalHost.bounds
      orbitalHost.layer.addSublayer(layer)
      orbitalLayer = layer
    }
  }

#endif
