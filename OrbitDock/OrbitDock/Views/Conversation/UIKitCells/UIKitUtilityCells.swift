//
//  UIKitUtilityCells.swift
//  OrbitDock
//
//  Native UICollectionViewCell subclasses for structural timeline rows on iOS.
//  Utility cells render shared presentation models so their semantics stay in
//  sync with the AppKit conversation timeline.
//

#if os(iOS)

  import SwiftUI
  import UIKit

  // MARK: - Turn Header Cell (36pt)

  final class UIKitTurnHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitTurnHeaderCell"

    private let leftHairline = UIView()
    private let rightHairline = UIView()
    private let turnLabel = UILabel()
    private let toolsLabel = UILabel()

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
      let hairlineColor = UIColor(Color.textQuaternary).withAlphaComponent(0.15)

      leftHairline.backgroundColor = hairlineColor
      leftHairline.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(leftHairline)

      rightHairline.backgroundColor = hairlineColor
      rightHairline.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(rightHairline)

      turnLabel.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
      turnLabel.textColor = UIColor(Color.textQuaternary)
      turnLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(turnLabel)

      toolsLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
      toolsLabel.textColor = UIColor(Color.textQuaternary)
      toolsLabel.textAlignment = .right
      toolsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      toolsLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(toolsLabel)

      NSLayoutConstraint.activate([
        leftHairline.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        leftHairline.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        leftHairline.trailingAnchor.constraint(equalTo: turnLabel.leadingAnchor, constant: -Spacing.sm),
        leftHairline.heightAnchor.constraint(equalToConstant: 0.5),

        turnLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        turnLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

        rightHairline.leadingAnchor.constraint(equalTo: turnLabel.trailingAnchor, constant: Spacing.sm),
        rightHairline.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        rightHairline.trailingAnchor.constraint(equalTo: toolsLabel.leadingAnchor, constant: -Spacing.sm),
        rightHairline.heightAnchor.constraint(equalToConstant: 0.5),

        toolsLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        toolsLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      ])
    }

    func configure(model: ConversationUtilityRowModels.TurnHeaderModel) {
      let isHidden = model.isHidden
      leftHairline.isHidden = isHidden
      rightHairline.isHidden = isHidden
      turnLabel.isHidden = isHidden
      toolsLabel.isHidden = isHidden || model.toolsText == nil

      guard let labelText = model.labelText else { return }

      turnLabel.attributedText = NSAttributedString(
        string: labelText,
        attributes: [
          .font: UIFont.systemFont(ofSize: TypeScale.micro, weight: .semibold),
          .foregroundColor: UIColor(Color.textQuaternary),
          .kern: 1.5,
        ]
      )
      toolsLabel.text = model.toolsText
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      leftHairline.isHidden = false
      rightHairline.isHidden = false
      turnLabel.isHidden = false
      toolsLabel.isHidden = false
      turnLabel.attributedText = nil
      toolsLabel.text = nil
    }
  }

  // MARK: - Rollup Summary Cell (36pt)

  final class UIKitRollupSummaryCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitRollupSummaryCell"

    private let cardBg = CellCardBackground()
    private let capsuleBackground = UIView()
    private let iconImage = UIImageView()
    private let summaryLabel = UILabel()
    private let durationLabel = UILabel()
    private let chevronImage = UIImageView()
    var onToggle: (() -> Void)?

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

      capsuleBackground.layer.cornerRadius = ConversationLayout.capsuleCornerRadius
      capsuleBackground.layer.masksToBounds = true
      capsuleBackground.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(capsuleBackground)

      iconImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
      iconImage.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(iconImage)

      summaryLabel.font = UIFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
      summaryLabel.textColor = UIColor(Color.textSecondary)
      summaryLabel.lineBreakMode = .byTruncatingTail
      summaryLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(summaryLabel)

      durationLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
      durationLabel.textColor = UIColor(Color.textTertiary)
      durationLabel.textAlignment = .right
      durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      durationLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(durationLabel)

      chevronImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .medium)
      chevronImage.tintColor = UIColor(Color.textQuaternary)
      chevronImage.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(chevronImage)

      NSLayoutConstraint.activate([
        capsuleBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        capsuleBackground.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        capsuleBackground.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
        capsuleBackground.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),

        iconImage.leadingAnchor.constraint(equalTo: capsuleBackground.leadingAnchor, constant: Spacing.sm),
        iconImage.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        iconImage.widthAnchor.constraint(equalToConstant: 14),

        summaryLabel.leadingAnchor.constraint(equalTo: iconImage.trailingAnchor, constant: Spacing.sm_),
        summaryLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

        durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: Spacing.sm),
        durationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

        chevronImage.leadingAnchor.constraint(equalTo: durationLabel.trailingAnchor, constant: Spacing.sm_),
        chevronImage.trailingAnchor.constraint(equalTo: capsuleBackground.trailingAnchor, constant: -Spacing.sm),
        chevronImage.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        chevronImage.widthAnchor.constraint(equalToConstant: 10),
      ])

      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
      contentView.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
      onToggle?()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      cardBg.layoutInBounds(contentView.bounds)
    }

    func configureCardPosition(_ position: CardPosition, topInset: CGFloat, bottomInset: CGFloat) {
      cardBg.configure(position: position, topInset: topInset, bottomInset: bottomInset)
    }

    func configure(model: ConversationUtilityRowModels.RollupSummaryModel) {
      let accentColor = UIColor(ConversationUtilityRowModels.color(for: model.colorKey))
      iconImage.image = UIImage(systemName: model.symbolName)
      iconImage.tintColor = accentColor
      summaryLabel.text = model.summaryText
      summaryLabel.textColor = model.isExpanded ? UIColor(Color.textTertiary) : UIColor(Color.textSecondary)
      durationLabel.text = model.durationText
      durationLabel.isHidden = model.durationText == nil
      chevronImage.image = UIImage(systemName: model.chevronName)
      capsuleBackground.backgroundColor = accentColor.withAlphaComponent(model.isExpanded ? 0.06 : 0.08)
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      cardBg.reset()
      onToggle = nil
      summaryLabel.text = nil
      durationLabel.text = nil
      durationLabel.isHidden = false
      chevronImage.image = nil
      iconImage.image = nil
    }
  }

  // MARK: - Load More Cell (38pt)

  final class UIKitLoadMoreCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitLoadMoreCell"

    private let button = UIButton(type: .system)
    var onLoadMore: (() -> Void)?

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

      button.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.meta, weight: .medium)
      button.setTitleColor(UIColor(Color.accent), for: .normal)
      button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
      button.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(button)

      NSLayoutConstraint.activate([
        button.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        button.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      ])
    }

    @objc private func handleTap() {
      onLoadMore?()
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onLoadMore = nil
    }

    func configure(remainingCount: Int) {
      button.setTitle("Load \(remainingCount) earlier messages", for: .normal)
    }
  }

  // MARK: - Message Count Cell (24pt)

  final class UIKitMessageCountCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitMessageCountCell"

    private let label = UILabel()

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

      label.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      label.textColor = UIColor(Color.textTertiary)
      label.textAlignment = .center
      label.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(label)

      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      ])
    }

    func configure(displayedCount: Int, totalCount: Int) {
      label.text = "Showing \(displayedCount) of \(totalCount) messages"
    }
  }

  // MARK: - Spacer Cell (32pt)

  final class UIKitSpacerCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitSpacerCell"

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      backgroundColor = .clear
      contentView.backgroundColor = .clear
    }
  }

  // MARK: - Live Indicator Cell (40pt)

  final class UIKitLiveIndicatorCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitLiveIndicatorCell"
    static let cellHeight: CGFloat = ConversationLayout.liveIndicatorHeight

    private let orbitalHost = UIView()
    private var orbitalLayer: OrbitalAnimationLayer?
    private let iconView = UIImageView()
    private let primaryLabel = UILabel()
    private let detailLabel = UILabel()
    private var primaryLeadingConstraint: NSLayoutConstraint?

    private static let hInset = ConversationLayout.laneHorizontalInset

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      contentView.backgroundColor = .clear
      setupSubviews()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setupSubviews()
    }

    private func setupSubviews() {
      orbitalHost.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(orbitalHost)

      iconView.contentMode = .center
      iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      iconView.isHidden = true
      iconView.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(iconView)

      primaryLabel.font = .systemFont(ofSize: TypeScale.body, weight: .medium)
      primaryLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(primaryLabel)

      detailLabel.font = .monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      detailLabel.textColor = UIColor(Color.textTertiary)
      detailLabel.lineBreakMode = .byTruncatingTail
      detailLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(detailLabel)

      let orbitalSize: CGFloat = 20

      NSLayoutConstraint.activate([
        orbitalHost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.hInset),
        orbitalHost.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        orbitalHost.widthAnchor.constraint(equalToConstant: orbitalSize),
        orbitalHost.heightAnchor.constraint(equalToConstant: orbitalSize),

        iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.hInset),
        iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        iconView.widthAnchor.constraint(equalToConstant: 16),

        primaryLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

        detailLabel.leadingAnchor.constraint(equalTo: primaryLabel.trailingAnchor, constant: Spacing.xs),
        detailLabel.centerYAnchor.constraint(equalTo: primaryLabel.centerYAnchor),
        detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Self.hInset),
      ])
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      orbitalLayer?.frame = orbitalHost.bounds
    }

    func configure(model: ConversationUtilityRowModels.LiveIndicatorModel) {
      iconView.isHidden = true
      orbitalHost.isHidden = true
      detailLabel.isHidden = true
      primaryLabel.text = nil
      detailLabel.text = nil

      let hasOrbital: Bool
      switch model.barStyle {
        case let .orbiting(colorKey, secondary):
          orbitalHost.isHidden = false
          ensureOrbitalLayer()
          let color = UIColor(ConversationUtilityRowModels.color(for: colorKey)).cgColor
          let secondaryColor = secondary.map { UIColor(ConversationUtilityRowModels.color(for: $0)).cgColor }
          orbitalLayer?.configure(state: .orbiting, color: color, secondaryColor: secondaryColor)
          hasOrbital = true

        case let .holding(colorKey):
          orbitalHost.isHidden = false
          ensureOrbitalLayer()
          let color = UIColor(ConversationUtilityRowModels.color(for: colorKey)).cgColor
          orbitalLayer?.configure(state: .holding, color: color)
          hasOrbital = true

        case let .parked(colorKey):
          orbitalHost.isHidden = false
          ensureOrbitalLayer()
          let color = UIColor(ConversationUtilityRowModels.color(for: colorKey)).cgColor
          orbitalLayer?.configure(state: .parked, color: color)
          hasOrbital = true

        case .none:
          orbitalLayer?.configure(state: .hidden, color: CGColor(gray: 0, alpha: 0))
          hasOrbital = false
      }

      if let iconName = model.iconName {
        iconView.isHidden = false
        iconView.image = UIImage(systemName: iconName)
        if let colorKey = model.iconColorKey {
          iconView.tintColor = UIColor(ConversationUtilityRowModels.color(for: colorKey))
        }
      }

      primaryLabel.text = model.primaryText
      primaryLabel.textColor = UIColor(ConversationUtilityRowModels.color(for: model.primaryColorKey))
        .withAlphaComponent(0.8)
      updateLabelLeadingConstraint(hasIcon: model.iconName != nil, hasOrbital: hasOrbital)

      if let detailText = model.detailText, !detailText.isEmpty {
        detailLabel.isHidden = false
        detailLabel.text = detailText
        detailLabel.textColor = UIColor(ConversationUtilityRowModels.color(for: model.detailColorKey))
        switch model.detailStyle {
          case .none:
            detailLabel.font = .systemFont(ofSize: TypeScale.body, weight: .regular)
          case .regular:
            detailLabel.font = .systemFont(ofSize: TypeScale.body, weight: .regular)
          case .monospaced:
            detailLabel.font = .monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
          case .emphasis:
            detailLabel.font = .systemFont(ofSize: TypeScale.body, weight: .bold)
        }
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      orbitalLayer?.removeAllOrbitalAnimations()
      orbitalLayer?.removeFromSuperlayer()
      orbitalLayer = nil
      iconView.image = nil
      primaryLabel.text = nil
      detailLabel.text = nil
    }

    private func updateLabelLeadingConstraint(hasIcon: Bool, hasOrbital: Bool) {
      primaryLeadingConstraint?.isActive = false
      if hasIcon {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: iconView.trailingAnchor,
          constant: Spacing.xs
        )
      } else if hasOrbital {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: orbitalHost.trailingAnchor,
          constant: Spacing.xs
        )
      } else {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: contentView.leadingAnchor,
          constant: Self.hInset
        )
      }
      primaryLeadingConstraint?.isActive = true
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
