//
//  NativeApprovalCardCellView.swift
//  OrbitDock
//
//  macOS NSTableCellView for inline approval cards in the conversation timeline.
//  Three modes: permission (tool approval), question (text input), takeover (passive session).
//

#if os(macOS)

  import AppKit
  import SwiftUI

  final class NativeApprovalCardCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeApprovalCardCell")

    // MARK: - Callbacks

    /// (decision, denyMessage, interrupt)
    var onDecision: ((String, String?, Bool?) -> Void)?
    var onAnswer: ((String) -> Void)?
    var onTakeOver: (() -> Void)?

    // MARK: - Subviews

    private let cardContainer = NSView()
    private let riskStrip = NSView()

    // Header
    private let headerIcon = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let spinnerView = NSProgressIndicator()

    // Tool badge row
    private let toolBadge = NSView()
    private let toolIcon = NSImageView()
    private let toolNameLabel = NSTextField(labelWithString: "")
    private let riskBadge = NSView()
    private let riskBadgeIcon = NSImageView()
    private let riskBadgeLabel = NSTextField(labelWithString: "DESTRUCTIVE")

    // Command preview
    private let commandContainer = NSView()
    private let commandAccentBar = NSView()
    private let commandText = NSTextField(labelWithString: "")
    private let projectPathRow = NSView()
    private let projectPathIcon = NSImageView()
    private let projectPathLabel = NSTextField(labelWithString: "")

    // Question mode
    private let questionTextLabel = NSTextField(wrappingLabelWithString: "")
    private let answerField = NSTextField()
    private let submitButton = NSButton()

    // Takeover mode
    private let takeoverDescription = NSTextField(wrappingLabelWithString: "")
    private let takeoverButton = NSButton()

    /// Diff preview
    private let diffContainer = NSView()

    // Permission buttons
    private let buttonRow = NSView()
    private let denyButton = NSButton()
    private let approveButton = NSButton()
    private let secondaryRow = NSStackView()
    private let sessionAllowButton = NSButton()
    private let alwaysAllowButton = NSButton()
    private let denyReasonButton = NSButton()
    private let denyStopButton = NSButton()

    // Deny reason panel
    private let denyReasonContainer = NSView()
    private let denyReasonField = NSTextField()
    private let sendDenialButton = NSButton()

    /// Divider
    private let actionDivider = NSView()

    private var currentModel: ApprovalCardModel?
    private var showDenyReason = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    // MARK: - Setup

    private func setup() {
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor

      cardContainer.wantsLayer = true
      cardContainer.layer?.cornerRadius = CGFloat(Radius.xl)
      cardContainer.layer?.masksToBounds = true
      cardContainer.layer?.borderWidth = 1
      cardContainer.translatesAutoresizingMaskIntoConstraints = false
      addSubview(cardContainer)

      riskStrip.wantsLayer = true
      riskStrip.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(riskStrip)

      setupHeader()
      setupToolBadge()
      setupCommandPreview()
      setupQuestionMode()
      setupTakeoverMode()
      setupPermissionButtons()
      setupDenyReasonPanel()

      let inset = ConversationLayout.laneHorizontalInset
      NSLayoutConstraint.activate([
        cardContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        cardContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        cardContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        cardContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),

        riskStrip.topAnchor.constraint(equalTo: cardContainer.topAnchor),
        riskStrip.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
        riskStrip.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
        riskStrip.heightAnchor.constraint(equalToConstant: 2),
      ])
    }

    private func setupHeader() {
      headerIcon.translatesAutoresizingMaskIntoConstraints = false
      headerIcon.imageScaling = .scaleProportionallyDown
      headerIcon.setContentHuggingPriority(.required, for: .horizontal)
      cardContainer.addSubview(headerIcon)

      headerLabel.translatesAutoresizingMaskIntoConstraints = false
      headerLabel.font = NSFont.systemFont(ofSize: TypeScale.title, weight: .semibold)
      headerLabel.textColor = NSColor(Color.textPrimary)
      headerLabel.lineBreakMode = .byTruncatingTail
      headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
      cardContainer.addSubview(headerLabel)

      spinnerView.translatesAutoresizingMaskIntoConstraints = false
      spinnerView.style = .spinning
      spinnerView.controlSize = .small
      spinnerView.isHidden = true
      cardContainer.addSubview(spinnerView)

      let pad = CGFloat(Spacing.lg)
      NSLayoutConstraint.activate([
        headerIcon.topAnchor.constraint(equalTo: riskStrip.bottomAnchor, constant: pad),
        headerIcon.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        headerIcon.widthAnchor.constraint(equalToConstant: 16),
        headerIcon.heightAnchor.constraint(equalToConstant: 16),

        headerLabel.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: CGFloat(Spacing.sm)),
        headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinnerView.leadingAnchor, constant: -8),

        spinnerView.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        spinnerView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
      ])
    }

    private func setupToolBadge() {
      toolBadge.wantsLayer = true
      toolBadge.layer?.cornerRadius = 10
      toolBadge.layer?.backgroundColor = NSColor(Color.backgroundTertiary).cgColor
      toolBadge.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(toolBadge)

      toolIcon.translatesAutoresizingMaskIntoConstraints = false
      toolIcon.imageScaling = .scaleProportionallyDown
      toolBadge.addSubview(toolIcon)

      toolNameLabel.translatesAutoresizingMaskIntoConstraints = false
      toolNameLabel.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .bold)
      toolNameLabel.textColor = NSColor(Color.textSecondary)
      toolBadge.addSubview(toolNameLabel)

      riskBadge.wantsLayer = true
      riskBadge.layer?.cornerRadius = 8
      riskBadge.layer?.backgroundColor = NSColor(Color.statusError).cgColor
      riskBadge.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(riskBadge)

      riskBadgeIcon.translatesAutoresizingMaskIntoConstraints = false
      riskBadgeIcon.imageScaling = .scaleProportionallyDown
      riskBadge.addSubview(riskBadgeIcon)

      riskBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
      riskBadgeLabel.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .black)
      riskBadgeLabel.textColor = .white
      riskBadge.addSubview(riskBadgeLabel)

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

        riskBadge.leadingAnchor.constraint(equalTo: toolBadge.trailingAnchor, constant: CGFloat(Spacing.sm)),
        riskBadge.centerYAnchor.constraint(equalTo: toolBadge.centerYAnchor),

        riskBadgeIcon.leadingAnchor.constraint(equalTo: riskBadge.leadingAnchor, constant: CGFloat(Spacing.sm)),
        riskBadgeIcon.centerYAnchor.constraint(equalTo: riskBadge.centerYAnchor),
        riskBadgeIcon.widthAnchor.constraint(equalToConstant: 10),
        riskBadgeIcon.heightAnchor.constraint(equalToConstant: 10),

        riskBadgeLabel.leadingAnchor.constraint(equalTo: riskBadgeIcon.trailingAnchor, constant: 3),
        riskBadgeLabel.trailingAnchor.constraint(equalTo: riskBadge.trailingAnchor, constant: -CGFloat(Spacing.sm)),
        riskBadgeLabel.topAnchor.constraint(equalTo: riskBadge.topAnchor, constant: 2),
        riskBadgeLabel.bottomAnchor.constraint(equalTo: riskBadge.bottomAnchor, constant: -2),
      ])
    }

    private func setupCommandPreview() {
      commandContainer.wantsLayer = true
      commandContainer.layer?.cornerRadius = CGFloat(Radius.md)
      commandContainer.layer?.backgroundColor = NSColor(Color.backgroundPrimary).cgColor
      commandContainer.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(commandContainer)

      commandAccentBar.wantsLayer = true
      commandAccentBar.translatesAutoresizingMaskIntoConstraints = false
      commandContainer.addSubview(commandAccentBar)

      commandText.translatesAutoresizingMaskIntoConstraints = false
      commandText.font = NSFont.monospacedSystemFont(ofSize: TypeScale.code, weight: .regular)
      commandText.textColor = NSColor(Color.textPrimary)
      commandText.lineBreakMode = .byTruncatingTail
      commandText.maximumNumberOfLines = 3
      commandText.isSelectable = true
      commandContainer.addSubview(commandText)

      projectPathRow.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(projectPathRow)

      projectPathIcon.translatesAutoresizingMaskIntoConstraints = false
      projectPathIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
      projectPathIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.micro, weight: .regular)
      projectPathIcon.contentTintColor = NSColor(Color.textQuaternary)
      projectPathRow.addSubview(projectPathIcon)

      projectPathLabel.translatesAutoresizingMaskIntoConstraints = false
      projectPathLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .regular)
      projectPathLabel.textColor = NSColor(Color.textTertiary)
      projectPathLabel.lineBreakMode = .byTruncatingMiddle
      projectPathRow.addSubview(projectPathLabel)

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

        projectPathRow.topAnchor.constraint(equalTo: commandContainer.bottomAnchor, constant: CGFloat(Spacing.sm)),
        projectPathRow.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        projectPathRow.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        projectPathIcon.leadingAnchor.constraint(equalTo: projectPathRow.leadingAnchor),
        projectPathIcon.centerYAnchor.constraint(equalTo: projectPathRow.centerYAnchor),
        projectPathIcon.widthAnchor.constraint(equalToConstant: 12),
        projectPathIcon.heightAnchor.constraint(equalToConstant: 12),

        projectPathLabel.leadingAnchor.constraint(
          equalTo: projectPathIcon.trailingAnchor,
          constant: CGFloat(Spacing.xs)
        ),
        projectPathLabel.trailingAnchor.constraint(equalTo: projectPathRow.trailingAnchor),
        projectPathLabel.topAnchor.constraint(equalTo: projectPathRow.topAnchor),
        projectPathLabel.bottomAnchor.constraint(equalTo: projectPathRow.bottomAnchor),
      ])
    }

    private func setupQuestionMode() {
      questionTextLabel.translatesAutoresizingMaskIntoConstraints = false
      questionTextLabel.font = NSFont.systemFont(ofSize: TypeScale.reading, weight: .regular)
      questionTextLabel.textColor = NSColor(Color.textPrimary)
      questionTextLabel.maximumNumberOfLines = 0
      questionTextLabel.preferredMaxLayoutWidth = 600
      cardContainer.addSubview(questionTextLabel)

      answerField.translatesAutoresizingMaskIntoConstraints = false
      answerField.placeholderString = "Your answer..."
      answerField.font = NSFont.systemFont(ofSize: TypeScale.code)
      answerField.textColor = NSColor(Color.textPrimary)
      answerField.backgroundColor = NSColor(Color.backgroundPrimary)
      answerField.isBordered = true
      answerField.bezelStyle = .roundedBezel
      answerField.target = self
      answerField.action = #selector(answerFieldSubmitted)
      cardContainer.addSubview(answerField)

      submitButton.translatesAutoresizingMaskIntoConstraints = false
      submitButton.title = "Submit"
      submitButton.bezelStyle = .rounded
      submitButton.font = NSFont.systemFont(ofSize: TypeScale.code, weight: .semibold)
      submitButton.contentTintColor = .white
      submitButton.wantsLayer = true
      submitButton.layer?.cornerRadius = CGFloat(Radius.lg)
      submitButton.layer?.backgroundColor = NSColor(Color.statusQuestion).withAlphaComponent(0.75).cgColor
      submitButton.target = self
      submitButton.action = #selector(submitButtonClicked)
      cardContainer.addSubview(submitButton)

      let pad = CGFloat(Spacing.lg)
      NSLayoutConstraint.activate([
        questionTextLabel.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: CGFloat(Spacing.md)),
        questionTextLabel.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        questionTextLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        answerField.topAnchor.constraint(equalTo: questionTextLabel.bottomAnchor, constant: CGFloat(Spacing.md)),
        answerField.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        answerField.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        answerField.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

        submitButton.topAnchor.constraint(equalTo: answerField.bottomAnchor, constant: CGFloat(Spacing.md)),
        submitButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        submitButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        submitButton.heightAnchor.constraint(equalToConstant: 30),
      ])
    }

    private func setupTakeoverMode() {
      takeoverDescription.translatesAutoresizingMaskIntoConstraints = false
      takeoverDescription.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .regular)
      takeoverDescription.textColor = NSColor(Color.textTertiary)
      takeoverDescription.maximumNumberOfLines = 0
      cardContainer.addSubview(takeoverDescription)

      takeoverButton.translatesAutoresizingMaskIntoConstraints = false
      takeoverButton.title = "Take Over & Review"
      takeoverButton.bezelStyle = .rounded
      takeoverButton.font = NSFont.systemFont(ofSize: TypeScale.code, weight: .semibold)
      takeoverButton.contentTintColor = .white
      takeoverButton.wantsLayer = true
      takeoverButton.layer?.cornerRadius = CGFloat(Radius.lg)
      takeoverButton.target = self
      takeoverButton.action = #selector(takeoverButtonClicked)
      cardContainer.addSubview(takeoverButton)

      let pad = CGFloat(Spacing.lg)
      NSLayoutConstraint.activate([
        takeoverDescription.topAnchor.constraint(equalTo: toolBadge.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverDescription.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverDescription.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        takeoverButton.topAnchor.constraint(equalTo: takeoverDescription.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        takeoverButton.heightAnchor.constraint(equalToConstant: 32),
      ])
    }

    private func setupPermissionButtons() {
      actionDivider.wantsLayer = true
      actionDivider.layer?.backgroundColor = NSColor(Color.textQuaternary).withAlphaComponent(0.3).cgColor
      actionDivider.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(actionDivider)

      buttonRow.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(buttonRow)

      denyButton.translatesAutoresizingMaskIntoConstraints = false
      denyButton.title = "  Deny  n"
      denyButton.bezelStyle = .rounded
      denyButton.font = NSFont.systemFont(ofSize: TypeScale.code, weight: .semibold)
      denyButton.contentTintColor = NSColor(Color.statusError)
      denyButton.wantsLayer = true
      denyButton.layer?.cornerRadius = CGFloat(Radius.lg)
      denyButton.layer?.backgroundColor = NSColor(Color.statusError).withAlphaComponent(CGFloat(OpacityTier.light))
        .cgColor
      denyButton.target = self
      denyButton.action = #selector(denyButtonClicked)
      buttonRow.addSubview(denyButton)

      approveButton.translatesAutoresizingMaskIntoConstraints = false
      approveButton.title = "  Approve  y"
      approveButton.bezelStyle = .rounded
      approveButton.font = NSFont.systemFont(ofSize: TypeScale.code, weight: .semibold)
      approveButton.contentTintColor = .white
      approveButton.wantsLayer = true
      approveButton.layer?.cornerRadius = CGFloat(Radius.lg)
      approveButton.layer?.backgroundColor = NSColor(Color.accent).withAlphaComponent(0.75).cgColor
      approveButton.target = self
      approveButton.action = #selector(approveButtonClicked)
      buttonRow.addSubview(approveButton)

      // Secondary actions row
      secondaryRow.translatesAutoresizingMaskIntoConstraints = false
      secondaryRow.orientation = .horizontal
      secondaryRow.spacing = CGFloat(Spacing.md)
      secondaryRow.alignment = .centerY
      cardContainer.addSubview(secondaryRow)

      sessionAllowButton.translatesAutoresizingMaskIntoConstraints = false
      sessionAllowButton.title = "Allow Session Y"
      sessionAllowButton.isBordered = false
      sessionAllowButton.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      sessionAllowButton.contentTintColor = NSColor(Color.textSecondary)
      sessionAllowButton.target = self
      sessionAllowButton.action = #selector(sessionAllowClicked)
      secondaryRow.addArrangedSubview(sessionAllowButton)

      alwaysAllowButton.translatesAutoresizingMaskIntoConstraints = false
      alwaysAllowButton.title = "Always !"
      alwaysAllowButton.isBordered = false
      alwaysAllowButton.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      alwaysAllowButton.contentTintColor = NSColor(Color.accent)
      alwaysAllowButton.target = self
      alwaysAllowButton.action = #selector(alwaysAllowClicked)
      secondaryRow.addArrangedSubview(alwaysAllowButton)

      denyReasonButton.translatesAutoresizingMaskIntoConstraints = false
      denyReasonButton.title = "Deny+Reason d"
      denyReasonButton.isBordered = false
      denyReasonButton.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      denyReasonButton.contentTintColor = NSColor(Color.statusError).withAlphaComponent(0.8)
      denyReasonButton.target = self
      denyReasonButton.action = #selector(denyReasonClicked)
      secondaryRow.addArrangedSubview(denyReasonButton)

      let spacer = NSView()
      spacer.translatesAutoresizingMaskIntoConstraints = false
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      secondaryRow.addArrangedSubview(spacer)

      denyStopButton.translatesAutoresizingMaskIntoConstraints = false
      denyStopButton.title = "Deny & Stop N"
      denyStopButton.isBordered = false
      denyStopButton.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      denyStopButton.contentTintColor = NSColor(Color.statusError).withAlphaComponent(0.8)
      denyStopButton.target = self
      denyStopButton.action = #selector(denyStopClicked)
      secondaryRow.addArrangedSubview(denyStopButton)

      let pad = CGFloat(Spacing.lg)
      NSLayoutConstraint.activate([
        actionDivider.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        actionDivider.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        actionDivider.heightAnchor.constraint(equalToConstant: 1),

        buttonRow.topAnchor.constraint(equalTo: actionDivider.bottomAnchor, constant: CGFloat(Spacing.md)),
        buttonRow.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        buttonRow.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        buttonRow.heightAnchor.constraint(equalToConstant: 30),

        denyButton.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor),
        denyButton.topAnchor.constraint(equalTo: buttonRow.topAnchor),
        denyButton.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
        denyButton.widthAnchor.constraint(equalTo: buttonRow.widthAnchor, multiplier: 0.48),

        approveButton.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
        approveButton.topAnchor.constraint(equalTo: buttonRow.topAnchor),
        approveButton.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
        approveButton.widthAnchor.constraint(equalTo: buttonRow.widthAnchor, multiplier: 0.48),

        secondaryRow.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: CGFloat(Spacing.sm)),
        secondaryRow.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        secondaryRow.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
      ])
    }

    private func setupDenyReasonPanel() {
      denyReasonContainer.wantsLayer = true
      denyReasonContainer.layer?.cornerRadius = CGFloat(Radius.md)
      denyReasonContainer.layer?.backgroundColor = NSColor(Color.backgroundPrimary).withAlphaComponent(0.5).cgColor
      denyReasonContainer.translatesAutoresizingMaskIntoConstraints = false
      denyReasonContainer.isHidden = true
      cardContainer.addSubview(denyReasonContainer)

      denyReasonField.translatesAutoresizingMaskIntoConstraints = false
      denyReasonField.placeholderString = "Reason for denial..."
      denyReasonField.font = NSFont.systemFont(ofSize: TypeScale.code)
      denyReasonField.textColor = NSColor(Color.textPrimary)
      denyReasonField.backgroundColor = NSColor(Color.backgroundPrimary)
      denyReasonField.isBordered = true
      denyReasonField.bezelStyle = .roundedBezel
      denyReasonContainer.addSubview(denyReasonField)

      sendDenialButton.translatesAutoresizingMaskIntoConstraints = false
      sendDenialButton.title = "Send Denial"
      sendDenialButton.bezelStyle = .rounded
      sendDenialButton.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
      sendDenialButton.contentTintColor = .white
      sendDenialButton.wantsLayer = true
      sendDenialButton.layer?.cornerRadius = 10
      sendDenialButton.layer?.backgroundColor = NSColor(Color.statusError).withAlphaComponent(0.75).cgColor
      sendDenialButton.target = self
      sendDenialButton.action = #selector(sendDenialClicked)
      denyReasonContainer.addSubview(sendDenialButton)

      let pad = CGFloat(Spacing.sm)
      NSLayoutConstraint.activate([
        denyReasonContainer.topAnchor.constraint(equalTo: secondaryRow.bottomAnchor, constant: CGFloat(Spacing.sm)),
        denyReasonContainer.leadingAnchor.constraint(
          equalTo: cardContainer.leadingAnchor,
          constant: CGFloat(Spacing.lg)
        ),
        denyReasonContainer.trailingAnchor.constraint(
          equalTo: cardContainer.trailingAnchor,
          constant: -CGFloat(Spacing.lg)
        ),

        denyReasonField.topAnchor.constraint(equalTo: denyReasonContainer.topAnchor, constant: pad),
        denyReasonField.leadingAnchor.constraint(equalTo: denyReasonContainer.leadingAnchor, constant: pad),
        denyReasonField.trailingAnchor.constraint(equalTo: denyReasonContainer.trailingAnchor, constant: -pad),

        sendDenialButton.topAnchor.constraint(equalTo: denyReasonField.bottomAnchor, constant: pad),
        sendDenialButton.trailingAnchor.constraint(equalTo: denyReasonContainer.trailingAnchor, constant: -pad),
        sendDenialButton.bottomAnchor.constraint(equalTo: denyReasonContainer.bottomAnchor, constant: -pad),
        sendDenialButton.heightAnchor.constraint(equalToConstant: 24),
      ])
    }

    // MARK: - Configure

    func configure(model: ApprovalCardModel) {
      currentModel = model
      showDenyReason = false
      denyReasonContainer.isHidden = true
      denyReasonField.stringValue = ""

      let tint = NSColor(model.risk.tintColor)
      riskStrip.layer?.backgroundColor = tint.cgColor
      cardContainer.layer?.backgroundColor = tint.withAlphaComponent(CGFloat(model.risk.tintOpacity)).cgColor
      cardContainer.layer?.borderColor = tint.withAlphaComponent(CGFloat(OpacityTier.medium)).cgColor

      switch model.mode {
        case .permission:
          configurePermissionMode(model)
        case .question:
          configureQuestionMode(model)
        case .takeover:
          configureTakeoverMode(model)
        case .none:
          break
      }
    }

    private func configurePermissionMode(_ model: ApprovalCardModel) {
      // Show permission views
      toolBadge.isHidden = false
      commandContainer.isHidden = model.command == nil && model.filePath == nil
      projectPathRow.isHidden = model.command == nil
      actionDivider.isHidden = false
      buttonRow.isHidden = false
      secondaryRow.isHidden = false
      riskBadge.isHidden = model.risk != .high

      // Hide other modes
      questionTextLabel.isHidden = true
      answerField.isHidden = true
      submitButton.isHidden = true
      takeoverDescription.isHidden = true
      takeoverButton.isHidden = true

      // Header
      let iconName = model.risk == .high ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
      headerIcon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
      headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.subhead, weight: .semibold)
      headerIcon.contentTintColor = NSColor(model.risk.tintColor)
      headerLabel.stringValue = "Permission Required"

      // Tool badge
      if let toolName = model.toolName {
        toolIcon.image = NSImage(systemSymbolName: ToolCardStyle.icon(for: toolName), accessibilityDescription: nil)
        toolIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.caption, weight: .regular)
        toolIcon.contentTintColor = NSColor(Color.textSecondary)
        toolNameLabel.stringValue = toolName
      }

      // Risk badge
      if model.risk == .high {
        riskBadgeIcon.image = NSImage(
          systemSymbolName: "bolt.trianglebadge.exclamationmark.fill",
          accessibilityDescription: nil
        )
        riskBadgeIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.micro, weight: .regular)
        riskBadgeIcon.contentTintColor = .white
        riskBadgeLabel.stringValue = "DESTRUCTIVE"
      }

      // Command preview
      if let command = model.command {
        commandText.stringValue = command
        commandAccentBar.layer?.backgroundColor = NSColor(model.risk.tintColor).cgColor
        projectPathLabel.stringValue = model.projectPath
        commandContainer.isHidden = false
        projectPathRow.isHidden = false
      } else if let filePath = model.filePath {
        let toolNameLower = (model.toolName ?? "").lowercased()
        let icon = toolNameLower == "edit" ? "pencil" : "doc.badge.plus"
        commandText.stringValue = filePath
        commandAccentBar.layer?.backgroundColor = NSColor(model.risk.tintColor).cgColor

        // Re-use project path icon for file icon
        projectPathIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        commandContainer.isHidden = false
        projectPathRow.isHidden = true
      } else {
        commandContainer.isHidden = true
        projectPathRow.isHidden = true
      }

      // Always allow only for exec with amendment
      alwaysAllowButton.isHidden = !(model.approvalType == .exec && model.hasAmendment)

      // Position divider after last visible content
      updateActionDividerPosition(model)
    }

    private func configureQuestionMode(_ model: ApprovalCardModel) {
      let tint = NSColor(Color.statusQuestion)
      riskStrip.layer?.backgroundColor = tint.cgColor
      cardContainer.layer?.backgroundColor = tint.withAlphaComponent(CGFloat(OpacityTier.light)).cgColor
      cardContainer.layer?.borderColor = tint.withAlphaComponent(CGFloat(OpacityTier.medium)).cgColor

      // Show question views
      questionTextLabel.isHidden = false
      answerField.isHidden = false
      submitButton.isHidden = false

      // Hide other modes
      toolBadge.isHidden = true
      commandContainer.isHidden = true
      projectPathRow.isHidden = true
      actionDivider.isHidden = true
      buttonRow.isHidden = true
      secondaryRow.isHidden = true
      riskBadge.isHidden = true
      takeoverDescription.isHidden = true
      takeoverButton.isHidden = true

      // Header
      headerIcon.image = NSImage(systemSymbolName: "questionmark.bubble.fill", accessibilityDescription: nil)
      headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.subhead, weight: .semibold)
      headerIcon.contentTintColor = tint
      headerLabel.stringValue = "Question"

      questionTextLabel.stringValue = model.question ?? ""
      answerField.stringValue = ""
    }

    private func configureTakeoverMode(_ model: ApprovalCardModel) {
      let isPermission = model.approvalType != .question
      let tint = isPermission ? NSColor(Color.statusPermission) : NSColor(Color.statusQuestion)

      riskStrip.layer?.backgroundColor = tint.cgColor
      cardContainer.layer?.backgroundColor = tint.withAlphaComponent(CGFloat(OpacityTier.light)).cgColor
      cardContainer.layer?.borderColor = tint.withAlphaComponent(CGFloat(OpacityTier.medium)).cgColor

      // Show takeover views
      takeoverDescription.isHidden = false
      takeoverButton.isHidden = false

      // Show tool badge if permission
      toolBadge.isHidden = model.toolName == nil
      if let toolName = model.toolName {
        toolIcon.image = NSImage(systemSymbolName: ToolCardStyle.icon(for: toolName), accessibilityDescription: nil)
        toolIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.caption, weight: .regular)
        toolIcon.contentTintColor = NSColor(Color.textSecondary)
        toolNameLabel.stringValue = toolName
      }

      // Hide other modes
      commandContainer.isHidden = true
      projectPathRow.isHidden = true
      actionDivider.isHidden = true
      buttonRow.isHidden = true
      secondaryRow.isHidden = true
      riskBadge.isHidden = true
      questionTextLabel.isHidden = true
      answerField.isHidden = true
      submitButton.isHidden = true

      // Header
      let iconName = isPermission ? "lock.fill" : "questionmark.bubble.fill"
      headerIcon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
      headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.subhead, weight: .semibold)
      headerIcon.contentTintColor = tint
      headerLabel.stringValue = isPermission ? "Permission Required" : "Question Pending"

      takeoverDescription.stringValue = "Take over this session to respond."
      takeoverButton.title = isPermission ? "Take Over & Review" : "Take Over & Answer"
      takeoverButton.layer?.backgroundColor = tint.withAlphaComponent(0.75).cgColor
    }

    private func updateActionDividerPosition(_ model: ApprovalCardModel) {
      // Remove existing position constraints for divider if any
      for constraint in cardContainer.constraints where constraint.firstItem === actionDivider
        && constraint.firstAttribute == .top
      {
        constraint.isActive = false
      }

      let anchor: NSView = if !commandContainer.isHidden {
        model.command != nil ? projectPathRow : commandContainer
      } else {
        toolBadge
      }

      actionDivider.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: CGFloat(Spacing.md)).isActive = true
    }

    // MARK: - Keyboard Shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard let model = currentModel, model.mode == .permission else {
        return super.performKeyEquivalent(with: event)
      }
      guard let chars = event.characters, !chars.isEmpty else {
        return super.performKeyEquivalent(with: event)
      }

      let char = chars.first!
      let shift = event.modifierFlags.contains(.shift)

      if char == "y", !shift {
        onDecision?("approved", nil, nil)
        return true
      } else if char == "Y" || (char == "y" && shift) {
        onDecision?("approved_for_session", nil, nil)
        return true
      } else if char == "!", model.hasAmendment {
        onDecision?("approved_always", nil, nil)
        return true
      } else if char == "n", !shift {
        onDecision?("denied", nil, nil)
        return true
      } else if char == "N" || (char == "n" && shift) {
        onDecision?("abort", nil, nil)
        return true
      } else if char == "d", !shift {
        showDenyReason.toggle()
        denyReasonContainer.isHidden = !showDenyReason
        if showDenyReason { window?.makeFirstResponder(denyReasonField) }
        return true
      }
      return super.performKeyEquivalent(with: event)
    }

    // MARK: - Actions

    @objc private func approveButtonClicked() {
      onDecision?("approved", nil, nil)
    }

    @objc private func denyButtonClicked() {
      onDecision?("denied", nil, nil)
    }

    @objc private func sessionAllowClicked() {
      onDecision?("approved_for_session", nil, nil)
    }

    @objc private func alwaysAllowClicked() {
      onDecision?("approved_always", nil, nil)
    }

    @objc private func denyReasonClicked() {
      showDenyReason.toggle()
      denyReasonContainer.isHidden = !showDenyReason
      if showDenyReason {
        window?.makeFirstResponder(denyReasonField)
      }
    }

    @objc private func denyStopClicked() {
      onDecision?("abort", nil, nil)
    }

    @objc private func sendDenialClicked() {
      let message = denyReasonField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !message.isEmpty else { return }
      onDecision?("denied", message, nil)
      denyReasonField.stringValue = ""
      showDenyReason = false
      denyReasonContainer.isHidden = true
    }

    @objc private func answerFieldSubmitted() {
      let answer = answerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !answer.isEmpty else { return }
      onAnswer?(answer)
      answerField.stringValue = ""
    }

    @objc private func submitButtonClicked() {
      answerFieldSubmitted()
    }

    @objc private func takeoverButtonClicked() {
      onTakeOver?()
    }

    // MARK: - Height Calculation

    static func requiredHeight(for mode: ApprovalCardMode, hasCommand: Bool, hasDiff: Bool) -> CGFloat {
      switch mode {
        case .permission:
          var h: CGFloat = 16 // top padding + risk strip
          h += 16 + 16 // header row
          h += 12 + 20 // tool badge
          if hasCommand {
            h += 8 + 36 // command preview
            h += 8 + 14 // project path
          }
          if hasDiff { h += 120 } // inline diff preview
          h += 12 + 1 // divider
          h += 12 + 30 // primary buttons
          h += 8 + 16 // secondary row
          h += 16 // bottom padding
          return h
        case .question:
          return 200 // header + question text + answer field + submit button + padding
        case .takeover:
          return 160 // header + tool badge + description + button + padding
        case .none:
          return 1
      }
    }
  }

#endif
