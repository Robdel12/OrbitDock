//
//  UIKitApprovalCardCell.swift
//  OrbitDock
//
//  iOS UICollectionViewCell for inline approval cards in the conversation timeline.
//  Three modes: permission (tool approval), question (options or text input), takeover (passive session).
//  Uses UIMenu for secondary actions to provide 44pt+ touch targets.
//

#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitApprovalCardCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitApprovalCardCell"

    // MARK: - Callbacks

    var onDecision: ((String, String?, Bool?) -> Void)?
    var onAnswer: (([String: [String]]) -> Void)?
    var onTakeOver: (() -> Void)?

    // MARK: - Subviews

    private let cardContainer = UIView()
    private let riskStrip = UIView()

    // Merged header — tool icon + "ToolName · Approval Required" + risk badge
    private let headerIcon = UIImageView()
    private let headerLabel = UILabel()
    private let riskBadgeContainer = UIView()
    private let riskBadgeLabel = UILabel()

    // Command preview — structured segments
    private let segmentStack = UIStackView()
    private let riskFindingsStack = UIStackView()

    // Question mode
    private let questionTextLabel = UILabel()
    private let questionOptionsStack = UIStackView()
    private let answerField = UITextField()
    private let submitButton = UIButton(type: .system)

    // Takeover mode
    private let takeoverDescription = UILabel()
    private let takeoverButton = UIButton(type: .system)

    // Permission buttons — split containers with menu chevrons
    private let buttonRow = UIView()
    private let denyButton = UIButton(type: .system)
    private let denyChevronButton = UIButton(type: .system)
    private let approveButton = UIButton(type: .system)
    private let approveChevronButton = UIButton(type: .system)

    private var currentModel: ApprovalCardModel?
    private var questionOptionsTopConstraint: NSLayoutConstraint?
    private var selectedQuestionAnswers: [String: [String]] = [:]
    private var questionTextFields: [String: UITextField] = [:]
    private var questionOptionButtons: [String: [UIButton]] = [:]

    private typealias Layout = ApprovalCardHeightCalculator.Layout

    private enum LocalLayout {
      static let chevronWidth: CGFloat = 36
    }

    // MARK: - Init

    override init(frame: CGRect) {
      super.init(frame: frame)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
    }

    // MARK: - Setup

    private func setup() {
      backgroundColor = .clear
      contentView.backgroundColor = .clear

      cardContainer.layer.cornerRadius = CGFloat(Radius.lg)
      cardContainer.layer.masksToBounds = true
      cardContainer.layer.borderWidth = 1
      cardContainer.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(cardContainer)

      riskStrip.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(riskStrip)

      setupHeader()
      setupCommandPreview()
      setupQuestionMode()
      setupTakeoverMode()
      setupPermissionButtons()

      let inset = ConversationLayout.laneHorizontalInset
      NSLayoutConstraint.activate([
        cardContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.outerVerticalInset),
        cardContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        cardContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        cardContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.outerVerticalInset),

        riskStrip.topAnchor.constraint(equalTo: cardContainer.topAnchor),
        riskStrip.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
        riskStrip.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
        riskStrip.heightAnchor.constraint(equalToConstant: 2),
      ])
    }

    // MARK: - Merged Header

    private func setupHeader() {
      headerIcon.translatesAutoresizingMaskIntoConstraints = false
      headerIcon.contentMode = .scaleAspectFit
      headerIcon.tintColor = UIColor(Color.statusPermission)
      cardContainer.addSubview(headerIcon)

      headerLabel.translatesAutoresizingMaskIntoConstraints = false
      headerLabel.font = UIFont.systemFont(ofSize: TypeScale.subhead, weight: .semibold)
      headerLabel.textColor = UIColor(Color.textPrimary)
      headerLabel.lineBreakMode = .byTruncatingTail
      cardContainer.addSubview(headerLabel)

      riskBadgeContainer.layer.cornerRadius = 7
      riskBadgeContainer.backgroundColor = UIColor(Color.statusError)
      riskBadgeContainer.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(riskBadgeContainer)

      riskBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
      riskBadgeLabel.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .black)
      riskBadgeLabel.textColor = .white
      riskBadgeLabel.text = "HIGH RISK"
      riskBadgeContainer.addSubview(riskBadgeLabel)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        headerIcon.topAnchor.constraint(equalTo: riskStrip.bottomAnchor, constant: pad),
        headerIcon.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        headerIcon.widthAnchor.constraint(equalToConstant: Layout.headerIconSize),
        headerIcon.heightAnchor.constraint(equalToConstant: Layout.headerIconSize),

        headerLabel.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: CGFloat(Spacing.sm)),

        riskBadgeContainer.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        riskBadgeContainer.leadingAnchor.constraint(equalTo: headerLabel.trailingAnchor, constant: CGFloat(Spacing.sm)),
        riskBadgeContainer.trailingAnchor.constraint(lessThanOrEqualTo: cardContainer.trailingAnchor, constant: -pad),

        riskBadgeLabel.topAnchor.constraint(equalTo: riskBadgeContainer.topAnchor, constant: 2),
        riskBadgeLabel.bottomAnchor.constraint(equalTo: riskBadgeContainer.bottomAnchor, constant: -2),
        riskBadgeLabel.leadingAnchor.constraint(
          equalTo: riskBadgeContainer.leadingAnchor,
          constant: CGFloat(Spacing.sm)
        ),
        riskBadgeLabel.trailingAnchor.constraint(
          equalTo: riskBadgeContainer.trailingAnchor,
          constant: -CGFloat(Spacing.sm)
        ),
      ])
    }

    // MARK: - Command Preview

    private func setupCommandPreview() {
      segmentStack.translatesAutoresizingMaskIntoConstraints = false
      segmentStack.axis = .vertical
      segmentStack.spacing = CGFloat(Spacing.xs)
      segmentStack.alignment = .fill
      cardContainer.addSubview(segmentStack)

      riskFindingsStack.translatesAutoresizingMaskIntoConstraints = false
      riskFindingsStack.axis = .vertical
      riskFindingsStack.spacing = CGFloat(Spacing.xs)
      riskFindingsStack.alignment = .fill
      riskFindingsStack.isHidden = true
      cardContainer.addSubview(riskFindingsStack)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        segmentStack.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: CGFloat(Spacing.sm)),
        segmentStack.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        segmentStack.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        riskFindingsStack.topAnchor.constraint(
          equalTo: segmentStack.bottomAnchor,
          constant: CGFloat(Spacing.sm)
        ),
        riskFindingsStack.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        riskFindingsStack.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
      ])
    }

    private func setupQuestionMode() {
      questionTextLabel.translatesAutoresizingMaskIntoConstraints = false
      questionTextLabel.font = UIFont.systemFont(ofSize: TypeScale.reading)
      questionTextLabel.textColor = UIColor(Color.textPrimary)
      questionTextLabel.numberOfLines = 0
      cardContainer.addSubview(questionTextLabel)

      questionOptionsStack.translatesAutoresizingMaskIntoConstraints = false
      questionOptionsStack.axis = .vertical
      questionOptionsStack.spacing = CGFloat(Spacing.xs)
      questionOptionsStack.alignment = .fill
      questionOptionsStack.distribution = .fill
      questionOptionsStack.isHidden = true
      cardContainer.addSubview(questionOptionsStack)

      answerField.translatesAutoresizingMaskIntoConstraints = false
      answerField.placeholder = "Your answer..."
      answerField.font = UIFont.systemFont(ofSize: TypeScale.body)
      answerField.textColor = UIColor(Color.textPrimary)
      answerField.backgroundColor = UIColor(Color.backgroundPrimary)
      answerField.borderStyle = .roundedRect
      answerField.returnKeyType = .send
      answerField.addTarget(self, action: #selector(answerFieldReturnPressed), for: .editingDidEndOnExit)
      cardContainer.addSubview(answerField)

      submitButton.translatesAutoresizingMaskIntoConstraints = false
      submitButton.setTitle("Submit", for: .normal)
      submitButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      submitButton.setTitleColor(.white, for: .normal)
      submitButton.backgroundColor = UIColor(Color.statusQuestion).withAlphaComponent(0.75)
      submitButton.layer.cornerRadius = CGFloat(Radius.lg)
      submitButton.addTarget(self, action: #selector(submitButtonTapped), for: .touchUpInside)
      cardContainer.addSubview(submitButton)

      let pad = Layout.cardPadding
      let questionOptionsTop = questionOptionsStack.topAnchor
        .constraint(equalTo: questionTextLabel.bottomAnchor, constant: 0)
      questionOptionsTopConstraint = questionOptionsTop
      NSLayoutConstraint.activate([
        questionTextLabel.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: CGFloat(Spacing.md)),
        questionTextLabel.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        questionTextLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        questionOptionsTop,
        questionOptionsStack.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        questionOptionsStack.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        answerField.topAnchor.constraint(equalTo: questionOptionsStack.bottomAnchor, constant: CGFloat(Spacing.md)),
        answerField.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        answerField.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        answerField.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),

        submitButton.topAnchor.constraint(equalTo: answerField.bottomAnchor, constant: CGFloat(Spacing.md)),
        submitButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        submitButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        submitButton.heightAnchor.constraint(equalToConstant: 42),
      ])
    }

    private func setupTakeoverMode() {
      takeoverDescription.translatesAutoresizingMaskIntoConstraints = false
      takeoverDescription.font = UIFont.systemFont(ofSize: TypeScale.body)
      takeoverDescription.textColor = UIColor(Color.textTertiary)
      takeoverDescription.numberOfLines = 0
      cardContainer.addSubview(takeoverDescription)

      takeoverButton.translatesAutoresizingMaskIntoConstraints = false
      takeoverButton.setTitle("Take Over & Review", for: .normal)
      takeoverButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      takeoverButton.setTitleColor(.white, for: .normal)
      takeoverButton.layer.cornerRadius = CGFloat(Radius.lg)
      takeoverButton.addTarget(self, action: #selector(takeoverButtonTapped), for: .touchUpInside)
      cardContainer.addSubview(takeoverButton)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        takeoverDescription.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverDescription.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverDescription.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        takeoverButton.topAnchor.constraint(equalTo: takeoverDescription.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        takeoverButton.heightAnchor.constraint(equalToConstant: 42),
      ])
    }

    // MARK: - Split-Button Permission Buttons

    private func setupPermissionButtons() {
      buttonRow.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(buttonRow)

      // — Deny side: button + chevron —
      denyButton.translatesAutoresizingMaskIntoConstraints = false
      denyButton.setTitle("Deny", for: .normal)
      denyButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      denyButton.setTitleColor(UIColor(Color.statusError), for: .normal)
      denyButton.layer.cornerRadius = CGFloat(Radius.md)
      denyButton.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
      denyButton.addTarget(self, action: #selector(denyButtonTapped), for: .touchUpInside)
      buttonRow.addSubview(denyButton)

      denyChevronButton.translatesAutoresizingMaskIntoConstraints = false
      denyChevronButton.setImage(
        UIImage(
          systemName: "chevron.down",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        ),
        for: .normal
      )
      denyChevronButton.tintColor = UIColor(Color.statusError).withAlphaComponent(0.8)
      denyChevronButton.layer.cornerRadius = CGFloat(Radius.md)
      denyChevronButton.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
      denyChevronButton.showsMenuAsPrimaryAction = true
      buttonRow.addSubview(denyChevronButton)

      // — Approve side: button + chevron —
      approveButton.translatesAutoresizingMaskIntoConstraints = false
      approveButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .bold)
      approveButton.setTitleColor(.white, for: .normal)
      approveButton.layer.cornerRadius = CGFloat(Radius.md)
      approveButton.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
      approveButton.addTarget(self, action: #selector(approveButtonTapped), for: .touchUpInside)
      buttonRow.addSubview(approveButton)

      approveChevronButton.translatesAutoresizingMaskIntoConstraints = false
      approveChevronButton.setImage(
        UIImage(
          systemName: "chevron.down",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        ),
        for: .normal
      )
      approveChevronButton.tintColor = UIColor.white.withAlphaComponent(0.8)
      approveChevronButton.layer.cornerRadius = CGFloat(Radius.md)
      approveChevronButton.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
      approveChevronButton.showsMenuAsPrimaryAction = true
      buttonRow.addSubview(approveChevronButton)

      let pad = Layout.cardPadding
      // Deny group = denyButton + denyChevron, Approve group = approveButton + approveChevron
      // Deny group: 40% width, Approve group: 60% width
      let denyGroup = UILayoutGuide()
      let approveGroup = UILayoutGuide()
      buttonRow.addLayoutGuide(denyGroup)
      buttonRow.addLayoutGuide(approveGroup)

      NSLayoutConstraint.activate([
        buttonRow.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        buttonRow.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        buttonRow.heightAnchor.constraint(equalToConstant: Layout.primaryButtonHeight),

        // Deny group guide
        denyGroup.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor),
        denyGroup.topAnchor.constraint(equalTo: buttonRow.topAnchor),
        denyGroup.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),

        // Approve group guide
        approveGroup.leadingAnchor.constraint(equalTo: denyGroup.trailingAnchor, constant: CGFloat(Spacing.sm)),
        approveGroup.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
        approveGroup.topAnchor.constraint(equalTo: buttonRow.topAnchor),
        approveGroup.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),

        // Ratio: deny 2/5, approve 3/5
        denyGroup.widthAnchor.constraint(equalTo: approveGroup.widthAnchor, multiplier: 2.0 / 3.0),

        // Deny button + chevron within deny group
        denyButton.leadingAnchor.constraint(equalTo: denyGroup.leadingAnchor),
        denyButton.topAnchor.constraint(equalTo: denyGroup.topAnchor),
        denyButton.bottomAnchor.constraint(equalTo: denyGroup.bottomAnchor),
        denyButton.trailingAnchor.constraint(equalTo: denyChevronButton.leadingAnchor),

        denyChevronButton.trailingAnchor.constraint(equalTo: denyGroup.trailingAnchor),
        denyChevronButton.topAnchor.constraint(equalTo: denyGroup.topAnchor),
        denyChevronButton.bottomAnchor.constraint(equalTo: denyGroup.bottomAnchor),
        denyChevronButton.widthAnchor.constraint(equalToConstant: LocalLayout.chevronWidth),

        // Approve button + chevron within approve group
        approveButton.leadingAnchor.constraint(equalTo: approveGroup.leadingAnchor),
        approveButton.topAnchor.constraint(equalTo: approveGroup.topAnchor),
        approveButton.bottomAnchor.constraint(equalTo: approveGroup.bottomAnchor),
        approveButton.trailingAnchor.constraint(equalTo: approveChevronButton.leadingAnchor),

        approveChevronButton.trailingAnchor.constraint(equalTo: approveGroup.trailingAnchor),
        approveChevronButton.topAnchor.constraint(equalTo: approveGroup.topAnchor),
        approveChevronButton.bottomAnchor.constraint(equalTo: approveGroup.bottomAnchor),
        approveChevronButton.widthAnchor.constraint(equalToConstant: LocalLayout.chevronWidth),
      ])
    }

    // MARK: - Configure

    func configure(model: ApprovalCardModel) {
      currentModel = model
      clearQuestionFormState()

      let tint = UIColor(model.risk.tintColor)
      riskStrip.backgroundColor = tint
      cardContainer.backgroundColor = tint.withAlphaComponent(CGFloat(model.risk.tintOpacity))
      cardContainer.layer.borderColor = tint.withAlphaComponent(CGFloat(OpacityTier.medium)).cgColor

      switch model.mode {
        case .permission:
          configurePermission(model)
        case .question:
          configureQuestion(model)
        case .takeover:
          configureTakeover(model)
        case .none:
          break
      }
    }

    private func configurePermission(_ model: ApprovalCardModel) {
      let hasContent = ApprovalPermissionPreviewHelpers.hasPreviewContent(model)

      // Show
      segmentStack.isHidden = !hasContent
      buttonRow.isHidden = false
      riskBadgeContainer.isHidden = model.risk != .high

      // Hide
      questionTextLabel.isHidden = true
      questionOptionsTopConstraint?.constant = 0
      questionOptionsStack.isHidden = true
      configureQuestionOptions([])
      clearQuestionFormState()
      answerField.isHidden = true
      submitButton.isHidden = true
      takeoverDescription.isHidden = true
      takeoverButton.isHidden = true

      // Merged header — tool icon + "ToolName · Status"
      let headerConfig = ApprovalCardConfiguration.headerConfig(for: model, mode: .permission)
      headerIcon.image = UIImage(systemName: headerConfig.iconName)
      headerIcon.tintColor = UIColor(headerConfig.iconTint)
      headerLabel.text = headerConfig.label
      approveButton.setTitle(headerConfig.approveTitle, for: .normal)
      denyButton.setTitle(headerConfig.denyTitle, for: .normal)

      // Structured preview content
      configurePreviewContent(model)
      configureRiskFindings(model)

      // Style split buttons
      let errorColor = UIColor(Color.statusError)
      denyButton.backgroundColor = errorColor.withAlphaComponent(CGFloat(OpacityTier.light))
      denyChevronButton.backgroundColor = errorColor.withAlphaComponent(CGFloat(OpacityTier.light))

      let accentColor = UIColor(Color.accent)
      approveButton.backgroundColor = accentColor
      approveChevronButton.backgroundColor = accentColor

      // Configure menus on chevron buttons
      denyChevronButton.menu = UIMenu(children: denyMenuActions(model))
      approveChevronButton.menu = UIMenu(children: approveMenuActions(model))

      // Position button row
      updateButtonRowPosition(model)
    }

    // MARK: - Structured Preview Content

    private func configurePreviewContent(_ model: ApprovalCardModel) {
      for view in segmentStack.arrangedSubviews {
        segmentStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }

      let accentColor = UIColor(model.risk.tintColor)

      switch model.previewType {
        case .shellCommand:
          if !model.shellSegments.isEmpty {
            for (index, segment) in model.shellSegments.enumerated() {
              let view = makeSegmentView(
                command: segment.command,
                operator: segment.leadingOperator,
                isFirst: index == 0,
                accentColor: accentColor
              )
              segmentStack.addArrangedSubview(view)
            }
          } else if let command = ApprovalPermissionPreviewHelpers.trimmed(model.command) {
            let view = makeSegmentView(
              command: command, operator: nil, isFirst: true, accentColor: accentColor
            )
            segmentStack.addArrangedSubview(view)
          } else if let manifest = ApprovalPermissionPreviewHelpers.trimmed(model.serverManifest) {
            let view = makeSegmentView(
              command: manifest, operator: nil, isFirst: true, accentColor: accentColor
            )
            segmentStack.addArrangedSubview(view)
          }

        default:
          if let value = ApprovalPermissionPreviewHelpers.previewValue(for: model) {
            let view = makeNonShellPreview(
              type: model.previewType,
              value: value,
              accentColor: accentColor
            )
            segmentStack.addArrangedSubview(view)
          } else if let manifest = ApprovalPermissionPreviewHelpers.trimmed(model.serverManifest) {
            let view = makeSegmentView(
              command: manifest, operator: nil, isFirst: true, accentColor: accentColor
            )
            segmentStack.addArrangedSubview(view)
          }
      }

      segmentStack.isHidden = segmentStack.arrangedSubviews.isEmpty
    }

    private func makeSegmentView(
      command: String,
      operator leadingOp: String?,
      isFirst: Bool,
      accentColor: UIColor
    ) -> UIView {
      let container = UIView()
      container.layer.cornerRadius = CGFloat(Radius.md)
      container.clipsToBounds = true
      container.backgroundColor = UIColor(Color.backgroundPrimary)
      container.translatesAutoresizingMaskIntoConstraints = false

      let bar = UIView()
      bar.backgroundColor = accentColor
      bar.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(bar)

      var topAnchorView: UIView = container
      var topConstant = Layout.commandVerticalPadding

      if let op = leadingOp,
         let label = ApprovalPermissionPreviewHelpers.operatorLabel(op)
      {
        let pill = UIView()
        pill.layer.cornerRadius = 3
        pill.backgroundColor = UIColor(Color.backgroundTertiary)
        pill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pill)

        let opLabel = UILabel()
        opLabel.translatesAutoresizingMaskIntoConstraints = false
        opLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .semibold)
        opLabel.textColor = UIColor(Color.textTertiary)
        opLabel.text = op
        pill.addSubview(opLabel)

        let descLabel = UILabel()
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = UIFont.systemFont(ofSize: TypeScale.micro)
        descLabel.textColor = UIColor(Color.textQuaternary)
        descLabel.text = label
        container.addSubview(descLabel)

        NSLayoutConstraint.activate([
          pill.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.commandVerticalPadding),
          pill.leadingAnchor.constraint(
            equalTo: bar.trailingAnchor,
            constant: Layout.commandHorizontalPadding
          ),
          pill.heightAnchor.constraint(equalToConstant: 16),

          opLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
          opLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -5),
          opLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

          descLabel.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: CGFloat(Spacing.xs)),
          descLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])

        topAnchorView = pill
        topConstant = CGFloat(Spacing.xs)
      }

      let textLabel = UILabel()
      textLabel.translatesAutoresizingMaskIntoConstraints = false
      textLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      textLabel.textColor = UIColor(Color.textPrimary)
      textLabel.numberOfLines = 0
      textLabel.lineBreakMode = .byCharWrapping

      if isFirst, leadingOp == nil {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
          string: "$ ",
          attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .semibold),
            .foregroundColor: accentColor,
          ]
        ))
        attributed.append(NSAttributedString(
          string: command,
          attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular),
            .foregroundColor: UIColor(Color.textPrimary),
          ]
        ))
        textLabel.attributedText = attributed
      } else {
        textLabel.text = command
      }

      container.addSubview(textLabel)

      let textTopAnchor = topAnchorView === container
        ? container.topAnchor
        : topAnchorView.bottomAnchor

      let bottomPin = textLabel.bottomAnchor.constraint(
        equalTo: container.bottomAnchor,
        constant: -Layout.commandVerticalPadding
      )
      bottomPin.priority = .defaultHigh

      let textMaxHeight = textLabel.heightAnchor.constraint(
        lessThanOrEqualToConstant: Layout.maxCommandTextHeight
      )

      NSLayoutConstraint.activate([
        bar.topAnchor.constraint(equalTo: container.topAnchor),
        bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        bar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        textLabel.topAnchor.constraint(equalTo: textTopAnchor, constant: topConstant),
        textLabel.leadingAnchor.constraint(
          equalTo: bar.trailingAnchor,
          constant: Layout.commandHorizontalPadding
        ),
        textLabel.trailingAnchor.constraint(
          equalTo: container.trailingAnchor,
          constant: -Layout.commandHorizontalPadding
        ),
        bottomPin,
        textMaxHeight,
      ])

      return container
    }

    private func makeNonShellPreview(
      type: ApprovalPreviewType,
      value: String,
      accentColor: UIColor
    ) -> UIView {
      let container = UIView()
      container.layer.cornerRadius = CGFloat(Radius.md)
      container.clipsToBounds = true
      container.backgroundColor = UIColor(Color.backgroundPrimary)
      container.translatesAutoresizingMaskIntoConstraints = false

      let bar = UIView()
      bar.backgroundColor = accentColor
      bar.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(bar)

      let typeLabel = UILabel()
      typeLabel.translatesAutoresizingMaskIntoConstraints = false
      typeLabel.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      typeLabel.textColor = UIColor(Color.textTertiary)
      typeLabel.text = type.title
      container.addSubview(typeLabel)

      let valueLabel = UILabel()
      valueLabel.translatesAutoresizingMaskIntoConstraints = false
      valueLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      valueLabel.textColor = UIColor(Color.textPrimary)
      valueLabel.numberOfLines = 0
      valueLabel.lineBreakMode = .byCharWrapping
      valueLabel.text = value
      container.addSubview(valueLabel)

      let bottomPin = valueLabel.bottomAnchor.constraint(
        equalTo: container.bottomAnchor,
        constant: -Layout.commandVerticalPadding
      )
      bottomPin.priority = .defaultHigh

      let valueMaxHeight = valueLabel.heightAnchor.constraint(
        lessThanOrEqualToConstant: Layout.maxCommandTextHeight
      )

      NSLayoutConstraint.activate([
        bar.topAnchor.constraint(equalTo: container.topAnchor),
        bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        bar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        typeLabel.topAnchor.constraint(
          equalTo: container.topAnchor,
          constant: Layout.commandVerticalPadding
        ),
        typeLabel.leadingAnchor.constraint(
          equalTo: bar.trailingAnchor,
          constant: Layout.commandHorizontalPadding
        ),

        valueLabel.topAnchor.constraint(
          equalTo: typeLabel.bottomAnchor,
          constant: CGFloat(Spacing.xxs)
        ),
        valueLabel.leadingAnchor.constraint(equalTo: typeLabel.leadingAnchor),
        valueLabel.trailingAnchor.constraint(
          equalTo: container.trailingAnchor,
          constant: -Layout.commandHorizontalPadding
        ),
        bottomPin,
        valueMaxHeight,
      ])

      return container
    }

    private func configureRiskFindings(_ model: ApprovalCardModel) {
      for view in riskFindingsStack.arrangedSubviews {
        riskFindingsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }

      guard !model.riskFindings.isEmpty else {
        riskFindingsStack.isHidden = true
        return
      }

      let tintColor = UIColor(model.risk.tintColor)

      for finding in model.riskFindings {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: "exclamationmark.triangle.fill")
        icon.tintColor = tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TypeScale.caption)
        row.addSubview(icon)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: TypeScale.caption)
        label.textColor = UIColor(Color.textSecondary)
        label.text = finding
        row.addSubview(label)

        NSLayoutConstraint.activate([
          icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
          icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
          icon.widthAnchor.constraint(equalToConstant: 12),
          icon.heightAnchor.constraint(equalToConstant: 12),

          label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: CGFloat(Spacing.xs)),
          label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
          label.topAnchor.constraint(equalTo: row.topAnchor),
          label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        riskFindingsStack.addArrangedSubview(row)
      }

      riskFindingsStack.isHidden = false
    }

    private func configureQuestion(_ model: ApprovalCardModel) {
      let tint = UIColor(Color.statusQuestion)
      riskStrip.backgroundColor = tint
      cardContainer.backgroundColor = tint.withAlphaComponent(CGFloat(OpacityTier.light))
      cardContainer.layer.borderColor = tint.withAlphaComponent(CGFloat(OpacityTier.medium)).cgColor

      let prompts = Self.questionPrompts(for: model)
      let isMultiPrompt = prompts.count > 1
      let primaryPrompt = prompts.first
      let hasOptions = !(primaryPrompt?.options ?? []).isEmpty && !isMultiPrompt

      // Show
      questionTextLabel.isHidden = false
      if isMultiPrompt {
        configureQuestionPromptForm(prompts)
        questionOptionsTopConstraint?.constant = CGFloat(Spacing.md)
        questionOptionsStack.isHidden = false
        answerField.isHidden = true
        submitButton.isHidden = false
        submitButton.setTitle("Submit Answers", for: .normal)
      } else {
        configureQuestionOptions(primaryPrompt?.options ?? [])
        questionOptionsTopConstraint?.constant = hasOptions ? CGFloat(Spacing.md) : 0
        questionOptionsStack.isHidden = !hasOptions
        answerField.isHidden = hasOptions
        submitButton.isHidden = hasOptions
        submitButton.setTitle("Submit", for: .normal)
      }

      // Hide
      segmentStack.isHidden = true
      riskFindingsStack.isHidden = true
      buttonRow.isHidden = true
      riskBadgeContainer.isHidden = true
      takeoverDescription.isHidden = true
      takeoverButton.isHidden = true

      let headerConfig = ApprovalCardConfiguration.headerConfig(for: model, mode: .question)
      headerIcon.image = UIImage(systemName: headerConfig.iconName)
      headerIcon.tintColor = tint
      headerLabel.text = headerConfig.label
      if isMultiPrompt {
        questionTextLabel.text = "Answer all questions to continue."
      } else {
        questionTextLabel.text = primaryPrompt?.question ?? ""
      }
      if !hasOptions, !isMultiPrompt {
        answerField.text = ""
      }
    }

    private func configureTakeover(_ model: ApprovalCardModel) {
      let isPermission = model.approvalType != .question
      let tint = isPermission ? UIColor(Color.statusPermission) : UIColor(Color.statusQuestion)

      riskStrip.backgroundColor = tint
      cardContainer.backgroundColor = tint.withAlphaComponent(CGFloat(OpacityTier.light))
      cardContainer.layer.borderColor = tint.withAlphaComponent(CGFloat(OpacityTier.medium)).cgColor

      // Show
      takeoverDescription.isHidden = false
      takeoverButton.isHidden = false

      // Hide
      segmentStack.isHidden = true
      riskFindingsStack.isHidden = true
      buttonRow.isHidden = true
      riskBadgeContainer.isHidden = true
      questionTextLabel.isHidden = true
      questionOptionsTopConstraint?.constant = 0
      questionOptionsStack.isHidden = true
      configureQuestionOptions([])
      clearQuestionFormState()
      answerField.isHidden = true
      submitButton.isHidden = true

      let headerConfig = ApprovalCardConfiguration.headerConfig(for: model, mode: .takeover)
      headerIcon.image = UIImage(systemName: headerConfig.iconName)
      headerIcon.tintColor = tint
      headerLabel.text = headerConfig.label
      takeoverDescription.text = "Take over this session to respond."
      takeoverButton.setTitle(ApprovalCardConfiguration.takeoverButtonTitle(for: model), for: .normal)
      takeoverButton.backgroundColor = tint.withAlphaComponent(0.75)
    }

    // MARK: - Menu Actions

    private func denyMenuActions(_ model: ApprovalCardModel) -> [UIAction] {
      ApprovalCardConfiguration.denyMenuActions(for: model).map { action in
        if action.decision == "deny_reason" {
          return UIAction(
            title: action.title,
            image: action.iconName.flatMap { UIImage(systemName: $0) }
          ) { [weak self] _ in
            guard let self, let vc = self.window?.rootViewController else { return }
            let alert = UIAlertController(title: "Deny Reason", message: nil, preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "Reason..." }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Deny", style: .destructive) { [weak self] _ in
              let reason = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              guard !reason.isEmpty else { return }
              self?.onDecision?("denied", reason, nil)
            })
            vc.present(alert, animated: true)
          }
        }
        return UIAction(
          title: action.title,
          image: action.iconName.flatMap { UIImage(systemName: $0) },
          attributes: action.isDestructive ? .destructive : []
        ) { [weak self] _ in
          self?.onDecision?(action.decision, nil, nil)
        }
      }
    }

    private func approveMenuActions(_ model: ApprovalCardModel) -> [UIAction] {
      ApprovalCardConfiguration.approveMenuActions(for: model).map { action in
        UIAction(
          title: action.title,
          image: action.iconName.flatMap { UIImage(systemName: $0) }
        ) { [weak self] _ in
          self?.onDecision?(action.decision, nil, nil)
        }
      }
    }

    private func updateButtonRowPosition(_ model: ApprovalCardModel) {
      for constraint in cardContainer.constraints where constraint.firstItem === buttonRow
        && constraint.firstAttribute == .top
      {
        constraint.isActive = false
      }

      let anchor: UIView = if !riskFindingsStack.isHidden {
        riskFindingsStack
      } else if !segmentStack.isHidden {
        segmentStack
      } else {
        headerIcon
      }

      let spacing: CGFloat = anchor === headerIcon ? CGFloat(Spacing.md) : CGFloat(Spacing.md)
      buttonRow.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: spacing).isActive = true
    }

    // MARK: - Actions

    @objc private func denyButtonTapped() {
      onDecision?("denied", nil, nil)
    }

    @objc private func approveButtonTapped() {
      onDecision?("approved", nil, nil)
    }

    @objc private func answerFieldReturnPressed() {
      let answer = (answerField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !answer.isEmpty else { return }
      let questionId = currentModel?.questions.first?.id ?? "0"
      onAnswer?([questionId: [answer]])
      answerField.text = ""
    }

    @objc private func submitButtonTapped() {
      if let model = currentModel, Self.questionPrompts(for: model).count > 1 {
        let answers = collectQuestionAnswers()
        guard !answers.isEmpty else { return }
        onAnswer?(answers)
        clearQuestionFormState()
        configureQuestionPromptForm(Self.questionPrompts(for: model))
        return
      }
      answerFieldReturnPressed()
    }

    @objc private func takeoverButtonTapped() {
      onTakeOver?()
    }

    // MARK: - Question Options

    private func configureQuestionOptions(_ options: [ApprovalQuestionOption]) {
      for view in questionOptionsStack.arrangedSubviews {
        questionOptionsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }

      guard !options.isEmpty else { return }

      let questionId = currentModel?.questions.first?.id ?? "0"
      for option in options {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.title = ApprovalCardHeightCalculator.questionOptionDisplayText(option)
        config.baseForegroundColor = UIColor(Color.textPrimary)
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        config.titleLineBreakMode = .byWordWrapping
        button.configuration = config
        button.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
        button.titleLabel?.numberOfLines = 0
        button.contentHorizontalAlignment = .leading
        button.backgroundColor = UIColor(Color.backgroundPrimary).withAlphaComponent(0.8)
        button.layer.cornerRadius = CGFloat(Radius.md)
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor(Color.statusQuestion).withAlphaComponent(0.35).cgColor
        button.accessibilityHint = option.description
        button.addAction(
          UIAction { [weak self] _ in
            self?.onAnswer?([questionId: [option.label]])
          },
          for: .touchUpInside
        )
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        questionOptionsStack.addArrangedSubview(button)
      }
    }

    private func clearQuestionFormState() {
      selectedQuestionAnswers = [:]
      questionTextFields = [:]
      questionOptionButtons = [:]
    }

    private func configureQuestionPromptForm(_ prompts: [ApprovalQuestionPrompt]) {
      for view in questionOptionsStack.arrangedSubviews {
        questionOptionsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      clearQuestionFormState()
      guard !prompts.isEmpty else { return }

      for (index, prompt) in prompts.enumerated() {
        let section = UIStackView()
        section.axis = .vertical
        section.spacing = 6
        section.alignment = .fill

        if let header = prompt.header, !header.isEmpty {
          let headerLabel = UILabel()
          headerLabel.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
          headerLabel.textColor = UIColor(Color.textSecondary)
          headerLabel.text = header.uppercased()
          section.addArrangedSubview(headerLabel)
        }

        let questionLabel = UILabel()
        questionLabel.font = UIFont.systemFont(ofSize: TypeScale.reading, weight: .medium)
        questionLabel.textColor = UIColor(Color.textPrimary)
        questionLabel.numberOfLines = 0
        questionLabel.text = prompt.question
        section.addArrangedSubview(questionLabel)

        if !prompt.options.isEmpty {
          let optionsStack = UIStackView()
          optionsStack.axis = .vertical
          optionsStack.spacing = CGFloat(Spacing.xs)
          optionsStack.alignment = .fill
          var buttons: [UIButton] = []

          for option in prompt.options {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            var config = UIButton.Configuration.plain()
            config.title = ApprovalCardHeightCalculator.questionOptionDisplayText(option)
            config.baseForegroundColor = UIColor(Color.textPrimary)
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
            config.titleLineBreakMode = .byWordWrapping
            button.configuration = config
            button.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
            button.titleLabel?.numberOfLines = 0
            button.contentHorizontalAlignment = .leading
            button.backgroundColor = UIColor(Color.backgroundPrimary).withAlphaComponent(0.8)
            button.layer.cornerRadius = CGFloat(Radius.md)
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor(Color.statusQuestion).withAlphaComponent(0.35).cgColor
            button.accessibilityHint = option.description
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(
              UIAction { [weak self, weak button] _ in
                guard let self, let button else { return }
                self.toggleOptionAnswer(
                  questionId: prompt.id,
                  optionLabel: option.label,
                  allowsMultipleSelection: prompt.allowsMultipleSelection,
                  selectedButton: button
                )
              },
              for: .touchUpInside
            )
            optionsStack.addArrangedSubview(button)
            buttons.append(button)
          }

          questionOptionButtons[prompt.id] = buttons
          section.addArrangedSubview(optionsStack)
        }

        if prompt.options.isEmpty || prompt.allowsOther {
          let field = UITextField()
          field.translatesAutoresizingMaskIntoConstraints = false
          field.placeholder = prompt.isSecret ? "Enter secure answer..." : "Your answer..."
          field.font = UIFont.systemFont(ofSize: TypeScale.body)
          field.textColor = UIColor(Color.textPrimary)
          field.backgroundColor = UIColor(Color.backgroundPrimary)
          field.borderStyle = .roundedRect
          field.returnKeyType = .done
          field.isSecureTextEntry = prompt.isSecret
          field.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
          field.addTarget(self, action: #selector(questionFieldChanged(_:)), for: .editingChanged)
          field.accessibilityIdentifier = prompt.id
          questionTextFields[prompt.id] = field
          section.addArrangedSubview(field)
        }

        questionOptionsStack.addArrangedSubview(section)
        if index < prompts.count - 1 {
          let spacer = UIView()
          spacer.translatesAutoresizingMaskIntoConstraints = false
          spacer.heightAnchor.constraint(equalToConstant: CGFloat(Spacing.sm)).isActive = true
          questionOptionsStack.addArrangedSubview(spacer)
        }
      }
    }

    @objc private func questionFieldChanged(_ sender: UITextField) {
      guard let questionId = sender.accessibilityIdentifier else { return }
      let text = (sender.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty {
        selectedQuestionAnswers.removeValue(forKey: questionId)
      } else {
        selectedQuestionAnswers[questionId] = [text]
      }
    }

    private func toggleOptionAnswer(
      questionId: String,
      optionLabel: String,
      allowsMultipleSelection: Bool,
      selectedButton: UIButton
    ) {
      var current = selectedQuestionAnswers[questionId] ?? []
      if allowsMultipleSelection {
        if let idx = current.firstIndex(of: optionLabel) {
          current.remove(at: idx)
        } else {
          current.append(optionLabel)
        }
      } else {
        current = [optionLabel]
      }

      if current.isEmpty {
        selectedQuestionAnswers.removeValue(forKey: questionId)
      } else {
        selectedQuestionAnswers[questionId] = current
      }

      guard let buttons = questionOptionButtons[questionId] else { return }
      for button in buttons {
        let title = button.title(for: .normal) ?? ""
        let label = title.components(separatedBy: "\n").first ?? title
        let isSelected = current.contains(label)
        button.layer.borderColor = isSelected
          ? UIColor(Color.statusQuestion).withAlphaComponent(0.9).cgColor
          : UIColor(Color.statusQuestion).withAlphaComponent(0.35).cgColor
      }
      if !allowsMultipleSelection {
        selectedButton.layer.borderColor = UIColor(Color.statusQuestion).withAlphaComponent(0.9).cgColor
      }
    }

    private func collectQuestionAnswers() -> [String: [String]] {
      guard let model = currentModel else { return [:] }
      let prompts = Self.questionPrompts(for: model)
      var answers: [String: [String]] = [:]

      for prompt in prompts {
        var values = selectedQuestionAnswers[prompt.id] ?? []
        if let field = questionTextFields[prompt.id] {
          let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty {
            if values.isEmpty {
              values = [text]
            } else if !values.contains(text) {
              values.append(text)
            }
          }
        }
        if !values.isEmpty {
          answers[prompt.id] = values
        }
      }
      return answers
    }

    // MARK: - Height

    static func requiredHeight(for model: ApprovalCardModel?, availableWidth: CGFloat) -> CGFloat {
      ApprovalCardHeightCalculator.requiredHeight(for: model, availableWidth: availableWidth)
    }

    private static func questionPrompts(for model: ApprovalCardModel) -> [ApprovalQuestionPrompt] {
      model.questions
    }

  }

#endif
