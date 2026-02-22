//
//  UIKitApprovalCardCell.swift
//  OrbitDock
//
//  iOS UICollectionViewCell for inline approval cards in the conversation timeline.
//  Three modes: permission (tool approval), question (text input), takeover (passive session).
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
    private let commandText = UILabel()

    // Question mode
    private let questionTextLabel = UILabel()
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

    private var currentModel: ApprovalCardModel?

    // MARK: - Init

    override init(frame: CGRect) {
      super.init(frame: frame)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    // MARK: - Setup

    private func setup() {
      backgroundColor = .clear
      contentView.backgroundColor = .clear

      cardContainer.layer.cornerRadius = CGFloat(Radius.xl)
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
        cardContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
        cardContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        cardContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        cardContainer.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

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
      headerLabel.font = UIFont.systemFont(ofSize: TypeScale.title, weight: .semibold)
      headerLabel.textColor = UIColor(Color.textPrimary)
      cardContainer.addSubview(headerLabel)

      let pad = CGFloat(Spacing.lg)
      NSLayoutConstraint.activate([
        headerIcon.topAnchor.constraint(equalTo: riskStrip.bottomAnchor, constant: pad),
        headerIcon.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        headerIcon.widthAnchor.constraint(equalToConstant: 16),
        headerIcon.heightAnchor.constraint(equalToConstant: 16),

        headerLabel.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: CGFloat(Spacing.sm)),
        headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardContainer.trailingAnchor, constant: -pad),
      ])
    }

    private func setupToolBadge() {
      toolBadge.layer.cornerRadius = 10
      toolBadge.backgroundColor = UIColor(Color.backgroundTertiary)
      toolBadge.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(toolBadge)

      toolIcon.translatesAutoresizingMaskIntoConstraints = false
      toolIcon.contentMode = .scaleAspectFit
      toolIcon.tintColor = UIColor(Color.textSecondary)
      toolBadge.addSubview(toolIcon)

      toolNameLabel.translatesAutoresizingMaskIntoConstraints = false
      toolNameLabel.font = UIFont.systemFont(ofSize: TypeScale.caption, weight: .bold)
      toolNameLabel.textColor = UIColor(Color.textSecondary)
      toolBadge.addSubview(toolNameLabel)

      riskBadgeContainer.layer.cornerRadius = 8
      riskBadgeContainer.backgroundColor = UIColor(Color.statusError)
      riskBadgeContainer.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(riskBadgeContainer)

      riskBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
      riskBadgeLabel.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .black)
      riskBadgeLabel.textColor = .white
      riskBadgeLabel.text = "DESTRUCTIVE"
      riskBadgeContainer.addSubview(riskBadgeLabel)

      let pad = CGFloat(Spacing.lg)
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
      commandText.font = UIFont.monospacedSystemFont(ofSize: TypeScale.code, weight: .regular)
      commandText.textColor = UIColor(Color.textPrimary)
      commandText.numberOfLines = 0
      commandText.lineBreakMode = .byWordWrapping
      commandContainer.addSubview(commandText)

      let pad = CGFloat(Spacing.lg)
      NSLayoutConstraint.activate([
        commandContainer.topAnchor.constraint(equalTo: toolBadge.bottomAnchor, constant: CGFloat(Spacing.sm)),
        commandContainer.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        commandContainer.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        commandAccentBar.topAnchor.constraint(equalTo: commandContainer.topAnchor),
        commandAccentBar.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor),
        commandAccentBar.leadingAnchor.constraint(equalTo: commandContainer.leadingAnchor),
        commandAccentBar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        commandText.topAnchor.constraint(equalTo: commandContainer.topAnchor, constant: CGFloat(Spacing.sm)),
        commandText.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor, constant: -CGFloat(Spacing.sm)),
        commandText.leadingAnchor.constraint(equalTo: commandAccentBar.trailingAnchor, constant: CGFloat(Spacing.md)),
        commandText.trailingAnchor.constraint(equalTo: commandContainer.trailingAnchor, constant: -CGFloat(Spacing.md)),
      ])
    }

    private func setupQuestionMode() {
      questionTextLabel.translatesAutoresizingMaskIntoConstraints = false
      questionTextLabel.font = UIFont.systemFont(ofSize: TypeScale.reading)
      questionTextLabel.textColor = UIColor(Color.textPrimary)
      questionTextLabel.numberOfLines = 0
      cardContainer.addSubview(questionTextLabel)

      answerField.translatesAutoresizingMaskIntoConstraints = false
      answerField.placeholder = "Your answer..."
      answerField.font = UIFont.systemFont(ofSize: TypeScale.code)
      answerField.textColor = UIColor(Color.textPrimary)
      answerField.backgroundColor = UIColor(Color.backgroundPrimary)
      answerField.borderStyle = .roundedRect
      answerField.returnKeyType = .send
      answerField.addTarget(self, action: #selector(answerFieldReturnPressed), for: .editingDidEndOnExit)
      cardContainer.addSubview(answerField)

      submitButton.translatesAutoresizingMaskIntoConstraints = false
      submitButton.setTitle("Submit", for: .normal)
      submitButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.code, weight: .semibold)
      submitButton.setTitleColor(.white, for: .normal)
      submitButton.backgroundColor = UIColor(Color.statusQuestion).withAlphaComponent(0.75)
      submitButton.layer.cornerRadius = CGFloat(Radius.lg)
      submitButton.addTarget(self, action: #selector(submitButtonTapped), for: .touchUpInside)
      cardContainer.addSubview(submitButton)

      let pad = CGFloat(Spacing.lg)
      NSLayoutConstraint.activate([
        questionTextLabel.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: CGFloat(Spacing.md)),
        questionTextLabel.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        questionTextLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        answerField.topAnchor.constraint(equalTo: questionTextLabel.bottomAnchor, constant: CGFloat(Spacing.md)),
        answerField.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        answerField.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        answerField.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

        submitButton.topAnchor.constraint(equalTo: answerField.bottomAnchor, constant: CGFloat(Spacing.md)),
        submitButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        submitButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        submitButton.heightAnchor.constraint(equalToConstant: 44),
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
      takeoverButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.code, weight: .semibold)
      takeoverButton.setTitleColor(.white, for: .normal)
      takeoverButton.layer.cornerRadius = CGFloat(Radius.lg)
      takeoverButton.addTarget(self, action: #selector(takeoverButtonTapped), for: .touchUpInside)
      cardContainer.addSubview(takeoverButton)

      let pad = CGFloat(Spacing.lg)
      NSLayoutConstraint.activate([
        takeoverDescription.topAnchor.constraint(equalTo: toolBadge.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverDescription.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverDescription.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        takeoverButton.topAnchor.constraint(equalTo: takeoverDescription.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        takeoverButton.heightAnchor.constraint(equalToConstant: 44),
      ])
    }

    private func setupPermissionButtons() {
      actionDivider.backgroundColor = UIColor(Color.textQuaternary).withAlphaComponent(0.3)
      actionDivider.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(actionDivider)

      buttonStack.axis = .horizontal
      buttonStack.spacing = CGFloat(Spacing.sm)
      buttonStack.distribution = .fillEqually
      buttonStack.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(buttonStack)

      // Deny button with context menu
      denyButton.setTitle("Deny", for: .normal)
      denyButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.code, weight: .semibold)
      denyButton.setTitleColor(UIColor(Color.statusError), for: .normal)
      denyButton.backgroundColor = UIColor(Color.statusError).withAlphaComponent(CGFloat(OpacityTier.light))
      denyButton.layer.cornerRadius = CGFloat(Radius.lg)
      denyButton.addTarget(self, action: #selector(denyButtonTapped), for: .touchUpInside)
      buttonStack.addArrangedSubview(denyButton)

      // Approve button with context menu
      approveButton.setTitle("Approve", for: .normal)
      approveButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.code, weight: .semibold)
      approveButton.setTitleColor(.white, for: .normal)
      approveButton.backgroundColor = UIColor(Color.accent).withAlphaComponent(0.75)
      approveButton.layer.cornerRadius = CGFloat(Radius.lg)
      approveButton.addTarget(self, action: #selector(approveButtonTapped), for: .touchUpInside)
      buttonStack.addArrangedSubview(approveButton)

      let pad = CGFloat(Spacing.lg)
      NSLayoutConstraint.activate([
        actionDivider.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        actionDivider.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        actionDivider.heightAnchor.constraint(equalToConstant: 1),

        buttonStack.topAnchor.constraint(equalTo: actionDivider.bottomAnchor, constant: CGFloat(Spacing.md)),
        buttonStack.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        buttonStack.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        buttonStack.heightAnchor.constraint(equalToConstant: 44),
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
      // Show
      toolBadge.isHidden = false
      commandContainer.isHidden = model.command == nil && model.filePath == nil
      actionDivider.isHidden = false
      buttonStack.isHidden = false
      riskBadgeContainer.isHidden = model.risk != .high

      // Hide
      questionTextLabel.isHidden = true
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
      if let command = model.command {
        commandText.text = command
        commandAccentBar.backgroundColor = UIColor(model.risk.tintColor)
        commandContainer.isHidden = false
      } else if let filePath = model.filePath {
        commandText.text = filePath
        commandAccentBar.backgroundColor = UIColor(model.risk.tintColor)
        commandContainer.isHidden = false
      } else {
        commandContainer.isHidden = true
      }

      // Configure context menus on buttons
      configureDenyMenu(model)
      configureApproveMenu(model)

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
      answerField.isHidden = false
      submitButton.isHidden = false

      // Hide
      toolBadge.isHidden = true
      commandContainer.isHidden = true
      actionDivider.isHidden = true
      buttonStack.isHidden = true
      riskBadgeContainer.isHidden = true
      takeoverDescription.isHidden = true
      takeoverButton.isHidden = true

      headerIcon.image = UIImage(systemName: "questionmark.bubble.fill")
      headerIcon.tintColor = tint
      headerLabel.text = "Question"
      questionTextLabel.text = model.question ?? ""
      answerField.text = ""
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
      actionDivider.isHidden = true
      buttonStack.isHidden = true
      riskBadgeContainer.isHidden = true
      questionTextLabel.isHidden = true
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
        title: "Deny & Stop Turn",
        image: UIImage(systemName: "stop.fill"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onDecision?("abort", nil, nil)
      }

      denyButton.menu = UIMenu(children: [denyAction, denyReasonAction, denyStopAction])
      denyButton.showsMenuAsPrimaryAction = false
    }

    private func configureApproveMenu(_ model: ApprovalCardModel) {
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

      approveButton.menu = UIMenu(children: children)
      approveButton.showsMenuAsPrimaryAction = false
    }

    private func updateDividerPosition(_ model: ApprovalCardModel) {
      // Remove existing position constraints for divider
      for constraint in cardContainer.constraints where constraint.firstItem === actionDivider
        && constraint.firstAttribute == .top
      {
        constraint.isActive = false
      }

      let anchor: UIView = commandContainer.isHidden ? toolBadge : commandContainer
      actionDivider.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: CGFloat(Spacing.md)).isActive = true
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

    // MARK: - Height

    static func requiredHeight(for model: ApprovalCardModel?, availableWidth: CGFloat) -> CGFloat {
      guard let model else { return 180 }

      let pad = CGFloat(Spacing.lg)
      let laneInset = ConversationLayout.laneHorizontalInset
      let contentWidth = availableWidth - laneInset * 2 - pad * 2

      switch model.mode {
        case .permission:
          var h: CGFloat = 8 + 2 + pad // cell pad + risk strip + card pad
          h += 16 // header
          h += CGFloat(Spacing.md) + 20 // tool badge

          if model.command != nil || model.filePath != nil {
            let text = model.command ?? model.filePath ?? ""
            let commandFont = UIFont.monospacedSystemFont(ofSize: TypeScale.code, weight: .regular)
            let textWidth = contentWidth - CGFloat(EdgeBar.width) - CGFloat(Spacing.md) * 2
            let textHeight = Self.measureTextHeight(text, font: commandFont, width: textWidth)
            h += CGFloat(Spacing.sm) // spacing before command container
            h += CGFloat(Spacing.sm) + textHeight + CGFloat(Spacing.sm)
          }

          if model.diff != nil { h += 120 }

          h += CGFloat(Spacing.md) + 1 // divider
          h += CGFloat(Spacing.md) + 44 // primary buttons (44pt touch targets)
          h += pad + 8 // card pad + cell pad
          return h

        case .question:
          var h: CGFloat = 8 + 2 + pad
          h += 16 // header
          h += CGFloat(Spacing.md)
          if let question = model.question {
            let qFont = UIFont.systemFont(ofSize: TypeScale.reading)
            h += Self.measureTextHeight(question, font: qFont, width: contentWidth)
          } else {
            h += 20
          }
          h += CGFloat(Spacing.md) + 36 // answer field
          h += CGFloat(Spacing.md) + 44 // submit button
          h += pad + 8
          return h

        case .takeover:
          var h: CGFloat = 8 + 2 + pad
          h += 16 // header
          h += CGFloat(Spacing.md) + 20 // tool badge
          h += CGFloat(Spacing.md) + 20 // description
          h += CGFloat(Spacing.md) + 44 // button
          h += pad + 8
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
  }

#endif
