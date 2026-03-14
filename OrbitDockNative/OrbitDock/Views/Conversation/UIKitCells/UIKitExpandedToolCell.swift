//
//  UIKitExpandedToolCell.swift
//  OrbitDock
//
//  Native UICollectionViewCell for expanded tool cards on iOS.
//  Content rendering is delegated to ToolContentRenderer.
//

#if os(iOS)

  import SwiftUI
  import UIKit

  private typealias EL = ExpandedToolLayout

  final class UIKitExpandedToolCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitExpandedToolCell"

    private let groupCardBg = CellCardBackground()

    // ── Subviews ──

    private let cardBackground = UIView()
    private let accentBar = UIView()
    private let headerDivider = UIView()
    private let contentBg = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statsLabel = UILabel()
    private let durationLabel = UILabel()
    private let collapseChevron = UIImageView()
    private let cancelButton = UIButton(type: .system)
    private let workerButton = UIButton(type: .system)
    private let contentContainer = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    // ── State ──

    private var model: NativeExpandedToolModel?
    var onCollapse: ((String) -> Void)?
    var onCancel: ((String) -> Void)?
    var onFocusWorker: ((String) -> Void)?

    // ── Init ──

    override init(frame: CGRect) {
      super.init(frame: frame)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    // ── Setup ──

    private func setup() {
      backgroundColor = .clear
      contentView.backgroundColor = .clear

      groupCardBg.install(in: contentView)

      cardBackground.backgroundColor = EL.bgColor
      cardBackground.layer.cornerRadius = EL.cornerRadius
      cardBackground.layer.masksToBounds = true
      cardBackground.layer.borderWidth = 1
      contentView.addSubview(cardBackground)

      cardBackground.addSubview(accentBar)

      headerDivider.backgroundColor = EL.headerDividerColor
      cardBackground.addSubview(headerDivider)

      contentBg.backgroundColor = EL.contentBgColor
      cardBackground.addSubview(contentBg)

      iconView.contentMode = .scaleAspectFit
      cardBackground.addSubview(iconView)

      titleLabel.font = EL.headerFont
      titleLabel.textColor = EL.textPrimary
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.numberOfLines = 1
      cardBackground.addSubview(titleLabel)

      subtitleLabel.font = EL.subtitleFont
      subtitleLabel.textColor = EL.textTertiary
      subtitleLabel.lineBreakMode = .byTruncatingTail
      subtitleLabel.numberOfLines = 1
      cardBackground.addSubview(subtitleLabel)

      statsLabel.font = EL.statsFont
      statsLabel.textColor = EL.textTertiary
      statsLabel.textAlignment = .right
      cardBackground.addSubview(statsLabel)

      durationLabel.font = EL.statsFont
      durationLabel.textColor = EL.textQuaternary
      durationLabel.textAlignment = .right
      cardBackground.addSubview(durationLabel)

      let chevronConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
      collapseChevron.image = UIImage(systemName: "chevron.down")?.withConfiguration(chevronConfig)
      collapseChevron.tintColor = EL.textQuaternary
      cardBackground.addSubview(collapseChevron)

      spinner.color = EL.textTertiary
      spinner.hidesWhenStopped = true
      spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
      cardBackground.addSubview(spinner)

      cancelButton.setTitle("Stop", for: .normal)
      cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.meta, weight: .semibold)
      cancelButton.setTitleColor(UIColor(Color.statusError), for: .normal)
      cancelButton.isHidden = true
      cancelButton.addTarget(self, action: #selector(handleCancelTap), for: .touchUpInside)
      cardBackground.addSubview(cancelButton)

      let workerConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      workerButton.setImage(UIImage(systemName: "sidebar.right", withConfiguration: workerConfig), for: .normal)
      workerButton.tintColor = UIColor(Color.accent)
      workerButton.isHidden = true
      workerButton.addTarget(self, action: #selector(handleWorkerTap), for: .touchUpInside)
      cardBackground.addSubview(workerButton)

      contentContainer.clipsToBounds = true
      cardBackground.addSubview(contentContainer)

      let tap = UITapGestureRecognizer(target: self, action: #selector(handleHeaderTap(_:)))
      cardBackground.addGestureRecognizer(tap)
    }

    @objc private func handleHeaderTap(_ gesture: UITapGestureRecognizer) {
      let location = gesture.location(in: cardBackground)
      if !cancelButton.isHidden, cancelButton.frame.contains(location) { return }
      if !workerButton.isHidden, workerButton.frame.contains(location) { return }
      let headerHeight = EL.headerHeight(for: model)
      if location.y <= headerHeight, let messageID = model?.messageID {
        onCollapse?(messageID)
      }
    }

    @objc private func handleCancelTap() {
      guard let messageID = model?.messageID else { return }
      onCancel?(messageID)
    }

    @objc private func handleWorkerTap() {
      guard let workerID = model?.linkedWorkerID else { return }
      onFocusWorker?(workerID)
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      groupCardBg.layoutInBounds(contentView.bounds)
    }

    func configureCardPosition(_ position: CardPosition, topInset: CGFloat, bottomInset: CGFloat) {
      groupCardBg.configure(position: position, topInset: topInset, bottomInset: bottomInset)
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      groupCardBg.reset()
      onCollapse = nil
      onCancel = nil
      onFocusWorker = nil
      model = nil
      contentContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    // ── Configure ──

    func configure(model: NativeExpandedToolModel, width: CGFloat) {
      self.model = model

      let inset = EL.laneHorizontalInset
      let cardWidth = width - inset * 2
      let headerH = EL.headerHeight(for: model, cardWidth: cardWidth)
      let contentH = EL.contentHeight(for: model, cardWidth: cardWidth)
      let totalH = EL.requiredHeight(for: width, model: model)

      cardBackground.frame = CGRect(x: inset, y: 0, width: cardWidth, height: totalH)
      cardBackground.layer.borderColor = model.toolColor.withAlphaComponent(OpacityTier.light).cgColor

      let accentColor: UIColor = model.hasError ? UIColor(Color.statusError) : model.toolColor
      accentBar.backgroundColor = accentColor
      accentBar.frame = CGRect(x: 0, y: 0, width: EL.accentBarWidth, height: totalH)

      let dividerX = EL.accentBarWidth
      let dividerW = cardWidth - EL.accentBarWidth
      headerDivider.frame = CGRect(x: dividerX, y: headerH, width: dividerW, height: 1)
      headerDivider.isHidden = contentH == 0

      if contentH > 0 {
        contentBg.isHidden = false
        contentBg.frame = CGRect(x: dividerX, y: headerH + 1, width: dividerW, height: contentH)
      } else {
        contentBg.isHidden = true
      }

      let iconConfig = UIImage.SymbolConfiguration(pointSize: EL.iconSize, weight: .medium)
      iconView.image = UIImage(systemName: model.iconName)?.withConfiguration(iconConfig)
      iconView.tintColor = model.hasError ? UIColor(Color.statusError) : model.toolColor
      iconView.frame = CGRect(
        x: EL.accentBarWidth + EL.headerHPad,
        y: EL.headerVPad,
        width: 20, height: 20
      )

      configureHeader(model: model, cardWidth: cardWidth, headerH: headerH)

      if model.isInProgress {
        spinner.startAnimating()
        let spinnerX = model.canCancel
          ? cardWidth - EL.headerHPad - 72
          : cardWidth - EL.headerHPad - 16
        spinner.frame = CGRect(x: spinnerX, y: EL.headerVPad + 2, width: 16, height: 16)
      } else {
        spinner.stopAnimating()
      }

      if model.canCancel {
        cancelButton.isHidden = false
        cancelButton.frame = CGRect(
          x: cardWidth - EL.headerHPad - 52, y: EL.headerVPad,
          width: 52, height: 20
        )
      } else {
        cancelButton.isHidden = true
      }

      if model.linkedWorkerID != nil {
        workerButton.isHidden = false
        workerButton.frame = CGRect(
          x: cardWidth - EL.headerHPad - (model.canCancel ? 84 : 46),
          y: EL.headerVPad - 1,
          width: 20, height: 20
        )
      } else {
        workerButton.isHidden = true
      }

      if !model.isInProgress, !model.canCancel {
        collapseChevron.isHidden = false
        collapseChevron.frame = CGRect(
          x: cardWidth - EL.headerHPad - 12, y: EL.headerVPad + 3,
          width: 12, height: 12
        )
      } else {
        collapseChevron.isHidden = true
      }

      if let dur = model.duration, !model.isInProgress, !model.canCancel {
        durationLabel.isHidden = false
        durationLabel.text = dur
        durationLabel.sizeToFit()
        let durW = durationLabel.frame.width
        let durX = cardWidth - EL.headerHPad - 12 - 8 - durW
        durationLabel.frame = CGRect(x: durX, y: EL.headerVPad + 2, width: durW, height: 16)
      } else {
        durationLabel.isHidden = true
      }

      contentContainer.subviews.forEach { $0.removeFromSuperview() }
      contentContainer.frame = CGRect(x: 0, y: headerH, width: cardWidth, height: contentH)
      ToolContentRenderer.buildContent(in: contentContainer, model: model, width: cardWidth)
    }

    // ── Header Configuration ──

    private func configureHeader(model: NativeExpandedToolModel, cardWidth: CGFloat, headerH: CGFloat) {
      let leftEdge = EL.accentBarWidth + EL.headerHPad + 20 + 8
      let rightEdge = cardWidth - EL.headerHPad - 12 - 8 - 60
      let plan = ExpandedToolHeaderPlanning.plan(for: model)
      applyHeaderPlan(plan, model: model)

      let hasSubtitle = !subtitleLabel.isHidden
      let titleWidth = max(60, rightEdge - leftEdge)
      if hasSubtitle {
        titleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad, width: titleWidth, height: 18)
        subtitleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad + 18, width: titleWidth, height: 16)
      } else {
        if case .bash = model.content {
          let titleH = headerH - EL.headerVPad * 2
          titleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad, width: titleWidth, height: max(18, titleH))
        } else {
          titleLabel.frame = CGRect(x: leftEdge, y: EL.headerVPad + 4, width: titleWidth, height: 18)
        }
      }

      if !statsLabel.isHidden {
        statsLabel.sizeToFit()
        let statsW = statsLabel.frame.width
        let statsX = cardWidth - EL
          .headerHPad - 12 - 8 - (durationLabel.isHidden ? 0 : durationLabel.frame.width + 8) - statsW
        statsLabel.frame = CGRect(x: statsX, y: EL.headerVPad + 2, width: statsW, height: 16)
      }
    }

    private func applyHeaderPlan(_ plan: ExpandedToolHeaderPlan, model: NativeExpandedToolModel) {
      switch plan.title {
        case let .bash(command):
          let bashColor: UIColor = model.hasError ? UIColor(Color.statusError) : model.toolColor
          let bashAttr = NSMutableAttributedString()
          bashAttr.append(NSAttributedString(
            string: "$ ",
            attributes: [
              .font: UIFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .bold),
              .foregroundColor: bashColor,
            ]
          ))
          bashAttr.append(NSAttributedString(
            string: command,
            attributes: [
              .font: UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
              .foregroundColor: EL.textPrimary,
            ]
          ))
          titleLabel.attributedText = bashAttr
          titleLabel.lineBreakMode = .byCharWrapping
          titleLabel.numberOfLines = 0

        case let .plain(text, style):
          titleLabel.attributedText = nil
          titleLabel.text = text
          titleLabel.font = titleFont(for: style)
          titleLabel.textColor = titleColor(for: style, model: model)
          titleLabel.lineBreakMode = .byTruncatingTail
          titleLabel.numberOfLines = 1
      }

      subtitleLabel.text = plan.subtitle
      subtitleLabel.isHidden = plan.subtitle == nil

      if let statsText = plan.statsText {
        statsLabel.isHidden = false
        statsLabel.text = statsText
        statsLabel.textColor = statsColor(for: plan.statsTone)
      } else {
        statsLabel.isHidden = true
      }
    }

    private func titleFont(for style: ExpandedToolHeaderTitleStyle) -> UIFont {
      switch style {
        case .primary, .toolTint: EL.headerFont
        case .fileName: UIFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .semibold)
      }
    }

    private func titleColor(for style: ExpandedToolHeaderTitleStyle, model: NativeExpandedToolModel) -> UIColor {
      switch style {
        case .primary, .fileName: EL.textPrimary
        case .toolTint: model.toolColor
      }
    }

    private func statsColor(for tone: ExpandedToolHeaderStatsTone) -> UIColor {
      switch tone {
        case .secondary: EL.textTertiary
        case let .diff(additions, _): additions > 0 ? EL.addedAccentColor : EL.removedAccentColor
      }
    }
  }

#endif
