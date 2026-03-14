#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitConversationUtilityCardView: UIView {
    final class InsetLabel: UILabel {
      var contentInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

      override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
      }

      override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(
          width: base.width + contentInsets.left + contentInsets.right,
          height: base.height + contentInsets.top + contentInsets.bottom
        )
      }
    }

    let cardView = UIView()
    let accentBar = UIView()
    let iconWell = UIView()
    let iconView = UIImageView()
    let eyebrowLabel = UILabel()
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    let spotlightLabel = UILabel()
    let badgeLabel = InsetLabel()
    let footerStack = UIStackView()

    private let textStack = UIStackView()
    private let topRow = UIStackView()
    private let contentStack = UIStackView()
    private let titleRow = UIStackView()

    override init(frame: CGRect) {
      super.init(frame: frame)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    private func setup() {
      translatesAutoresizingMaskIntoConstraints = false
      backgroundColor = .clear

      cardView.translatesAutoresizingMaskIntoConstraints = false
      cardView.backgroundColor = UIColor(Color.backgroundSecondary).withAlphaComponent(0.92)
      cardView.layer.cornerRadius = CGFloat(Radius.lg)
      cardView.layer.borderWidth = 1
      addSubview(cardView)

      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.layer.cornerRadius = EdgeBar.width / 2
      cardView.addSubview(accentBar)

      iconWell.translatesAutoresizingMaskIntoConstraints = false
      iconWell.layer.cornerRadius = 13
      cardView.addSubview(iconWell)

      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.contentMode = .scaleAspectFit
      cardView.addSubview(iconView)

      eyebrowLabel.font = .systemFont(ofSize: TypeScale.mini, weight: .semibold)
      eyebrowLabel.textColor = UIColor(Color.textTertiary)
      eyebrowLabel.numberOfLines = 1

      titleLabel.font = .systemFont(ofSize: TypeScale.body, weight: .semibold)
      titleLabel.textColor = UIColor(Color.textPrimary)
      titleLabel.numberOfLines = 2

      subtitleLabel.font = .systemFont(ofSize: TypeScale.meta, weight: .medium)
      subtitleLabel.textColor = UIColor(Color.textSecondary)
      subtitleLabel.numberOfLines = 2

      spotlightLabel.font = .systemFont(ofSize: TypeScale.mini, weight: .medium)
      spotlightLabel.textColor = UIColor(Color.textQuaternary)
      spotlightLabel.numberOfLines = 2

      badgeLabel.font = .monospacedSystemFont(ofSize: TypeScale.mini, weight: .semibold)
      badgeLabel.textAlignment = .center
      badgeLabel.layer.cornerRadius = 9
      badgeLabel.layer.masksToBounds = true
      badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

      titleRow.axis = .horizontal
      titleRow.alignment = .top
      titleRow.spacing = CGFloat(Spacing.sm)
      titleRow.addArrangedSubview(titleLabel)
      titleRow.addArrangedSubview(badgeLabel)

      textStack.axis = .vertical
      textStack.alignment = .fill
      textStack.spacing = 4
      textStack.addArrangedSubview(eyebrowLabel)
      textStack.addArrangedSubview(titleRow)
      textStack.addArrangedSubview(subtitleLabel)
      textStack.addArrangedSubview(spotlightLabel)

      topRow.axis = .horizontal
      topRow.alignment = .top
      topRow.spacing = CGFloat(Spacing.md)
      topRow.translatesAutoresizingMaskIntoConstraints = false
      topRow.addArrangedSubview(iconWell)
      topRow.addArrangedSubview(textStack)
      cardView.addSubview(topRow)

      footerStack.axis = .horizontal
      footerStack.alignment = .fill
      footerStack.spacing = CGFloat(Spacing.xs)
      footerStack.translatesAutoresizingMaskIntoConstraints = false
      footerStack.isHidden = true

      contentStack.axis = .vertical
      contentStack.alignment = .fill
      contentStack.spacing = CGFloat(Spacing.sm)
      contentStack.translatesAutoresizingMaskIntoConstraints = false
      contentStack.addArrangedSubview(topRow)
      contentStack.addArrangedSubview(footerStack)
      cardView.addSubview(contentStack)

      NSLayoutConstraint.activate([
        cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ConversationLayout.laneHorizontalInset),
        cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ConversationLayout.laneHorizontalInset),
        cardView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

        accentBar.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: CGFloat(Spacing.sm)),
        accentBar.topAnchor.constraint(equalTo: cardView.topAnchor, constant: CGFloat(Spacing.sm)),
        accentBar.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -CGFloat(Spacing.sm)),
        accentBar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        iconWell.widthAnchor.constraint(equalToConstant: 26),
        iconWell.heightAnchor.constraint(equalToConstant: 26),
        iconView.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
        iconView.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
        iconView.widthAnchor.constraint(equalToConstant: 14),
        iconView.heightAnchor.constraint(equalToConstant: 14),

        contentStack.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: CGFloat(Spacing.md)),
        contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -CGFloat(Spacing.md)),
        contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: CGFloat(Spacing.sm)),
        contentStack.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -CGFloat(Spacing.sm)),
      ])
    }

    func configureChrome(
      accentColor: UIColor,
      iconName: String,
      eyebrow: String?,
      title: String,
      subtitle: String?,
      spotlight: String?,
      badge: String?,
      emphasizesBorder: Bool = false
    ) {
      accentBar.backgroundColor = accentColor
      iconWell.backgroundColor = accentColor.withAlphaComponent(0.12)
      iconView.image = UIImage(systemName: iconName)
      iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
      iconView.tintColor = accentColor
      eyebrowLabel.text = eyebrow
      eyebrowLabel.isHidden = (eyebrow ?? "").isEmpty
      titleLabel.text = title
      subtitleLabel.text = subtitle
      subtitleLabel.isHidden = (subtitle ?? "").isEmpty
      spotlightLabel.text = spotlight
      spotlightLabel.isHidden = (spotlight ?? "").isEmpty
      badgeLabel.text = badge
      badgeLabel.isHidden = (badge ?? "").isEmpty
      badgeLabel.textColor = accentColor.withAlphaComponent(0.95)
      badgeLabel.backgroundColor = accentColor.withAlphaComponent(0.12)
      cardView.layer.borderColor = accentColor.withAlphaComponent(emphasizesBorder ? 0.26 : 0.12).cgColor
    }

    func clearFooter() {
      footerStack.arrangedSubviews.forEach {
        footerStack.removeArrangedSubview($0)
        $0.removeFromSuperview()
      }
      footerStack.isHidden = true
    }
  }

#endif
