//
//  NativeApprovalCardCellView.swift
//  OrbitDock
//
//  macOS NSTableCellView for inline approval cards in the conversation timeline.
//  Three modes: permission (tool approval), question (options or text input), takeover (passive session).
//

#if os(macOS)

  import AppKit
  import SwiftUI

  final class NativeApprovalCardCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeApprovalCardCell")

    // MARK: - Callbacks

    /// (decision, denyMessage, interrupt)
    var onDecision: ((String, String?, Bool?) -> Void)?
    var onAnswer: (([String: [String]]) -> Void)?
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
    private let riskBadgeLabel = NSTextField(labelWithString: "HIGH RISK")

    // Command preview
    private let commandContainer = NSView()
    private let commandAccentBar = NSView()
    private let commandTextScrollView = NSScrollView()
    private let commandText = NSTextView()
    private let projectPathRow = NSView()
    private let projectPathIcon = NSImageView()
    private let projectPathLabel = NSTextField(labelWithString: "")

    // Question mode
    private let questionTextLabel = NSTextField(wrappingLabelWithString: "")
    private let questionOptionsStack = NSStackView()
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
    private var commandTextHeightConstraint: NSLayoutConstraint?
    private var commandPreviewTextForSizing: String?
    private var questionOptionsTopConstraint: NSLayoutConstraint?
    private var selectedQuestionAnswers: [String: [String]] = [:]
    private var questionTextFields: [String: NSTextField] = [:]
    private var questionOptionButtons: [String: [NSButton]] = [:]
    private var questionOptionPayloads: [ObjectIdentifier: (questionId: String, optionLabel: String)] = [:]

    private enum Layout {
      static let outerVerticalInset: CGFloat = 6
      static let cardPadding: CGFloat = 12
      static let headerIconSize: CGFloat = 14
      static let commandVerticalPadding: CGFloat = 6
      static let commandHorizontalPadding: CGFloat = 10
      static let minCommandTextHeight: CGFloat = 22
      static let maxCommandTextHeight: CGFloat = 220
      static let primaryButtonHeight: CGFloat = 32
      static let secondaryRowHeight: CGFloat = 18
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    override func layout() {
      super.layout()
      refreshCommandPreviewHeight()
    }

    // MARK: - Setup

    private func setup() {
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor

      cardContainer.wantsLayer = true
      cardContainer.layer?.cornerRadius = CGFloat(Radius.lg)
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
        cardContainer.topAnchor.constraint(equalTo: topAnchor, constant: Layout.outerVerticalInset),
        cardContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        cardContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        cardContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.outerVerticalInset),

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
      headerLabel.font = NSFont.systemFont(ofSize: TypeScale.subhead, weight: .semibold)
      headerLabel.textColor = NSColor(Color.textPrimary)
      headerLabel.lineBreakMode = .byTruncatingTail
      headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
      cardContainer.addSubview(headerLabel)

      spinnerView.translatesAutoresizingMaskIntoConstraints = false
      spinnerView.style = .spinning
      spinnerView.controlSize = .small
      spinnerView.isHidden = true
      cardContainer.addSubview(spinnerView)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        headerIcon.topAnchor.constraint(equalTo: riskStrip.bottomAnchor, constant: pad),
        headerIcon.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        headerIcon.widthAnchor.constraint(equalToConstant: Layout.headerIconSize),
        headerIcon.heightAnchor.constraint(equalToConstant: Layout.headerIconSize),

        headerLabel.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: CGFloat(Spacing.sm)),
        headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinnerView.leadingAnchor, constant: -8),

        spinnerView.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        spinnerView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
      ])
    }

    private func setupToolBadge() {
      toolBadge.wantsLayer = true
      toolBadge.layer?.cornerRadius = 9
      toolBadge.layer?.backgroundColor = NSColor(Color.backgroundTertiary).cgColor
      toolBadge.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(toolBadge)

      toolIcon.translatesAutoresizingMaskIntoConstraints = false
      toolIcon.imageScaling = .scaleProportionallyDown
      toolBadge.addSubview(toolIcon)

      toolNameLabel.translatesAutoresizingMaskIntoConstraints = false
      toolNameLabel.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
      toolNameLabel.textColor = NSColor(Color.textSecondary)
      toolBadge.addSubview(toolNameLabel)

      riskBadge.wantsLayer = true
      riskBadge.layer?.cornerRadius = 7
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

      commandTextScrollView.translatesAutoresizingMaskIntoConstraints = false
      commandTextScrollView.drawsBackground = false
      commandTextScrollView.borderType = .noBorder
      commandTextScrollView.hasVerticalScroller = false
      commandTextScrollView.hasHorizontalScroller = false
      commandTextScrollView.autohidesScrollers = true
      commandTextScrollView.scrollerStyle = .overlay
      commandTextScrollView.verticalScrollElasticity = .automatic
      commandTextScrollView.horizontalScrollElasticity = .none
      commandContainer.addSubview(commandTextScrollView)

      commandText.translatesAutoresizingMaskIntoConstraints = true
      commandText.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      commandText.textColor = NSColor(Color.textPrimary)
      commandText.drawsBackground = false
      commandText.isEditable = false
      commandText.isSelectable = true
      commandText.isRichText = false
      commandText.isHorizontallyResizable = false
      commandText.isVerticallyResizable = true
      commandText.minSize = NSSize(width: 0, height: 0)
      commandText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      commandText.autoresizingMask = [.width]
      commandText.textContainerInset = .zero
      commandText.textContainer?.lineFragmentPadding = 0
      commandText.textContainer?.widthTracksTextView = true
      commandText.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
      commandTextScrollView.documentView = commandText

      projectPathRow.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(projectPathRow)

      projectPathIcon.translatesAutoresizingMaskIntoConstraints = false
      projectPathIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
      projectPathIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.micro, weight: .regular)
      projectPathIcon.contentTintColor = NSColor(Color.textQuaternary)
      projectPathRow.addSubview(projectPathIcon)

      projectPathLabel.translatesAutoresizingMaskIntoConstraints = false
      projectPathLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
      projectPathLabel.textColor = NSColor(Color.textTertiary)
      projectPathLabel.lineBreakMode = .byTruncatingMiddle
      projectPathRow.addSubview(projectPathLabel)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        commandContainer.topAnchor.constraint(equalTo: toolBadge.bottomAnchor, constant: CGFloat(Spacing.sm)),
        commandContainer.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        commandContainer.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        commandAccentBar.topAnchor.constraint(equalTo: commandContainer.topAnchor),
        commandAccentBar.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor),
        commandAccentBar.leadingAnchor.constraint(equalTo: commandContainer.leadingAnchor),
        commandAccentBar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        commandTextScrollView.topAnchor.constraint(
          equalTo: commandContainer.topAnchor,
          constant: Layout.commandVerticalPadding
        ),
        commandTextScrollView.bottomAnchor.constraint(
          equalTo: commandContainer.bottomAnchor,
          constant: -Layout.commandVerticalPadding
        ),
        commandTextScrollView.leadingAnchor.constraint(
          equalTo: commandAccentBar.trailingAnchor,
          constant: Layout.commandHorizontalPadding
        ),
        commandTextScrollView.trailingAnchor.constraint(
          equalTo: commandContainer.trailingAnchor,
          constant: -Layout.commandHorizontalPadding
        ),

        projectPathRow.topAnchor.constraint(
          equalTo: commandContainer.bottomAnchor,
          constant: Layout.commandVerticalPadding
        ),
        projectPathRow.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        projectPathRow.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        projectPathIcon.leadingAnchor.constraint(equalTo: projectPathRow.leadingAnchor),
        projectPathIcon.centerYAnchor.constraint(equalTo: projectPathRow.centerYAnchor),
        projectPathIcon.widthAnchor.constraint(equalToConstant: 11),
        projectPathIcon.heightAnchor.constraint(equalToConstant: 11),

        projectPathLabel.leadingAnchor.constraint(
          equalTo: projectPathIcon.trailingAnchor,
          constant: CGFloat(Spacing.xs)
        ),
        projectPathLabel.trailingAnchor.constraint(equalTo: projectPathRow.trailingAnchor),
        projectPathLabel.topAnchor.constraint(equalTo: projectPathRow.topAnchor),
        projectPathLabel.bottomAnchor.constraint(equalTo: projectPathRow.bottomAnchor),
      ])

      commandTextHeightConstraint = commandTextScrollView.heightAnchor.constraint(
        equalToConstant: Layout.minCommandTextHeight
      )
      commandTextHeightConstraint?.isActive = true
    }

    private func setupQuestionMode() {
      questionTextLabel.translatesAutoresizingMaskIntoConstraints = false
      questionTextLabel.font = NSFont.systemFont(ofSize: TypeScale.reading, weight: .regular)
      questionTextLabel.textColor = NSColor(Color.textPrimary)
      questionTextLabel.maximumNumberOfLines = 0
      questionTextLabel.preferredMaxLayoutWidth = 600
      cardContainer.addSubview(questionTextLabel)

      questionOptionsStack.translatesAutoresizingMaskIntoConstraints = false
      questionOptionsStack.orientation = .vertical
      questionOptionsStack.spacing = CGFloat(Spacing.xs)
      questionOptionsStack.alignment = .width
      questionOptionsStack.distribution = .fill
      questionOptionsStack.detachesHiddenViews = true
      questionOptionsStack.isHidden = true
      cardContainer.addSubview(questionOptionsStack)

      answerField.translatesAutoresizingMaskIntoConstraints = false
      answerField.placeholderString = "Your answer..."
      answerField.font = NSFont.systemFont(ofSize: TypeScale.body)
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
      submitButton.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      submitButton.contentTintColor = .white
      submitButton.wantsLayer = true
      submitButton.layer?.cornerRadius = CGFloat(Radius.lg)
      submitButton.layer?.backgroundColor = NSColor(Color.statusQuestion).withAlphaComponent(0.75).cgColor
      submitButton.target = self
      submitButton.action = #selector(submitButtonClicked)
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
        answerField.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),

        submitButton.topAnchor.constraint(equalTo: answerField.bottomAnchor, constant: CGFloat(Spacing.md)),
        submitButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        submitButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        submitButton.heightAnchor.constraint(equalToConstant: 28),
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
      takeoverButton.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      takeoverButton.contentTintColor = .white
      takeoverButton.wantsLayer = true
      takeoverButton.layer?.cornerRadius = CGFloat(Radius.lg)
      takeoverButton.target = self
      takeoverButton.action = #selector(takeoverButtonClicked)
      cardContainer.addSubview(takeoverButton)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        takeoverDescription.topAnchor.constraint(equalTo: toolBadge.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverDescription.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverDescription.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        takeoverButton.topAnchor.constraint(equalTo: takeoverDescription.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        takeoverButton.heightAnchor.constraint(equalToConstant: 30),
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
      denyButton.title = "Deny"
      denyButton.bezelStyle = .rounded
      denyButton.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      denyButton.contentTintColor = NSColor(Color.statusError)
      denyButton.wantsLayer = true
      denyButton.layer?.cornerRadius = CGFloat(Radius.md)
      denyButton.layer?.backgroundColor = NSColor(Color.statusError).withAlphaComponent(CGFloat(OpacityTier.light))
        .cgColor
      denyButton.target = self
      denyButton.action = #selector(denyButtonClicked)
      buttonRow.addSubview(denyButton)

      approveButton.translatesAutoresizingMaskIntoConstraints = false
      approveButton.title = "Approve Once"
      approveButton.bezelStyle = .rounded
      approveButton.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      approveButton.contentTintColor = .white
      approveButton.wantsLayer = true
      approveButton.layer?.cornerRadius = CGFloat(Radius.md)
      approveButton.layer?.backgroundColor = NSColor(Color.accent).withAlphaComponent(0.75).cgColor
      approveButton.target = self
      approveButton.action = #selector(approveButtonClicked)
      buttonRow.addSubview(approveButton)

      // Secondary actions row
      secondaryRow.translatesAutoresizingMaskIntoConstraints = false
      secondaryRow.orientation = .horizontal
      secondaryRow.spacing = CGFloat(Spacing.sm)
      secondaryRow.alignment = .centerY
      secondaryRow.detachesHiddenViews = true
      cardContainer.addSubview(secondaryRow)

      sessionAllowButton.translatesAutoresizingMaskIntoConstraints = false
      sessionAllowButton.title = "Allow Session"
      sessionAllowButton.isBordered = false
      sessionAllowButton.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      sessionAllowButton.contentTintColor = NSColor(Color.textSecondary)
      sessionAllowButton.target = self
      sessionAllowButton.action = #selector(sessionAllowClicked)
      secondaryRow.addArrangedSubview(sessionAllowButton)

      alwaysAllowButton.translatesAutoresizingMaskIntoConstraints = false
      alwaysAllowButton.title = "Always Allow"
      alwaysAllowButton.isBordered = false
      alwaysAllowButton.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      alwaysAllowButton.contentTintColor = NSColor(Color.accent)
      alwaysAllowButton.target = self
      alwaysAllowButton.action = #selector(alwaysAllowClicked)
      secondaryRow.addArrangedSubview(alwaysAllowButton)

      denyReasonButton.translatesAutoresizingMaskIntoConstraints = false
      denyReasonButton.title = "Deny w/ Reason"
      denyReasonButton.isBordered = false
      denyReasonButton.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      denyReasonButton.contentTintColor = NSColor(Color.statusError).withAlphaComponent(0.8)
      denyReasonButton.target = self
      denyReasonButton.action = #selector(denyReasonClicked)
      secondaryRow.addArrangedSubview(denyReasonButton)

      let spacer = NSView()
      spacer.translatesAutoresizingMaskIntoConstraints = false
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      secondaryRow.addArrangedSubview(spacer)

      denyStopButton.translatesAutoresizingMaskIntoConstraints = false
      denyStopButton.title = "Deny & Stop"
      denyStopButton.isBordered = false
      denyStopButton.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      denyStopButton.contentTintColor = NSColor(Color.statusError).withAlphaComponent(0.8)
      denyStopButton.target = self
      denyStopButton.action = #selector(denyStopClicked)
      secondaryRow.addArrangedSubview(denyStopButton)

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        actionDivider.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        actionDivider.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        actionDivider.heightAnchor.constraint(equalToConstant: 1),

        buttonRow.topAnchor.constraint(equalTo: actionDivider.bottomAnchor, constant: CGFloat(Spacing.sm)),
        buttonRow.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        buttonRow.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        buttonRow.heightAnchor.constraint(equalToConstant: Layout.primaryButtonHeight),

        denyButton.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor),
        denyButton.topAnchor.constraint(equalTo: buttonRow.topAnchor),
        denyButton.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),

        approveButton.leadingAnchor.constraint(equalTo: denyButton.trailingAnchor, constant: CGFloat(Spacing.sm)),
        approveButton.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
        approveButton.topAnchor.constraint(equalTo: buttonRow.topAnchor),
        approveButton.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
        approveButton.widthAnchor.constraint(equalTo: denyButton.widthAnchor),

        secondaryRow.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: CGFloat(Spacing.xs)),
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
      denyReasonField.font = NSFont.systemFont(ofSize: TypeScale.body)
      denyReasonField.textColor = NSColor(Color.textPrimary)
      denyReasonField.backgroundColor = NSColor(Color.backgroundPrimary)
      denyReasonField.isBordered = true
      denyReasonField.bezelStyle = .roundedBezel
      denyReasonContainer.addSubview(denyReasonField)

      sendDenialButton.translatesAutoresizingMaskIntoConstraints = false
      sendDenialButton.title = "Send Denial"
      sendDenialButton.bezelStyle = .rounded
      sendDenialButton.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
      sendDenialButton.contentTintColor = .white
      sendDenialButton.wantsLayer = true
      sendDenialButton.layer?.cornerRadius = CGFloat(Radius.md)
      sendDenialButton.layer?.backgroundColor = NSColor(Color.statusError).withAlphaComponent(0.75).cgColor
      sendDenialButton.target = self
      sendDenialButton.action = #selector(sendDenialClicked)
      denyReasonContainer.addSubview(sendDenialButton)

      let pad = CGFloat(Spacing.xs)
      NSLayoutConstraint.activate([
        denyReasonContainer.topAnchor.constraint(equalTo: secondaryRow.bottomAnchor, constant: CGFloat(Spacing.xs)),
        denyReasonContainer.leadingAnchor.constraint(
          equalTo: cardContainer.leadingAnchor,
          constant: Layout.cardPadding
        ),
        denyReasonContainer.trailingAnchor.constraint(
          equalTo: cardContainer.trailingAnchor,
          constant: -Layout.cardPadding
        ),

        denyReasonField.topAnchor.constraint(equalTo: denyReasonContainer.topAnchor, constant: pad),
        denyReasonField.leadingAnchor.constraint(equalTo: denyReasonContainer.leadingAnchor, constant: pad),
        denyReasonField.trailingAnchor.constraint(equalTo: denyReasonContainer.trailingAnchor, constant: -pad),

        sendDenialButton.topAnchor.constraint(equalTo: denyReasonField.bottomAnchor, constant: pad),
        sendDenialButton.trailingAnchor.constraint(equalTo: denyReasonContainer.trailingAnchor, constant: -pad),
        sendDenialButton.bottomAnchor.constraint(equalTo: denyReasonContainer.bottomAnchor, constant: -pad),
        sendDenialButton.heightAnchor.constraint(equalToConstant: 22),
      ])
    }

    // MARK: - Configure

    func configure(model: ApprovalCardModel) {
      currentModel = model
      showDenyReason = false
      denyReasonContainer.isHidden = true
      denyReasonField.stringValue = ""
      clearQuestionFormState()

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
      let preview = ApprovalPermissionPreviewBuilder.build(for: model)

      // Show permission views
      toolBadge.isHidden = false
      commandContainer.isHidden = preview == nil
      projectPathRow.isHidden = preview?.showsProjectPath != true
      actionDivider.isHidden = false
      buttonRow.isHidden = false
      secondaryRow.isHidden = false
      riskBadge.isHidden = model.risk != .high

      // Hide other modes
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
      headerIcon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
      headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.subhead, weight: .semibold)
      headerIcon.contentTintColor = NSColor(model.risk.tintColor)
      headerLabel.stringValue = "Approval Required"

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
        riskBadgeLabel.stringValue = "HIGH RISK"
      }

      // Preview content
      if let preview {
        setCommandPreviewText(preview.text)
        commandAccentBar.layer?.backgroundColor = NSColor(model.risk.tintColor).cgColor
        commandContainer.isHidden = false
        if preview.showsProjectPath {
          projectPathIcon.image = NSImage(systemSymbolName: preview.projectPathIconName, accessibilityDescription: nil)
          projectPathLabel.stringValue = model.projectPath
          projectPathRow.isHidden = false
        } else {
          projectPathRow.isHidden = true
        }
      } else {
        setCommandPreviewText(nil)
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

      let prompts = Self.questionPrompts(for: model)
      let isMultiPrompt = prompts.count > 1
      let primaryPrompt = prompts.first
      let hasOptions = !(primaryPrompt?.options ?? []).isEmpty && !isMultiPrompt

      // Show question views
      questionTextLabel.isHidden = false
      if isMultiPrompt {
        configureQuestionPromptForm(prompts)
        questionOptionsTopConstraint?.constant = CGFloat(Spacing.md)
        questionOptionsStack.isHidden = false
        answerField.isHidden = true
        submitButton.isHidden = false
        submitButton.title = "Submit Answers"
      } else {
        configureQuestionOptions(primaryPrompt?.options ?? [])
        questionOptionsTopConstraint?.constant = hasOptions ? CGFloat(Spacing.md) : 0
        questionOptionsStack.isHidden = !hasOptions
        answerField.isHidden = hasOptions
        submitButton.isHidden = hasOptions
        submitButton.title = "Submit"
      }

      // Hide other modes
      toolBadge.isHidden = true
      commandContainer.isHidden = true
      setCommandPreviewText(nil)
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

      if isMultiPrompt {
        questionTextLabel.stringValue = "Answer all questions to continue."
      } else {
        questionTextLabel.stringValue = primaryPrompt?.question ?? ""
      }
      if !hasOptions, !isMultiPrompt {
        answerField.stringValue = ""
      }
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
      setCommandPreviewText(nil)
      projectPathRow.isHidden = true
      actionDivider.isHidden = true
      buttonRow.isHidden = true
      secondaryRow.isHidden = true
      riskBadge.isHidden = true
      questionTextLabel.isHidden = true
      questionOptionsTopConstraint?.constant = 0
      questionOptionsStack.isHidden = true
      configureQuestionOptions([])
      clearQuestionFormState()
      answerField.isHidden = true
      submitButton.isHidden = true

      // Header
      let iconName = isPermission ? "lock.fill" : "questionmark.bubble.fill"
      headerIcon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
      headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.subhead, weight: .semibold)
      headerIcon.contentTintColor = tint
      headerLabel.stringValue = isPermission ? "Approval Required" : "Question Pending"

      takeoverDescription.stringValue = "Take over this session to respond."
      takeoverButton.title = isPermission ? "Take Over & Review" : "Take Over & Answer"
      takeoverButton.layer?.backgroundColor = tint.withAlphaComponent(0.75).cgColor
    }

    private func updateActionDividerPosition(_: ApprovalCardModel) {
      // Remove existing position constraints for divider if any
      for constraint in cardContainer.constraints where constraint.firstItem === actionDivider
        && constraint.firstAttribute == .top
      {
        constraint.isActive = false
      }

      let anchor: NSView = if !projectPathRow.isHidden {
        projectPathRow
      } else if !commandContainer.isHidden {
        commandContainer
      } else {
        toolBadge
      }

      actionDivider.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: CGFloat(Spacing.sm)).isActive = true
    }

    private func setCommandPreviewText(_ text: String?) {
      commandPreviewTextForSizing = text
      commandText.string = text ?? ""
      commandTextScrollView.contentView.scroll(to: .zero)
      commandTextScrollView.reflectScrolledClipView(commandTextScrollView.contentView)
      refreshCommandPreviewHeight()
    }

    private func refreshCommandPreviewHeight() {
      guard !commandContainer.isHidden, let text = commandPreviewTextForSizing else {
        commandTextHeightConstraint?.constant = Layout.minCommandTextHeight
        commandTextScrollView.hasVerticalScroller = false
        return
      }

      let availableWidth = max(bounds.width, 1)
      let visibleHeight = Self.visibleCommandTextHeight(text, availableWidth: availableWidth)
      commandTextHeightConstraint?.constant = visibleHeight

      let fullHeight = Self.measureTextHeight(
        text,
        font: NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular),
        width: Self.commandTextWidth(for: availableWidth)
      )
      commandTextScrollView.hasVerticalScroller = fullHeight > visibleHeight + 0.5
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
      let questionId = currentModel?.questions.first?.id ?? "0"
      onAnswer?([questionId: [answer]])
      answerField.stringValue = ""
    }

    @objc private func submitButtonClicked() {
      if let model = currentModel, Self.questionPrompts(for: model).count > 1 {
        let answers = collectQuestionAnswers()
        guard !answers.isEmpty else { return }
        onAnswer?(answers)
        clearQuestionFormState()
        configureQuestionPromptForm(Self.questionPrompts(for: model))
        return
      }
      answerFieldSubmitted()
    }

    @objc private func questionOptionClicked(_ sender: NSButton) {
      let payload = questionOptionPayloads[ObjectIdentifier(sender)]
      let questionId = payload?.questionId ?? currentModel?.questions.first?.id ?? "0"
      let label = payload?.optionLabel ?? sender.title.components(separatedBy: "\n").first ?? sender.title
      let answer = label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !answer.isEmpty else { return }
      onAnswer?([questionId: [answer]])
    }

    @objc private func questionPromptOptionClicked(_ sender: NSButton) {
      guard let payload = questionOptionPayloads[ObjectIdentifier(sender)] else { return }
      let prompt = currentModel?
        .questions
        .first(where: { $0.id == payload.questionId })
      let allowsMultipleSelection = prompt?.allowsMultipleSelection == true
      toggleOptionAnswer(
        questionId: payload.questionId,
        optionLabel: payload.optionLabel,
        allowsMultipleSelection: allowsMultipleSelection,
        selectedButton: sender
      )
    }

    @objc private func takeoverButtonClicked() {
      onTakeOver?()
    }

    private func configureQuestionOptions(_ options: [ApprovalQuestionOption]) {
      for view in questionOptionsStack.arrangedSubviews {
        questionOptionsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      questionOptionPayloads = [:]
      questionOptionButtons = [:]

      guard !options.isEmpty else { return }

      let questionId = currentModel?.questions.first?.id ?? "0"
      var buttons: [NSButton] = []
      for option in options {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(option.label)
        button.title = Self.questionOptionDisplayText(option)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
        button.contentTintColor = NSColor(Color.textPrimary)
        button.alignment = .left
        button.imagePosition = .noImage
        button.wantsLayer = true
        button.layer?.cornerRadius = CGFloat(Radius.md)
        button.layer?.backgroundColor = NSColor(Color.backgroundPrimary).withAlphaComponent(0.8).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor(Color.statusQuestion).withAlphaComponent(0.35).cgColor
        button.target = self
        button.action = #selector(questionOptionClicked(_:))
        button.toolTip = option.description
        questionOptionPayloads[ObjectIdentifier(button)] = (questionId: questionId, optionLabel: option.label)
        if let cell = button.cell as? NSButtonCell {
          cell.lineBreakMode = .byWordWrapping
          cell.wraps = true
          cell.usesSingleLineMode = false
        }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        questionOptionsStack.addArrangedSubview(button)
        buttons.append(button)
      }
      if !buttons.isEmpty {
        questionOptionButtons[questionId] = buttons
      }
    }

    private func clearQuestionFormState() {
      selectedQuestionAnswers = [:]
      questionTextFields = [:]
      questionOptionButtons = [:]
      questionOptionPayloads = [:]
    }

    private func configureQuestionPromptForm(_ prompts: [ApprovalQuestionPrompt]) {
      for view in questionOptionsStack.arrangedSubviews {
        questionOptionsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      clearQuestionFormState()
      guard !prompts.isEmpty else { return }

      for (index, prompt) in prompts.enumerated() {
        let section = NSStackView()
        section.orientation = .vertical
        section.spacing = 6
        section.alignment = .width
        section.distribution = .fill
        section.translatesAutoresizingMaskIntoConstraints = false

        if let header = prompt.header, !header.isEmpty {
          let headerLabel = NSTextField(labelWithString: header.uppercased())
          headerLabel.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
          headerLabel.textColor = NSColor(Color.textSecondary)
          headerLabel.lineBreakMode = .byTruncatingTail
          section.addArrangedSubview(headerLabel)
        }

        let questionLabel = NSTextField(wrappingLabelWithString: prompt.question)
        questionLabel.font = NSFont.systemFont(ofSize: TypeScale.reading, weight: .medium)
        questionLabel.textColor = NSColor(Color.textPrimary)
        questionLabel.maximumNumberOfLines = 0
        section.addArrangedSubview(questionLabel)

        if !prompt.options.isEmpty {
          let optionsStack = NSStackView()
          optionsStack.orientation = .vertical
          optionsStack.spacing = CGFloat(Spacing.xs)
          optionsStack.alignment = .width
          optionsStack.distribution = .fill
          optionsStack.translatesAutoresizingMaskIntoConstraints = false
          var buttons: [NSButton] = []

          for option in prompt.options {
            let button = NSButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.identifier = NSUserInterfaceItemIdentifier(option.label)
            button.title = Self.questionOptionDisplayText(option)
            button.setButtonType(.momentaryPushIn)
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
            button.contentTintColor = NSColor(Color.textPrimary)
            button.alignment = .left
            button.imagePosition = .noImage
            button.wantsLayer = true
            button.layer?.cornerRadius = CGFloat(Radius.md)
            button.layer?.backgroundColor = NSColor(Color.backgroundPrimary).withAlphaComponent(0.8).cgColor
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor(Color.statusQuestion).withAlphaComponent(0.35).cgColor
            button.target = self
            button.action = #selector(questionPromptOptionClicked(_:))
            button.toolTip = option.description
            questionOptionPayloads[ObjectIdentifier(button)] = (
              questionId: prompt.id,
              optionLabel: option.label
            )
            if let cell = button.cell as? NSButtonCell {
              cell.lineBreakMode = .byWordWrapping
              cell.wraps = true
              cell.usesSingleLineMode = false
            }
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
            optionsStack.addArrangedSubview(button)
            buttons.append(button)
          }

          if !buttons.isEmpty {
            questionOptionButtons[prompt.id] = buttons
          }
          section.addArrangedSubview(optionsStack)
        }

        if prompt.options.isEmpty || prompt.allowsOther {
          let field: NSTextField = prompt.isSecret ? NSSecureTextField() : NSTextField()
          field.translatesAutoresizingMaskIntoConstraints = false
          field.placeholderString = prompt.isSecret ? "Enter secure answer..." : "Your answer..."
          field.font = NSFont.systemFont(ofSize: TypeScale.body)
          field.textColor = NSColor(Color.textPrimary)
          field.backgroundColor = NSColor(Color.backgroundPrimary)
          field.isBordered = true
          field.bezelStyle = .roundedBezel
          field.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
          questionTextFields[prompt.id] = field
          section.addArrangedSubview(field)
        }

        questionOptionsStack.addArrangedSubview(section)
        if index < prompts.count - 1 {
          let spacer = NSView()
          spacer.translatesAutoresizingMaskIntoConstraints = false
          spacer.heightAnchor.constraint(equalToConstant: CGFloat(Spacing.sm)).isActive = true
          questionOptionsStack.addArrangedSubview(spacer)
        }
      }
    }

    private func toggleOptionAnswer(
      questionId: String,
      optionLabel: String,
      allowsMultipleSelection: Bool,
      selectedButton: NSButton
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
        let payload = questionOptionPayloads[ObjectIdentifier(button)]
        let label = payload?.optionLabel
          ?? button.title.components(separatedBy: "\n").first
          ?? button.title
        let isSelected = current.contains(label)
        button.layer?.borderColor = isSelected
          ? NSColor(Color.statusQuestion).withAlphaComponent(0.9).cgColor
          : NSColor(Color.statusQuestion).withAlphaComponent(0.35).cgColor
      }
      if !allowsMultipleSelection {
        selectedButton.layer?.borderColor = NSColor(Color.statusQuestion).withAlphaComponent(0.9).cgColor
      }
    }

    private func collectQuestionAnswers() -> [String: [String]] {
      guard let model = currentModel else { return [:] }
      let prompts = Self.questionPrompts(for: model)
      var answers: [String: [String]] = [:]

      for prompt in prompts {
        var values = selectedQuestionAnswers[prompt.id] ?? []
        if let field = questionTextFields[prompt.id] {
          let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Height Calculation

    static func requiredHeight(for model: ApprovalCardModel?, availableWidth: CGFloat) -> CGFloat {
      guard let model else { return 160 }

      let pad = Layout.cardPadding
      let outerInset = Layout.outerVerticalInset
      let laneInset = ConversationLayout.laneHorizontalInset
      // Inner content width: table width → card insets → card padding
      let contentWidth = availableWidth - laneInset * 2 - pad * 2

      switch model.mode {
        case .permission:
          var h: CGFloat = outerInset
          h += 2 // risk strip
          h += pad // top card padding
          h += Layout.headerIconSize // header row (icon + label)
          h += CGFloat(Spacing.md) + 20 // tool badge row

          if let text = Self.commandPreviewText(for: model) {
            h += CGFloat(Spacing.sm) // spacing before command container
            h += Layout.commandVerticalPadding
            h += Self.visibleCommandTextHeight(text, availableWidth: availableWidth)
            h += Layout.commandVerticalPadding

            if model.command != nil {
              h += Layout.commandVerticalPadding + 12 // project path row
            }
          }

          if model.diff != nil { h += 120 }

          h += CGFloat(Spacing.sm) + 1 // divider
          h += CGFloat(Spacing.sm) + Layout.primaryButtonHeight // primary buttons
          h += CGFloat(Spacing.xs) + Layout.secondaryRowHeight // secondary row
          h += pad // bottom card padding
          h += outerInset // bottom cell padding
          return h

        case .question:
          var h: CGFloat = outerInset + 2 + pad // cell pad + risk strip + card pad
          h += Layout.headerIconSize // header
          h += CGFloat(Spacing.md)
          let prompts = questionPrompts(for: model)
          if prompts.count > 1 {
            h += Self.measureTextHeight(
              "Answer all questions to continue.",
              font: NSFont.systemFont(ofSize: TypeScale.reading, weight: .medium),
              width: contentWidth
            )
            h += CGFloat(Spacing.md)
            for (index, prompt) in prompts.enumerated() {
              h += questionPromptHeight(prompt, width: contentWidth)
              if index < prompts.count - 1 {
                h += CGFloat(Spacing.sm)
              }
            }
            h += CGFloat(Spacing.md) + 28
          } else if let prompt = prompts.first {
            let qFont = NSFont.systemFont(ofSize: TypeScale.reading, weight: .regular)
            h += Self.measureTextHeight(prompt.question, font: qFont, width: contentWidth)
            if prompt.options.isEmpty {
              h += CGFloat(Spacing.md) + 26
              h += CGFloat(Spacing.md) + 28
            } else {
              h += CGFloat(Spacing.md)
              for (index, option) in prompt.options.enumerated() {
                h += Self.questionOptionHeight(option, width: contentWidth)
                if index < prompt.options.count - 1 {
                  h += CGFloat(Spacing.xs)
                }
              }
            }
          } else {
            h += 20
            h += CGFloat(Spacing.md) + 26 // answer field
            h += CGFloat(Spacing.md) + 28 // submit button
          }
          h += pad + outerInset // card pad + cell pad
          return h

        case .takeover:
          var h: CGFloat = outerInset + 2 + pad
          h += Layout.headerIconSize // header
          h += CGFloat(Spacing.md) + 20 // tool badge (if visible)
          h += CGFloat(Spacing.md) + 20 // description
          h += CGFloat(Spacing.md) + 30 // button
          h += pad + outerInset
          return h

        case .none:
          return 1
      }
    }

    /// Measure wrapped text height for a given font and constrained width.
    private static func measureTextHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
      guard !text.isEmpty, width > 0 else { return 0 }
      let attr = NSAttributedString(string: text, attributes: [.font: font])
      let rect = attr.boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      )
      return ceil(rect.height)
    }

    private static func commandPreviewText(for model: ApprovalCardModel) -> String? {
      ApprovalPermissionPreviewBuilder.build(for: model)?.text
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
          font: NSFont.systemFont(ofSize: TypeScale.micro, weight: .semibold),
          width: width
        )
        height += 4
      }

      height += measureTextHeight(
        prompt.question,
        font: NSFont.systemFont(ofSize: TypeScale.reading, weight: .medium),
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
        height += 6 + 26
      }

      return height
    }

    private static func questionOptionHeight(_ option: ApprovalQuestionOption, width: CGFloat) -> CGFloat {
      let text = questionOptionDisplayText(option)
      let textHeight = measureTextHeight(
        text,
        font: NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold),
        width: max(1, width - 20)
      )
      return max(30, textHeight + 16)
    }

    private static func commandTextWidth(for availableWidth: CGFloat) -> CGFloat {
      let contentWidth = availableWidth - ConversationLayout.laneHorizontalInset * 2 - Layout.cardPadding * 2
      return max(1, contentWidth - CGFloat(EdgeBar.width) - Layout.commandHorizontalPadding * 2)
    }

    private static func visibleCommandTextHeight(_ text: String, availableWidth: CGFloat) -> CGFloat {
      let font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      let fullHeight = measureTextHeight(text, font: font, width: commandTextWidth(for: availableWidth))
      let clampedHeight = min(fullHeight, Layout.maxCommandTextHeight)
      return max(Layout.minCommandTextHeight, clampedHeight)
    }
  }

#endif
