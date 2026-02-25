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

    // Header
    private let headerIcon = UIImageView()
    private let headerLabel = UILabel()

    // Tool badge
    private let toolBadge = UIView()
    private let toolIcon = UIImageView()
    private let toolNameLabel = UILabel()
    private let riskBadgeContainer = UIView()
    private let riskBadgeLabel = UILabel()

    // Command preview — structured segments
    private let segmentStack = UIStackView()
    private let riskFindingsStack = UIStackView()
    private let scopeRow = UIView()
    private let scopeLabel = UILabel()
    private let requestIdLabel = UILabel()

    // Question mode
    private let questionTextLabel = UILabel()
    private let questionOptionsStack = UIStackView()
    private let answerField = UITextField()
    private let submitButton = UIButton(type: .system)

    // Takeover mode
    private let takeoverDescription = UILabel()
    private let takeoverButton = UIButton(type: .system)

    // Permission buttons
    private let actionDivider = UIView()
    private let buttonStack = UIStackView()
    private let denyButton = UIButton(type: .system)
    private let approveButton = UIButton(type: .system)
    private let actionHintLabel = UILabel()
    private let moreActionsButton = UIButton(type: .system)

    private var currentModel: ApprovalCardModel?
    private var questionOptionsTopConstraint: NSLayoutConstraint?
    private var selectedQuestionAnswers: [String: [String]] = [:]
    private var questionTextFields: [String: UITextField] = [:]
    private var questionOptionButtons: [String: [UIButton]] = [:]

    private enum Layout {
      static let outerVerticalInset: CGFloat = 6
      static let cardPadding: CGFloat = 14
      static let headerIconSize: CGFloat = 15
      static let commandVerticalPadding: CGFloat = 6
      static let commandHorizontalPadding: CGFloat = 10
      static let minCommandTextHeight: CGFloat = 22
      static let maxCommandTextHeight: CGFloat = 220
      static let primaryButtonHeight: CGFloat = 44
      static let actionFooterHeight: CGFloat = 24
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
      setupToolBadge()
      setupCommandPreview()
      setupQuestionMode()
      setupTakeoverMode()
      setupPermissionButtons()

      let inset = ConversationLayout.laneHorizontalInset
      NSLayoutConstraint.activate([
        cardContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.outerVerticalInset),
        cardContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        cardContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        // Keep the card height anchored to the measured row height.
        // Using <= here can collapse the container during cell reuse.
        cardContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.outerVerticalInset),

        riskStrip.topAnchor.constraint(equalTo: cardContainer.topAnchor),
        riskStrip.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
        riskStrip.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
        riskStrip.heightAnchor.constraint(equalToConstant: 2),
      ])
    }

    private func setupHeader() {
      headerIcon.translatesAutoresizingMaskIntoConstraints = false
      headerIcon.contentMode = .scaleAspectFit
      headerIcon.tintColor = UIColor(Color.statusPermission)
      cardContainer.addSubview(headerIcon)

      headerLabel.translatesAutoresizingMaskIntoConstraints = false
      headerLabel.font = UIFont.systemFont(ofSize: TypeScale.subhead, weight: .semibold)
      headerLabel.textColor = UIColor(Color.textPrimary)
      cardContainer.addSubview(headerLabel)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        headerIcon.topAnchor.constraint(equalTo: riskStrip.bottomAnchor, constant: pad),
        headerIcon.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        headerIcon.widthAnchor.constraint(equalToConstant: Layout.headerIconSize),
        headerIcon.heightAnchor.constraint(equalToConstant: Layout.headerIconSize),

        headerLabel.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: CGFloat(Spacing.sm)),
        headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardContainer.trailingAnchor, constant: -pad),
      ])
    }

    private func setupToolBadge() {
      toolBadge.layer.cornerRadius = 9
      toolBadge.backgroundColor = UIColor(Color.backgroundTertiary)
      toolBadge.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(toolBadge)

      toolIcon.translatesAutoresizingMaskIntoConstraints = false
      toolIcon.contentMode = .scaleAspectFit
      toolIcon.tintColor = UIColor(Color.textSecondary)
      toolBadge.addSubview(toolIcon)

      toolNameLabel.translatesAutoresizingMaskIntoConstraints = false
      toolNameLabel.font = UIFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
      toolNameLabel.textColor = UIColor(Color.textSecondary)
      toolBadge.addSubview(toolNameLabel)

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
        toolBadge.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: CGFloat(Spacing.md)),
        toolBadge.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),

        toolIcon.leadingAnchor.constraint(equalTo: toolBadge.leadingAnchor, constant: CGFloat(Spacing.sm)),
        toolIcon.centerYAnchor.constraint(equalTo: toolBadge.centerYAnchor),
        toolIcon.widthAnchor.constraint(equalToConstant: 12),
        toolIcon.heightAnchor.constraint(equalToConstant: 12),

        toolNameLabel.leadingAnchor.constraint(equalTo: toolIcon.trailingAnchor, constant: CGFloat(Spacing.xs)),
        toolNameLabel.trailingAnchor.constraint(equalTo: toolBadge.trailingAnchor, constant: -CGFloat(Spacing.sm)),
        toolNameLabel.topAnchor.constraint(equalTo: toolBadge.topAnchor, constant: CGFloat(Spacing.xs)),
        toolNameLabel.bottomAnchor.constraint(equalTo: toolBadge.bottomAnchor, constant: -CGFloat(Spacing.xs)),

        riskBadgeContainer.leadingAnchor.constraint(equalTo: toolBadge.trailingAnchor, constant: CGFloat(Spacing.sm)),
        riskBadgeContainer.centerYAnchor.constraint(equalTo: toolBadge.centerYAnchor),

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

      scopeRow.translatesAutoresizingMaskIntoConstraints = false
      scopeRow.isHidden = true
      cardContainer.addSubview(scopeRow)

      scopeLabel.translatesAutoresizingMaskIntoConstraints = false
      scopeLabel.font = UIFont.systemFont(ofSize: TypeScale.micro)
      scopeLabel.textColor = UIColor(Color.textQuaternary)
      scopeLabel.lineBreakMode = .byTruncatingTail
      scopeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
      scopeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      scopeRow.addSubview(scopeLabel)

      requestIdLabel.translatesAutoresizingMaskIntoConstraints = false
      requestIdLabel.font = UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
      requestIdLabel.textColor = UIColor(Color.textQuaternary)
      requestIdLabel.textAlignment = .right
      requestIdLabel.setContentHuggingPriority(.required, for: .horizontal)
      requestIdLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      scopeRow.addSubview(requestIdLabel)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        segmentStack.topAnchor.constraint(equalTo: toolBadge.bottomAnchor, constant: CGFloat(Spacing.sm)),
        segmentStack.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        segmentStack.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        riskFindingsStack.topAnchor.constraint(
          equalTo: segmentStack.bottomAnchor,
          constant: CGFloat(Spacing.sm)
        ),
        riskFindingsStack.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        riskFindingsStack.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        scopeRow.topAnchor.constraint(
          equalTo: riskFindingsStack.bottomAnchor,
          constant: CGFloat(Spacing.xs)
        ),
        scopeRow.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        scopeRow.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        scopeLabel.leadingAnchor.constraint(equalTo: scopeRow.leadingAnchor),
        scopeLabel.topAnchor.constraint(equalTo: scopeRow.topAnchor),
        scopeLabel.bottomAnchor.constraint(equalTo: scopeRow.bottomAnchor),

        requestIdLabel.leadingAnchor.constraint(
          greaterThanOrEqualTo: scopeLabel.trailingAnchor,
          constant: CGFloat(Spacing.sm)
        ),
        requestIdLabel.trailingAnchor.constraint(equalTo: scopeRow.trailingAnchor),
        requestIdLabel.centerYAnchor.constraint(equalTo: scopeRow.centerYAnchor),
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
        takeoverDescription.topAnchor.constraint(equalTo: toolBadge.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverDescription.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverDescription.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        takeoverButton.topAnchor.constraint(equalTo: takeoverDescription.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        takeoverButton.heightAnchor.constraint(equalToConstant: 42),
      ])
    }

    private func setupPermissionButtons() {
      actionDivider.backgroundColor = UIColor(Color.textQuaternary).withAlphaComponent(0.3)
      actionDivider.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(actionDivider)

      buttonStack.axis = .horizontal
      buttonStack.spacing = CGFloat(Spacing.xs)
      buttonStack.distribution = .fillEqually
      buttonStack.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(buttonStack)

      // Deny button with context menu
      denyButton.setTitle("Deny", for: .normal)
      denyButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      denyButton.setTitleColor(UIColor(Color.statusError), for: .normal)
      denyButton.backgroundColor = UIColor(Color.statusError).withAlphaComponent(CGFloat(OpacityTier.light))
      denyButton.layer.cornerRadius = CGFloat(Radius.md)
      denyButton.accessibilityHint = "Press and hold for deny reason or stop turn options"
      denyButton.addTarget(self, action: #selector(denyButtonTapped), for: .touchUpInside)
      buttonStack.addArrangedSubview(denyButton)

      // Approve button with context menu
      approveButton.setTitle("Approve Once", for: .normal)
      approveButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      approveButton.setTitleColor(.white, for: .normal)
      approveButton.backgroundColor = UIColor(Color.accent).withAlphaComponent(0.75)
      approveButton.layer.cornerRadius = CGFloat(Radius.md)
      approveButton.accessibilityHint = "Press and hold for session or always allow options"
      approveButton.addTarget(self, action: #selector(approveButtonTapped), for: .touchUpInside)
      buttonStack.addArrangedSubview(approveButton)

      actionHintLabel.translatesAutoresizingMaskIntoConstraints = false
      actionHintLabel.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      actionHintLabel.textColor = UIColor(Color.textQuaternary)
      actionHintLabel.text = "Decision applies to the full request. Long-press or More for alternate actions."
      actionHintLabel.numberOfLines = 1
      actionHintLabel.lineBreakMode = .byTruncatingTail
      actionHintLabel.adjustsFontSizeToFitWidth = true
      actionHintLabel.minimumScaleFactor = 0.85
      actionHintLabel.isHidden = true
      cardContainer.addSubview(actionHintLabel)

      moreActionsButton.translatesAutoresizingMaskIntoConstraints = false
      var moreConfig = UIButton.Configuration.plain()
      moreConfig.title = "More"
      moreConfig.baseForegroundColor = UIColor(Color.textSecondary)
      moreConfig.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
      moreActionsButton.configuration = moreConfig
      moreActionsButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
      moreActionsButton.backgroundColor = UIColor(Color.backgroundTertiary).withAlphaComponent(0.7)
      moreActionsButton.layer.cornerRadius = CGFloat(Radius.sm)
      moreActionsButton.showsMenuAsPrimaryAction = true
      moreActionsButton.isHidden = true
      cardContainer.addSubview(moreActionsButton)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        actionDivider.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        actionDivider.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        actionDivider.heightAnchor.constraint(equalToConstant: 1),

        buttonStack.topAnchor.constraint(equalTo: actionDivider.bottomAnchor, constant: CGFloat(Spacing.sm)),
        buttonStack.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        buttonStack.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        buttonStack.heightAnchor.constraint(equalToConstant: Layout.primaryButtonHeight),

        actionHintLabel.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: CGFloat(Spacing.xs)),
        actionHintLabel.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        actionHintLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: moreActionsButton.leadingAnchor,
          constant: -CGFloat(Spacing.sm)
        ),
        actionHintLabel.heightAnchor.constraint(equalToConstant: Layout.actionFooterHeight),

        moreActionsButton.centerYAnchor.constraint(equalTo: actionHintLabel.centerYAnchor),
        moreActionsButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        moreActionsButton.heightAnchor.constraint(equalToConstant: Layout.actionFooterHeight),
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
      toolBadge.isHidden = false
      segmentStack.isHidden = !hasContent
      actionDivider.isHidden = false
      buttonStack.isHidden = false
      actionHintLabel.isHidden = false
      moreActionsButton.isHidden = false
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

      // Header
      let iconName = model.risk == .high ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
      headerIcon.image = UIImage(systemName: iconName)
      headerIcon.tintColor = UIColor(model.risk.tintColor)
      headerLabel.text = "Approval Required"

      // Tool badge
      if let toolName = model.toolName {
        toolIcon.image = UIImage(systemName: ToolCardStyle.icon(for: toolName))
        toolNameLabel.text = toolName
      }

      // Structured preview content
      configurePreviewContent(model)
      configureRiskFindings(model)
      configureScopeRow(model)

      // Configure context menus on buttons
      configureDenyMenu(model)
      configureApproveMenu(model)
      configureMoreActionsMenu(model)
      let hasAlwaysAllow = model.approvalType == .exec && model.hasAmendment
      actionHintLabel.text = hasAlwaysAllow
        ? "Decision applies to the full request. Use long-press or More for session, always allow, or deny-reason actions."
        : "Decision applies to the full request. Use long-press or More for session and deny-reason actions."
      approveButton.accessibilityHint = hasAlwaysAllow
        ? "Approves the full request once. Press and hold for session or always allow options."
        : "Approves the full request once. Press and hold for allow-for-session options."
      moreActionsButton.accessibilityHint = "Opens all full-request approval and denial actions."

      // Position divider
      updateDividerPosition(model)
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

      // Cap text height to match the height calculation's maxCommandTextHeight clamp.
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

      // Cap value text height to match the height calculation's maxCommandTextHeight clamp.
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

    private func configureScopeRow(_ model: ApprovalCardModel) {
      let hasScope = ApprovalPermissionPreviewHelpers.trimmed(model.decisionScope) != nil
      let hasId = ApprovalPermissionPreviewHelpers.trimmed(model.approvalId) != nil

      guard hasScope || hasId else {
        scopeRow.isHidden = true
        return
      }

      scopeLabel.text = model.decisionScope
      requestIdLabel.text = model.approvalId.map { "#\($0)" }
      scopeRow.isHidden = false
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
      toolBadge.isHidden = true
      segmentStack.isHidden = true
      riskFindingsStack.isHidden = true
      scopeRow.isHidden = true
      actionDivider.isHidden = true
      buttonStack.isHidden = true
      actionHintLabel.isHidden = true
      moreActionsButton.isHidden = true
      riskBadgeContainer.isHidden = true
      takeoverDescription.isHidden = true
      takeoverButton.isHidden = true

      headerIcon.image = UIImage(systemName: "questionmark.bubble.fill")
      headerIcon.tintColor = tint
      headerLabel.text = "Question"
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
      toolBadge.isHidden = model.toolName == nil

      if let toolName = model.toolName {
        toolIcon.image = UIImage(systemName: ToolCardStyle.icon(for: toolName))
        toolNameLabel.text = toolName
      }

      // Hide
      segmentStack.isHidden = true
      riskFindingsStack.isHidden = true
      scopeRow.isHidden = true
      actionDivider.isHidden = true
      buttonStack.isHidden = true
      actionHintLabel.isHidden = true
      moreActionsButton.isHidden = true
      riskBadgeContainer.isHidden = true
      questionTextLabel.isHidden = true
      questionOptionsTopConstraint?.constant = 0
      questionOptionsStack.isHidden = true
      configureQuestionOptions([])
      clearQuestionFormState()
      answerField.isHidden = true
      submitButton.isHidden = true

      let iconName = isPermission ? "lock.fill" : "questionmark.bubble.fill"
      headerIcon.image = UIImage(systemName: iconName)
      headerIcon.tintColor = tint
      headerLabel.text = isPermission ? "Approval Required" : "Question Pending"
      takeoverDescription.text = "Take over this session to respond."
      takeoverButton.setTitle(isPermission ? "Take Over & Review" : "Take Over & Answer", for: .normal)
      takeoverButton.backgroundColor = tint.withAlphaComponent(0.75)
    }

    private func configureDenyMenu(_ model: ApprovalCardModel) {
      denyButton.menu = UIMenu(children: denyMenuActions(model))
      denyButton.showsMenuAsPrimaryAction = false
    }

    private func configureApproveMenu(_ model: ApprovalCardModel) {
      approveButton.menu = UIMenu(children: approveMenuActions(model))
      approveButton.showsMenuAsPrimaryAction = false
    }

    private func configureMoreActionsMenu(_ model: ApprovalCardModel) {
      let approveInline = UIMenu(
        title: "Approve",
        options: .displayInline,
        children: approveMenuActions(model)
      )
      let denyInline = UIMenu(
        title: "Deny",
        options: .displayInline,
        children: denyMenuActions(model)
      )
      moreActionsButton.menu = UIMenu(children: [approveInline, denyInline])
    }

    private func denyMenuActions(_ _: ApprovalCardModel) -> [UIAction] {
      let denyAction = UIAction(
        title: "Deny",
        image: UIImage(systemName: "xmark"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onDecision?("denied", nil, nil)
      }
      let denyReasonAction = UIAction(
        title: "Deny with Reason",
        image: UIImage(systemName: "text.bubble")
      ) { [weak self] _ in
        // Show an alert for reason input on iOS
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
      let denyStopAction = UIAction(
        title: "Deny & Stop",
        image: UIImage(systemName: "stop.fill"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onDecision?("abort", nil, nil)
      }

      return [denyAction, denyReasonAction, denyStopAction]
    }

    private func approveMenuActions(_ model: ApprovalCardModel) -> [UIAction] {
      var children: [UIAction] = []
      children
        .append(UIAction(title: "Approve Request Once", image: UIImage(systemName: "checkmark")) { [weak self] _ in
          self?.onDecision?("approved", nil, nil)
        })
      children
        .append(UIAction(title: "Allow for Session", image: UIImage(systemName: "checkmark.seal")) { [weak self] _ in
          self?.onDecision?("approved_for_session", nil, nil)
        })
      if model.approvalType == .exec, model.hasAmendment {
        children
          .append(UIAction(title: "Always Allow", image: UIImage(systemName: "checkmark.shield")) { [weak self] _ in
            self?.onDecision?("approved_always", nil, nil)
          })
      }

      return children
    }

    private func updateDividerPosition(_: ApprovalCardModel) {
      for constraint in cardContainer.constraints where constraint.firstItem === actionDivider
        && constraint.firstAttribute == .top
      {
        constraint.isActive = false
      }

      let anchor: UIView = if !scopeRow.isHidden {
        scopeRow
      } else if !riskFindingsStack.isHidden {
        riskFindingsStack
      } else if !segmentStack.isHidden {
        segmentStack
      } else {
        toolBadge
      }

      actionDivider.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: CGFloat(Spacing.sm)).isActive = true
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
        config.title = Self.questionOptionDisplayText(option)
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
            config.title = Self.questionOptionDisplayText(option)
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
      guard let model else { return 180 }

      let pad = Layout.cardPadding
      let outerInset = Layout.outerVerticalInset
      let laneInset = ConversationLayout.laneHorizontalInset
      let contentWidth = availableWidth - laneInset * 2 - pad * 2

      switch model.mode {
        case .permission:
          var h: CGFloat = outerInset + 2 + pad // cell pad + risk strip + card pad
          h += Layout.headerIconSize // header
          h += CGFloat(Spacing.md) + 20 // tool badge

          let hasContent = ApprovalPermissionPreviewHelpers.hasPreviewContent(model)
          if hasContent {
            h += CGFloat(Spacing.sm) // spacing before segment stack
            h += Self.segmentStackHeight(for: model, contentWidth: contentWidth)
          }

          if !model.riskFindings.isEmpty {
            h += CGFloat(Spacing.sm)
            let findingHeight: CGFloat = 14
            h += findingHeight * CGFloat(model.riskFindings.count)
            h += CGFloat(Spacing.xs) * CGFloat(max(0, model.riskFindings.count - 1))
          }

          let hasScope = ApprovalPermissionPreviewHelpers.trimmed(model.decisionScope) != nil
          let hasId = ApprovalPermissionPreviewHelpers.trimmed(model.approvalId) != nil
          if hasScope || hasId {
            h += CGFloat(Spacing.xs) + 12
          }

          if model.diff != nil { h += 120 }

          h += CGFloat(Spacing.sm) + 1 // divider
          h += CGFloat(Spacing.sm) + Layout.primaryButtonHeight // primary buttons (44pt touch targets)
          h += CGFloat(Spacing.xs) + Layout.actionFooterHeight
          h += pad + outerInset // card pad + cell pad
          return h

        case .question:
          var h: CGFloat = outerInset + 2 + pad
          h += Layout.headerIconSize // header
          h += CGFloat(Spacing.md)
          let prompts = questionPrompts(for: model)
          if prompts.count > 1 {
            h += Self.measureTextHeight(
              "Answer all questions to continue.",
              font: UIFont.systemFont(ofSize: TypeScale.reading, weight: .medium),
              width: contentWidth
            )
            h += CGFloat(Spacing.md)
            for (index, prompt) in prompts.enumerated() {
              h += questionPromptHeight(prompt, width: contentWidth)
              if index < prompts.count - 1 {
                h += CGFloat(Spacing.sm)
              }
            }
            h += CGFloat(Spacing.md) + 42 // submit button
          } else if let prompt = prompts.first {
            let qFont = UIFont.systemFont(ofSize: TypeScale.reading)
            h += Self.measureTextHeight(prompt.question, font: qFont, width: contentWidth)
            if prompt.options.isEmpty {
              h += CGFloat(Spacing.md) + 34 // answer field
              h += CGFloat(Spacing.md) + 42 // submit button
            } else {
              h += CGFloat(Spacing.md) // spacing before options
              for (index, option) in prompt.options.enumerated() {
                h += Self.questionOptionHeight(option, width: contentWidth)
                if index < prompt.options.count - 1 {
                  h += CGFloat(Spacing.xs)
                }
              }
            }
          } else {
            h += 20
            h += CGFloat(Spacing.md) + 34 // answer field
            h += CGFloat(Spacing.md) + 42 // submit button
          }
          h += pad + outerInset
          return h

        case .takeover:
          var h: CGFloat = outerInset + 2 + pad
          h += Layout.headerIconSize // header
          h += CGFloat(Spacing.md) + 20 // tool badge
          h += CGFloat(Spacing.md) + 20 // description
          h += CGFloat(Spacing.md) + 42 // button
          h += pad + outerInset
          return h

        case .none:
          return 1
      }
    }

    private static func measureTextHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
      guard !text.isEmpty, width > 0 else { return 0 }
      let attr = NSAttributedString(string: text, attributes: [.font: font])
      let rect = attr.boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
      return ceil(rect.height)
    }

    private static func segmentStackHeight(for model: ApprovalCardModel, contentWidth: CGFloat) -> CGFloat {
      let textWidth = max(1, contentWidth - CGFloat(EdgeBar.width) - Layout.commandHorizontalPadding * 2)
      let monoFont = UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)

      var segments: [(command: String, hasOperator: Bool)] = []

      switch model.previewType {
        case .shellCommand:
          if !model.shellSegments.isEmpty {
            segments = model.shellSegments.map { ($0.command, $0.leadingOperator != nil) }
          } else if let cmd = ApprovalPermissionPreviewHelpers.trimmed(model.command) {
            segments = [(cmd, false)]
          } else if let manifest = ApprovalPermissionPreviewHelpers.trimmed(model.serverManifest) {
            segments = [(manifest, false)]
          }
        default:
          if let value = ApprovalPermissionPreviewHelpers.previewValue(for: model) {
            let labelHeight: CGFloat = 12
            let textHeight = measureTextHeight(value, font: monoFont, width: textWidth)
            let clampedText = min(textHeight, Layout.maxCommandTextHeight)
            return Layout.commandVerticalPadding + labelHeight + CGFloat(Spacing.xxs) + clampedText + Layout
              .commandVerticalPadding
          } else if let manifest = ApprovalPermissionPreviewHelpers.trimmed(model.serverManifest) {
            segments = [(manifest, false)]
          }
      }

      guard !segments.isEmpty else { return 0 }

      var total: CGFloat = 0
      for (index, segment) in segments.enumerated() {
        let textHeight = measureTextHeight(segment.command, font: monoFont, width: textWidth)
        let clampedText = min(textHeight, Layout.maxCommandTextHeight)
        var segmentHeight = Layout.commandVerticalPadding + clampedText + Layout.commandVerticalPadding
        if segment.hasOperator {
          segmentHeight += 16 + CGFloat(Spacing.xs)
        }
        total += segmentHeight
        if index > 0 {
          total += CGFloat(Spacing.xs)
        }
      }
      return total
    }

    private static func questionOptionDisplayText(_ option: ApprovalQuestionOption) -> String {
      if let description = option.description, !description.isEmpty {
        return "\(option.label)\n\(description)"
      }
      return option.label
    }

    private static func questionPrompts(for model: ApprovalCardModel) -> [ApprovalQuestionPrompt] {
      model.questions
    }

    private static func questionPromptHeight(_ prompt: ApprovalQuestionPrompt, width: CGFloat) -> CGFloat {
      var height: CGFloat = 0
      if let header = prompt.header, !header.isEmpty {
        height += measureTextHeight(
          header.uppercased(),
          font: UIFont.systemFont(ofSize: TypeScale.micro, weight: .semibold),
          width: width
        )
        height += 4
      }

      height += measureTextHeight(
        prompt.question,
        font: UIFont.systemFont(ofSize: TypeScale.reading, weight: .medium),
        width: width
      )

      if !prompt.options.isEmpty {
        height += 6
        for (index, option) in prompt.options.enumerated() {
          height += questionOptionHeight(option, width: width)
          if index < prompt.options.count - 1 {
            height += CGFloat(Spacing.xs)
          }
        }
      }

      if prompt.options.isEmpty || prompt.allowsOther {
        height += 6 + 34
      }

      return height
    }

    private static func questionOptionHeight(_ option: ApprovalQuestionOption, width: CGFloat) -> CGFloat {
      let text = questionOptionDisplayText(option)
      let textHeight = measureTextHeight(
        text,
        font: UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold),
        width: max(1, width - 24)
      )
      return max(44, textHeight + 20)
    }

  }

#endif
