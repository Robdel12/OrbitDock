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
    var onAnswer: ((String) -> Void)?
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

    // Command preview
    private let commandContainer = UIView()
    private let commandAccentBar = UIView()
    private let commandText = UITextView()

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
    private var commandTextHeightConstraint: NSLayoutConstraint?
    private var commandPreviewTextForSizing: String?
    private var questionOptionsTopConstraint: NSLayoutConstraint?

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
      refreshCommandPreviewHeight()
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
      riskBadgeLabel.text = "DESTRUCTIVE"
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
      commandContainer.layer.cornerRadius = CGFloat(Radius.md)
      commandContainer.backgroundColor = UIColor(Color.backgroundPrimary)
      commandContainer.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(commandContainer)

      commandAccentBar.translatesAutoresizingMaskIntoConstraints = false
      commandContainer.addSubview(commandAccentBar)

      commandText.translatesAutoresizingMaskIntoConstraints = false
      commandText.font = UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      commandText.textColor = UIColor(Color.textPrimary)
      commandText.backgroundColor = .clear
      commandText.isEditable = false
      commandText.isSelectable = true
      commandText.isScrollEnabled = false
      commandText.showsHorizontalScrollIndicator = false
      commandText.showsVerticalScrollIndicator = false
      commandText.textContainerInset = .zero
      commandText.textContainer.lineFragmentPadding = 0
      commandContainer.addSubview(commandText)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        commandContainer.topAnchor.constraint(equalTo: toolBadge.bottomAnchor, constant: CGFloat(Spacing.sm)),
        commandContainer.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        commandContainer.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        commandAccentBar.topAnchor.constraint(equalTo: commandContainer.topAnchor),
        commandAccentBar.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor),
        commandAccentBar.leadingAnchor.constraint(equalTo: commandContainer.leadingAnchor),
        commandAccentBar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        commandText.topAnchor.constraint(equalTo: commandContainer.topAnchor, constant: Layout.commandVerticalPadding),
        commandText.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor, constant: -Layout.commandVerticalPadding),
        commandText.leadingAnchor.constraint(
          equalTo: commandAccentBar.trailingAnchor,
          constant: Layout.commandHorizontalPadding
        ),
        commandText.trailingAnchor.constraint(
          equalTo: commandContainer.trailingAnchor,
          constant: -Layout.commandHorizontalPadding
        ),
      ])

      commandTextHeightConstraint = commandText.heightAnchor.constraint(equalToConstant: Layout.minCommandTextHeight)
      commandTextHeightConstraint?.isActive = true
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
      actionHintLabel.text = "Press and hold buttons for session, always, and deny-reason options"
      actionHintLabel.numberOfLines = 1
      actionHintLabel.lineBreakMode = .byTruncatingTail
      actionHintLabel.adjustsFontSizeToFitWidth = true
      actionHintLabel.minimumScaleFactor = 0.85
      actionHintLabel.isHidden = true
      cardContainer.addSubview(actionHintLabel)

      moreActionsButton.translatesAutoresizingMaskIntoConstraints = false
      moreActionsButton.setTitle("More", for: .normal)
      moreActionsButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
      moreActionsButton.setTitleColor(UIColor(Color.textSecondary), for: .normal)
      moreActionsButton.backgroundColor = UIColor(Color.backgroundTertiary).withAlphaComponent(0.7)
      moreActionsButton.layer.cornerRadius = CGFloat(Radius.sm)
      moreActionsButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
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
      let commandPreviewText = Self.commandPreviewText(for: model)

      // Show
      toolBadge.isHidden = false
      commandContainer.isHidden = commandPreviewText == nil
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
      answerField.isHidden = true
      submitButton.isHidden = true
      takeoverDescription.isHidden = true
      takeoverButton.isHidden = true

      // Header
      let iconName = model.risk == .high ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
      headerIcon.image = UIImage(systemName: iconName)
      headerIcon.tintColor = UIColor(model.risk.tintColor)
      headerLabel.text = "Permission Required"

      // Tool badge
      if let toolName = model.toolName {
        toolIcon.image = UIImage(systemName: ToolCardStyle.icon(for: toolName))
        toolNameLabel.text = toolName
      }

      // Command preview
      if let commandPreviewText {
        setCommandPreviewText(commandPreviewText)
        commandAccentBar.backgroundColor = UIColor(model.risk.tintColor)
        commandContainer.isHidden = false
      } else {
        setCommandPreviewText(nil)
        commandContainer.isHidden = true
      }

      // Configure context menus on buttons
      configureDenyMenu(model)
      configureApproveMenu(model)
      configureMoreActionsMenu(model)
      let hasAlwaysAllow = model.approvalType == .exec && model.hasAmendment
      actionHintLabel.text = hasAlwaysAllow
        ? "Long-press buttons, or use More, for session/always/deny-reason actions"
        : "Long-press buttons, or use More, for session/deny-reason actions"
      approveButton.accessibilityHint = hasAlwaysAllow
        ? "Press and hold for session or always allow options"
        : "Press and hold for allow-for-session options"
      moreActionsButton.accessibilityHint = "Opens all approval and denial actions"

      // Position divider
      updateDividerPosition(model)
    }

    private func configureQuestion(_ model: ApprovalCardModel) {
      let tint = UIColor(Color.statusQuestion)
      riskStrip.backgroundColor = tint
      cardContainer.backgroundColor = tint.withAlphaComponent(CGFloat(OpacityTier.light))
      cardContainer.layer.borderColor = tint.withAlphaComponent(CGFloat(OpacityTier.medium)).cgColor

      // Show
      questionTextLabel.isHidden = false
      let hasOptions = !model.questionOptions.isEmpty
      configureQuestionOptions(model.questionOptions)
      questionOptionsTopConstraint?.constant = hasOptions ? CGFloat(Spacing.md) : 0
      questionOptionsStack.isHidden = !hasOptions
      answerField.isHidden = hasOptions
      submitButton.isHidden = hasOptions

      // Hide
      toolBadge.isHidden = true
      commandContainer.isHidden = true
      setCommandPreviewText(nil)
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
      questionTextLabel.text = model.question ?? ""
      if !hasOptions {
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
      commandContainer.isHidden = true
      setCommandPreviewText(nil)
      actionDivider.isHidden = true
      buttonStack.isHidden = true
      actionHintLabel.isHidden = true
      moreActionsButton.isHidden = true
      riskBadgeContainer.isHidden = true
      questionTextLabel.isHidden = true
      questionOptionsTopConstraint?.constant = 0
      questionOptionsStack.isHidden = true
      configureQuestionOptions([])
      answerField.isHidden = true
      submitButton.isHidden = true

      let iconName = isPermission ? "lock.fill" : "questionmark.bubble.fill"
      headerIcon.image = UIImage(systemName: iconName)
      headerIcon.tintColor = tint
      headerLabel.text = isPermission ? "Permission Required" : "Question Pending"
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
      children.append(UIAction(title: "Approve Once", image: UIImage(systemName: "checkmark")) { [weak self] _ in
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

    private func updateDividerPosition(_ model: ApprovalCardModel) {
      // Remove existing position constraints for divider
      for constraint in cardContainer.constraints where constraint.firstItem === actionDivider
        && constraint.firstAttribute == .top
      {
        constraint.isActive = false
      }

      let anchor: UIView = commandContainer.isHidden ? toolBadge : commandContainer
      actionDivider.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: CGFloat(Spacing.sm)).isActive = true
    }

    private func setCommandPreviewText(_ text: String?) {
      commandPreviewTextForSizing = text
      commandText.text = text ?? ""
      commandText.setContentOffset(.zero, animated: false)
      refreshCommandPreviewHeight()
    }

    private func refreshCommandPreviewHeight() {
      guard !commandContainer.isHidden, let text = commandPreviewTextForSizing else {
        commandTextHeightConstraint?.constant = Layout.minCommandTextHeight
        commandText.isScrollEnabled = false
        commandText.showsVerticalScrollIndicator = false
        return
      }

      let availableWidth = max(bounds.width, 1)
      let visibleHeight = Self.visibleCommandTextHeight(text, availableWidth: availableWidth)
      commandTextHeightConstraint?.constant = visibleHeight

      let fullHeight = Self.measureTextHeight(
        text,
        font: UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular),
        width: Self.commandTextWidth(for: availableWidth)
      )
      let shouldScroll = fullHeight > visibleHeight + 0.5
      commandText.isScrollEnabled = shouldScroll
      commandText.showsVerticalScrollIndicator = shouldScroll
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
      onAnswer?(answer)
      answerField.text = ""
    }

    @objc private func submitButtonTapped() {
      answerFieldReturnPressed()
    }

    @objc private func takeoverButtonTapped() {
      onTakeOver?()
    }

    private func configureQuestionOptions(_ options: [ApprovalQuestionOption]) {
      questionOptionsStack.arrangedSubviews.forEach { view in
        questionOptionsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }

      guard !options.isEmpty else { return }

      for option in options {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(Self.questionOptionDisplayText(option), for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.titleLabel?.textAlignment = .left
        button.contentHorizontalAlignment = .leading
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        button.setTitleColor(UIColor(Color.textPrimary), for: .normal)
        button.backgroundColor = UIColor(Color.backgroundPrimary).withAlphaComponent(0.8)
        button.layer.cornerRadius = CGFloat(Radius.md)
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor(Color.statusQuestion).withAlphaComponent(0.35).cgColor
        button.accessibilityHint = option.description
        button.addAction(
          UIAction { [weak self] _ in
            self?.onAnswer?(option.label)
          },
          for: .touchUpInside
        )
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        questionOptionsStack.addArrangedSubview(button)
      }
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

          if let text = Self.commandPreviewText(for: model) {
            h += CGFloat(Spacing.sm) // spacing before command container
            h += Layout.commandVerticalPadding
            h += Self.visibleCommandTextHeight(text, availableWidth: availableWidth)
            h += Layout.commandVerticalPadding
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
          if let question = model.question {
            let qFont = UIFont.systemFont(ofSize: TypeScale.reading)
            h += Self.measureTextHeight(question, font: qFont, width: contentWidth)
          } else {
            h += 20
          }
          if model.questionOptions.isEmpty {
            h += CGFloat(Spacing.md) + 34 // answer field
            h += CGFloat(Spacing.md) + 42 // submit button
          } else {
            h += CGFloat(Spacing.md) // spacing before options
            for (index, option) in model.questionOptions.enumerated() {
              h += Self.questionOptionHeight(option, width: contentWidth)
              if index < model.questionOptions.count - 1 {
                h += CGFloat(Spacing.xs)
              }
            }
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

    private static func commandPreviewText(for model: ApprovalCardModel) -> String? {
      if let command = model.command, !command.isEmpty { return command }
      if let filePath = model.filePath, !filePath.isEmpty { return filePath }
      if let toolName = model.toolName, !toolName.isEmpty {
        return "Approve \(toolName) action?"
      }
      return nil
    }

    private static func questionOptionDisplayText(_ option: ApprovalQuestionOption) -> String {
      if let description = option.description, !description.isEmpty {
        return "\(option.label)\n\(description)"
      }
      return option.label
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

    private static func commandTextWidth(for availableWidth: CGFloat) -> CGFloat {
      let contentWidth = availableWidth - ConversationLayout.laneHorizontalInset * 2 - Layout.cardPadding * 2
      return max(1, contentWidth - CGFloat(EdgeBar.width) - Layout.commandHorizontalPadding * 2)
    }

    private static func visibleCommandTextHeight(_ text: String, availableWidth: CGFloat) -> CGFloat {
      let font = UIFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      let fullHeight = measureTextHeight(text, font: font, width: commandTextWidth(for: availableWidth))
      let clampedHeight = min(fullHeight, Layout.maxCommandTextHeight)
      return max(Layout.minCommandTextHeight, clampedHeight)
    }
  }

#endif
