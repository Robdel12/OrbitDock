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

  private enum UIKitActivitySummaryLayout {
    static func requiredHeight(
      for model: ConversationUtilityRowModels.ActivitySummaryModel?,
      availableWidth: CGFloat
    ) -> CGFloat {
      let cardWidth = max(0, availableWidth - ConversationLayout.laneHorizontalInset * 2)
      let contentWidth = max(0, cardWidth - CGFloat(Spacing.sm) - EdgeBar.width - CGFloat(Spacing.md) - 26 - CGFloat(Spacing.md) - CGFloat(Spacing.md))
      let textWidth = max(120, contentWidth - 56)
      let verticalPadding = CGFloat(Spacing.sm) * 2 + 4

      let eyebrowHeight = UIFont.systemFont(ofSize: TypeScale.mini, weight: .semibold).lineHeight
      let titleHeight = (model?.titleText ?? "Tool activity").boundingHeight(
        width: textWidth,
        font: .systemFont(ofSize: TypeScale.body, weight: .semibold),
        maxLines: 2
      )
      let subtitleHeight = (model?.subtitleText ?? "Grouped activity in this turn").boundingHeight(
        width: textWidth,
        font: .systemFont(ofSize: TypeScale.meta, weight: .medium),
        maxLines: 2
      )

      return max(92, verticalPadding + eyebrowHeight + titleHeight + subtitleHeight + 12)
    }
  }

  private extension String {
    func boundingHeight(width: CGFloat, font: UIFont, maxLines: Int) -> CGFloat {
      let rect = (self as NSString).boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
      )
      let lineHeight = font.lineHeight
      return min(ceil(rect.height), lineHeight * CGFloat(maxLines))
    }
  }

  final class UIKitWorkerOrchestrationCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitWorkerOrchestrationCell"

    private let card = UIKitConversationUtilityCardView()
    private let chipsStack = UIStackView()
    private var chipWorkerIDs: [String] = []
    var onSelectWorker: ((String) -> Void)?

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

      chipsStack.axis = .horizontal
      chipsStack.spacing = Spacing.xs
      chipsStack.alignment = .fill
      chipsStack.translatesAutoresizingMaskIntoConstraints = false
      card.footerStack.addArrangedSubview(chipsStack)

      NSLayoutConstraint.activate([
        card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        card.topAnchor.constraint(equalTo: contentView.topAnchor),
        card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      ])
    }

    func configure(model: ConversationUtilityRowModels.WorkerOrchestrationModel) {
      chipWorkerIDs = model.workers.map(\.id)
      let activeCount = model.workers.reduce(into: 0) { count, worker in
        if worker.isActive { count += 1 }
      }
      let accentColorKey = model.workers.first(where: \.isActive)?.statusColorKey ?? model.workers.first?.statusColorKey ?? .accent
      let accent = UIColor(ConversationUtilityRowModels.color(for: accentColorKey))
      let badge: String? = if activeCount > 0 {
        activeCount == 1 ? "1 active" : "\(activeCount) active"
      } else if !model.workers.isEmpty {
        "Finished"
      } else {
        nil
      }
      card.configureChrome(
        accentColor: accent,
        iconName: "person.2.fill",
        eyebrow: "Workers",
        title: model.titleText,
        subtitle: model.subtitleText,
        spotlight: model.spotlightText,
        badge: badge
      )
      card.footerStack.isHidden = model.workers.isEmpty
      chipsStack.arrangedSubviews.forEach {
        chipsStack.removeArrangedSubview($0)
        $0.removeFromSuperview()
      }

      for (index, worker) in model.workers.enumerated() {
        let button = UIButton(type: .system)
        button.tag = index
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        config.image = UIImage(systemName: worker.isActive ? "dot.radiowaves.left.and.right" : "circle.fill")
        config.imagePadding = 6
        config.title = worker.title
        config.baseForegroundColor = UIColor(Color.textPrimary)
        config.background.backgroundColor = UIColor(
          ConversationUtilityRowModels.color(for: worker.statusColorKey)
        ).withAlphaComponent(worker.isActive ? 0.16 : 0.08)
        button.configuration = config
        button.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
        button.tintColor = UIColor(ConversationUtilityRowModels.color(for: worker.statusColorKey))
        button.layer.cornerRadius = ConversationLayout.capsuleCornerRadius
        button.accessibilityLabel = "\(worker.title), \(worker.statusText)"
        button.addTarget(self, action: #selector(handleChipTap(_:)), for: .touchUpInside)
        chipsStack.addArrangedSubview(button)
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      chipWorkerIDs = []
      onSelectWorker = nil
      card.footerStack.isHidden = true
      chipsStack.arrangedSubviews.forEach {
        chipsStack.removeArrangedSubview($0)
        $0.removeFromSuperview()
      }
    }

    func configureCardPosition(_ position: CardPosition, topInset: CGFloat, bottomInset: CGFloat) {
    }

    @objc private func handleChipTap(_ sender: UIButton) {
      guard sender.tag >= 0, sender.tag < chipWorkerIDs.count else { return }
      onSelectWorker?(chipWorkerIDs[sender.tag])
    }
  }

  final class UIKitActivitySummaryCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitActivitySummaryCell"

    private let card = UIKitConversationUtilityCardView()
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

      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
      contentView.addGestureRecognizer(tap)
    }

    func configure(model: ConversationUtilityRowModels.ActivitySummaryModel) {
      let accent = UIColor(ConversationUtilityRowModels.color(for: model.accentColorKey))
      card.clearFooter()
      card.configureChrome(
        accentColor: accent,
        iconName: model.iconName,
        eyebrow: "Activity",
        title: model.titleText,
        subtitle: model.subtitleText,
        spotlight: model.isExpanded
          ? "Showing \(model.childCount) tool step\(model.childCount == 1 ? "" : "s")"
          : "Tap to inspect \(model.childCount) tool step\(model.childCount == 1 ? "" : "s")",
        badge: model.badgeText
      )
      card.titleLabel.numberOfLines = 2
      card.subtitleLabel.numberOfLines = 2
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      card.clearFooter()
      onTap = nil
    }

    func configureCardPosition(_ position: CardPosition, topInset: CGFloat, bottomInset: CGFloat) {
    }

    static func requiredHeight(
      for model: ConversationUtilityRowModels.ActivitySummaryModel?,
      availableWidth: CGFloat
    ) -> CGFloat {
      UIKitActivitySummaryLayout.requiredHeight(for: model, availableWidth: availableWidth)
    }

    @objc private func handleTap() {
      onTap?()
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
    private let card = UIKitConversationUtilityCardView()

    private let orbitalHost = UIView()
    private var orbitalLayer: OrbitalAnimationLayer?

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
      card.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(card)

      orbitalHost.translatesAutoresizingMaskIntoConstraints = false
      orbitalHost.isHidden = true
      card.iconWell.addSubview(orbitalHost)

      NSLayoutConstraint.activate([
        card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        card.topAnchor.constraint(equalTo: contentView.topAnchor),
        card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

        orbitalHost.leadingAnchor.constraint(equalTo: card.iconWell.leadingAnchor),
        orbitalHost.trailingAnchor.constraint(equalTo: card.iconWell.trailingAnchor),
        orbitalHost.topAnchor.constraint(equalTo: card.iconWell.topAnchor),
        orbitalHost.bottomAnchor.constraint(equalTo: card.iconWell.bottomAnchor),
      ])
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      orbitalLayer?.frame = orbitalHost.bounds
    }

    func configure(model: ConversationUtilityRowModels.LiveIndicatorModel) {
      card.clearFooter()
      card.iconView.isHidden = true
      orbitalHost.isHidden = true

      let accentColor: UIColor = {
        switch model.primaryColorKey {
          case .permission: return UIColor(Color.statusPermission)
          case .reply: return UIColor(Color.statusReply)
          case .working: return UIColor(Color.statusWorking)
          default: return UIColor(Color.accent)
        }
      }()
      let badge: String? = {
        switch model.barStyle {
          case .orbiting: return "Active"
          case .holding: return "Needs input"
          case .parked: return "Ready"
          case .none: return nil
        }
      }()
      let eyebrow: String? = {
        switch model.barStyle {
          case .orbiting: return "Live"
          case .holding: return "Blocked"
          case .parked: return "Session"
          case .none: return "Session"
        }
      }()
      card.configureChrome(
        accentColor: accentColor,
        iconName: model.iconName ?? "circle.fill",
        eyebrow: eyebrow,
        title: model.primaryText,
        subtitle: model.detailText,
        spotlight: nil,
        badge: badge
      )
      switch model.detailStyle {
        case .none, .regular:
          card.subtitleLabel.font = .systemFont(ofSize: TypeScale.meta, weight: .medium)
        case .monospaced:
          card.subtitleLabel.font = .monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
        case .emphasis:
          card.subtitleLabel.font = .systemFont(ofSize: TypeScale.meta, weight: .semibold)
      }

      let hasOrbital: Bool
      switch model.barStyle {
        case let .orbiting(colorKey, secondary):
          orbitalHost.isHidden = false
          card.iconView.isHidden = true
          ensureOrbitalLayer()
          let color = UIColor(ConversationUtilityRowModels.color(for: colorKey)).cgColor
          let secondaryColor = secondary.map { UIColor(ConversationUtilityRowModels.color(for: $0)).cgColor }
          orbitalLayer?.configure(state: .orbiting, color: color, secondaryColor: secondaryColor)
          hasOrbital = true

        case let .holding(colorKey):
          orbitalHost.isHidden = false
          card.iconView.isHidden = true
          ensureOrbitalLayer()
          let color = UIColor(ConversationUtilityRowModels.color(for: colorKey)).cgColor
          orbitalLayer?.configure(state: .holding, color: color)
          hasOrbital = true

        case let .parked(colorKey):
          orbitalHost.isHidden = false
          card.iconView.isHidden = true
          ensureOrbitalLayer()
          let color = UIColor(ConversationUtilityRowModels.color(for: colorKey)).cgColor
          orbitalLayer?.configure(state: .parked, color: color)
          hasOrbital = true

        case .none:
          orbitalLayer?.configure(state: .hidden, color: CGColor(gray: 0, alpha: 0))
          hasOrbital = false
      }

      if let iconName = model.iconName {
        card.iconView.isHidden = false
        card.iconView.image = UIImage(systemName: iconName)
        if let colorKey = model.iconColorKey {
          card.iconView.tintColor = UIColor(ConversationUtilityRowModels.color(for: colorKey))
        }
      }
      if !hasOrbital {
        orbitalLayer?.configure(state: .hidden, color: CGColor(gray: 0, alpha: 0))
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      orbitalLayer?.removeAllOrbitalAnimations()
      orbitalLayer?.removeFromSuperlayer()
      orbitalLayer = nil
      card.clearFooter()
      card.iconView.image = nil
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
