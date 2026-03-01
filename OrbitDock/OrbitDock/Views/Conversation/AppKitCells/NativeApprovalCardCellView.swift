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

    // Merged header — tool icon + "ToolName · Approval Required" + risk badge + spinner
    private let headerIcon = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let riskBadge = NSView()
    private let riskBadgeIcon = NSImageView()
    private let riskBadgeLabel = NSTextField(labelWithString: "HIGH RISK")
    private let spinnerView = NSProgressIndicator()

    // Command preview — structured segments
    private let segmentStack = NSStackView()
    private let riskFindingsStack = NSStackView()

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

    // Permission buttons — split-button containers with dropdown chevrons
    private let buttonRow = NSView()
    private let denySplitContainer = NSView()
    private let denyMainArea = NSView()
    private let denyLabel = NSTextField(labelWithString: "")
    private let denyChevronDivider = NSView()
    private let denyChevronArea = NSView()
    private let denyChevronIcon = NSImageView()
    private let approveSplitContainer = NSView()
    private let approveMainArea = NSView()
    private let approveIcon = NSImageView()
    private let approveLabel = NSTextField(labelWithString: "")
    private let approveChevronDivider = NSView()
    private let approveChevronArea = NSView()
    private let approveChevronIcon = NSImageView()

    // Deny reason panel
    private let denyReasonContainer = NSView()
    private let denyReasonField = NSTextField()
    private let sendDenialButton = NSButton()

    private var currentModel: ApprovalCardModel?
    private var showDenyReason = false
    private var questionOptionsTopConstraint: NSLayoutConstraint?
    private var selectedQuestionAnswers: [String: [String]] = [:]
    private var questionTextFields: [String: NSTextField] = [:]
    private var questionOptionButtons: [String: [NSButton]] = [:]
    private var questionOptionPayloads: [ObjectIdentifier: (questionId: String, optionLabel: String)] = [:]

    // Click gesture recognizers for split buttons
    private var denyMainClick: NSClickGestureRecognizer?
    private var denyChevronClick: NSClickGestureRecognizer?
    private var approveMainClick: NSClickGestureRecognizer?
    private var approveChevronClick: NSClickGestureRecognizer?

    private typealias Layout = ApprovalCardHeightCalculator.Layout

    private enum LocalLayout {
      static let chevronWidth: CGFloat = 28
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

    // MARK: - Merged Header

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
      headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      cardContainer.addSubview(headerLabel)

      // Risk badge — inline in header row
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

        riskBadge.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        riskBadge.leadingAnchor.constraint(equalTo: headerLabel.trailingAnchor, constant: CGFloat(Spacing.sm)),
        riskBadge.trailingAnchor.constraint(
          lessThanOrEqualTo: spinnerView.leadingAnchor,
          constant: -CGFloat(Spacing.sm)
        ),

        riskBadgeIcon.leadingAnchor.constraint(equalTo: riskBadge.leadingAnchor, constant: CGFloat(Spacing.sm)),
        riskBadgeIcon.centerYAnchor.constraint(equalTo: riskBadge.centerYAnchor),
        riskBadgeIcon.widthAnchor.constraint(equalToConstant: 10),
        riskBadgeIcon.heightAnchor.constraint(equalToConstant: 10),

        riskBadgeLabel.leadingAnchor.constraint(equalTo: riskBadgeIcon.trailingAnchor, constant: 3),
        riskBadgeLabel.trailingAnchor.constraint(equalTo: riskBadge.trailingAnchor, constant: -CGFloat(Spacing.sm)),
        riskBadgeLabel.topAnchor.constraint(equalTo: riskBadge.topAnchor, constant: 2),
        riskBadgeLabel.bottomAnchor.constraint(equalTo: riskBadge.bottomAnchor, constant: -2),

        spinnerView.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
        spinnerView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
      ])
    }

    // MARK: - Command Preview

    private func setupCommandPreview() {
      // Segment stack — holds per-segment code blocks
      segmentStack.translatesAutoresizingMaskIntoConstraints = false
      segmentStack.orientation = .vertical
      segmentStack.spacing = CGFloat(Spacing.xs)
      segmentStack.alignment = .leading
      segmentStack.detachesHiddenViews = true
      cardContainer.addSubview(segmentStack)

      // Risk findings stack
      riskFindingsStack.translatesAutoresizingMaskIntoConstraints = false
      riskFindingsStack.orientation = .vertical
      riskFindingsStack.spacing = CGFloat(Spacing.xs)
      riskFindingsStack.alignment = .leading
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
        takeoverDescription.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverDescription.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverDescription.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        takeoverButton.topAnchor.constraint(equalTo: takeoverDescription.bottomAnchor, constant: CGFloat(Spacing.md)),
        takeoverButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        takeoverButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        takeoverButton.heightAnchor.constraint(equalToConstant: 30),
      ])
    }

    // MARK: - Split-Button Permission Buttons

    private func setupPermissionButtons() {
      buttonRow.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(buttonRow)

      // — Deny split button —
      setupDenySplitButton()
      // — Approve split button —
      setupApproveSplitButton()

      let pad = Layout.cardPadding
      NSLayoutConstraint.activate([
        buttonRow.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: pad),
        buttonRow.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),
        buttonRow.heightAnchor.constraint(equalToConstant: Layout.primaryButtonHeight),

        // Deny: 40% width
        denySplitContainer.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor),
        denySplitContainer.topAnchor.constraint(equalTo: buttonRow.topAnchor),
        denySplitContainer.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),

        // Approve: 60% width
        approveSplitContainer.leadingAnchor.constraint(
          equalTo: denySplitContainer.trailingAnchor,
          constant: CGFloat(Spacing.sm)
        ),
        approveSplitContainer.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
        approveSplitContainer.topAnchor.constraint(equalTo: buttonRow.topAnchor),
        approveSplitContainer.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),

        // Ratio: deny takes 2/5, approve takes 3/5 (minus the gap)
        denySplitContainer.widthAnchor.constraint(equalTo: approveSplitContainer.widthAnchor, multiplier: 2.0 / 3.0),
      ])
    }

    private func setupDenySplitButton() {
      denySplitContainer.wantsLayer = true
      denySplitContainer.layer?.cornerRadius = CGFloat(Radius.md)
      denySplitContainer.layer?.masksToBounds = true
      denySplitContainer.translatesAutoresizingMaskIntoConstraints = false
      buttonRow.addSubview(denySplitContainer)

      // Main clickable area
      denyMainArea.wantsLayer = true
      denyMainArea.translatesAutoresizingMaskIntoConstraints = false
      denySplitContainer.addSubview(denyMainArea)

      denyLabel.translatesAutoresizingMaskIntoConstraints = false
      denyLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      denyLabel.textColor = NSColor(Color.statusError)
      denyLabel.alignment = .center
      denyLabel.stringValue = "Deny"
      denyMainArea.addSubview(denyLabel)

      // Vertical divider
      denyChevronDivider.wantsLayer = true
      denyChevronDivider.translatesAutoresizingMaskIntoConstraints = false
      denySplitContainer.addSubview(denyChevronDivider)

      // Chevron area
      denyChevronArea.wantsLayer = true
      denyChevronArea.translatesAutoresizingMaskIntoConstraints = false
      denySplitContainer.addSubview(denyChevronArea)

      denyChevronIcon.translatesAutoresizingMaskIntoConstraints = false
      denyChevronIcon.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More deny options")
      denyChevronIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
      denyChevronIcon.contentTintColor = NSColor(Color.statusError).withAlphaComponent(0.8)
      denyChevronArea.addSubview(denyChevronIcon)

      // Gesture recognizers
      let mainClick = NSClickGestureRecognizer(target: self, action: #selector(denyMainClicked))
      denyMainArea.addGestureRecognizer(mainClick)
      denyMainClick = mainClick

      let chevronClick = NSClickGestureRecognizer(target: self, action: #selector(denyChevronClicked))
      denyChevronArea.addGestureRecognizer(chevronClick)
      denyChevronClick = chevronClick

      NSLayoutConstraint.activate([
        denyMainArea.leadingAnchor.constraint(equalTo: denySplitContainer.leadingAnchor),
        denyMainArea.topAnchor.constraint(equalTo: denySplitContainer.topAnchor),
        denyMainArea.bottomAnchor.constraint(equalTo: denySplitContainer.bottomAnchor),
        denyMainArea.trailingAnchor.constraint(equalTo: denyChevronDivider.leadingAnchor),

        denyLabel.centerXAnchor.constraint(equalTo: denyMainArea.centerXAnchor),
        denyLabel.centerYAnchor.constraint(equalTo: denyMainArea.centerYAnchor),

        denyChevronDivider.trailingAnchor.constraint(equalTo: denyChevronArea.leadingAnchor),
        denyChevronDivider.topAnchor.constraint(equalTo: denySplitContainer.topAnchor, constant: 6),
        denyChevronDivider.bottomAnchor.constraint(equalTo: denySplitContainer.bottomAnchor, constant: -6),
        denyChevronDivider.widthAnchor.constraint(equalToConstant: 1),

        denyChevronArea.trailingAnchor.constraint(equalTo: denySplitContainer.trailingAnchor),
        denyChevronArea.topAnchor.constraint(equalTo: denySplitContainer.topAnchor),
        denyChevronArea.bottomAnchor.constraint(equalTo: denySplitContainer.bottomAnchor),
        denyChevronArea.widthAnchor.constraint(equalToConstant: LocalLayout.chevronWidth),

        denyChevronIcon.centerXAnchor.constraint(equalTo: denyChevronArea.centerXAnchor),
        denyChevronIcon.centerYAnchor.constraint(equalTo: denyChevronArea.centerYAnchor),
      ])
    }

    private func setupApproveSplitButton() {
      approveSplitContainer.wantsLayer = true
      approveSplitContainer.layer?.cornerRadius = CGFloat(Radius.md)
      approveSplitContainer.layer?.masksToBounds = true
      approveSplitContainer.translatesAutoresizingMaskIntoConstraints = false
      buttonRow.addSubview(approveSplitContainer)

      // Main clickable area
      approveMainArea.wantsLayer = true
      approveMainArea.translatesAutoresizingMaskIntoConstraints = false
      approveSplitContainer.addSubview(approveMainArea)

      approveIcon.translatesAutoresizingMaskIntoConstraints = false
      approveIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
      approveIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.body, weight: .semibold)
      approveIcon.contentTintColor = .white
      approveMainArea.addSubview(approveIcon)

      approveLabel.translatesAutoresizingMaskIntoConstraints = false
      approveLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .bold)
      approveLabel.textColor = .white
      approveLabel.alignment = .center
      approveLabel.stringValue = "Approve"
      approveMainArea.addSubview(approveLabel)

      // Vertical divider
      approveChevronDivider.wantsLayer = true
      approveChevronDivider.translatesAutoresizingMaskIntoConstraints = false
      approveSplitContainer.addSubview(approveChevronDivider)

      // Chevron area
      approveChevronArea.wantsLayer = true
      approveChevronArea.translatesAutoresizingMaskIntoConstraints = false
      approveSplitContainer.addSubview(approveChevronArea)

      approveChevronIcon.translatesAutoresizingMaskIntoConstraints = false
      approveChevronIcon.image = NSImage(
        systemSymbolName: "chevron.down",
        accessibilityDescription: "More approve options"
      )
      approveChevronIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
      approveChevronIcon.contentTintColor = NSColor.white.withAlphaComponent(0.8)
      approveChevronArea.addSubview(approveChevronIcon)

      // Gesture recognizers
      let mainClick = NSClickGestureRecognizer(target: self, action: #selector(approveMainClicked))
      approveMainArea.addGestureRecognizer(mainClick)
      approveMainClick = mainClick

      let chevronClick = NSClickGestureRecognizer(target: self, action: #selector(approveChevronClicked))
      approveChevronArea.addGestureRecognizer(chevronClick)
      approveChevronClick = chevronClick

      NSLayoutConstraint.activate([
        approveMainArea.leadingAnchor.constraint(equalTo: approveSplitContainer.leadingAnchor),
        approveMainArea.topAnchor.constraint(equalTo: approveSplitContainer.topAnchor),
        approveMainArea.bottomAnchor.constraint(equalTo: approveSplitContainer.bottomAnchor),
        approveMainArea.trailingAnchor.constraint(equalTo: approveChevronDivider.leadingAnchor),

        approveIcon.trailingAnchor.constraint(equalTo: approveLabel.leadingAnchor, constant: -CGFloat(Spacing.xs)),
        approveIcon.centerYAnchor.constraint(equalTo: approveMainArea.centerYAnchor),

        approveLabel.centerXAnchor.constraint(equalTo: approveMainArea.centerXAnchor, constant: 8),
        approveLabel.centerYAnchor.constraint(equalTo: approveMainArea.centerYAnchor),

        approveChevronDivider.trailingAnchor.constraint(equalTo: approveChevronArea.leadingAnchor),
        approveChevronDivider.topAnchor.constraint(equalTo: approveSplitContainer.topAnchor, constant: 6),
        approveChevronDivider.bottomAnchor.constraint(equalTo: approveSplitContainer.bottomAnchor, constant: -6),
        approveChevronDivider.widthAnchor.constraint(equalToConstant: 1),

        approveChevronArea.trailingAnchor.constraint(equalTo: approveSplitContainer.trailingAnchor),
        approveChevronArea.topAnchor.constraint(equalTo: approveSplitContainer.topAnchor),
        approveChevronArea.bottomAnchor.constraint(equalTo: approveSplitContainer.bottomAnchor),
        approveChevronArea.widthAnchor.constraint(equalToConstant: LocalLayout.chevronWidth),

        approveChevronIcon.centerXAnchor.constraint(equalTo: approveChevronArea.centerXAnchor),
        approveChevronIcon.centerYAnchor.constraint(equalTo: approveChevronArea.centerYAnchor),
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
        denyReasonContainer.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: CGFloat(Spacing.sm)),
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
      let hasContent = ApprovalPermissionPreviewHelpers.hasPreviewContent(model)

      // Show permission views
      segmentStack.isHidden = !hasContent
      buttonRow.isHidden = false
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

      // Merged header — tool icon + "ToolName · Status"
      let headerConfig = ApprovalCardConfiguration.headerConfig(for: model, mode: .permission)
      headerIcon.image = NSImage(systemSymbolName: headerConfig.iconName, accessibilityDescription: nil)
      headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.subhead, weight: .semibold)
      headerIcon.contentTintColor = NSColor(headerConfig.iconTint)
      headerLabel.stringValue = headerConfig.label
      approveLabel.stringValue = headerConfig.approveTitle
      denyLabel.stringValue = headerConfig.denyTitle

      // Risk badge (inline in header)
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
      configurePreviewContent(model)
      configureRiskFindings(model)

      // Style split buttons
      let errorColor = NSColor(Color.statusError)
      denySplitContainer.layer?.backgroundColor = errorColor.withAlphaComponent(CGFloat(OpacityTier.light)).cgColor
      denyChevronDivider.layer?.backgroundColor = errorColor.withAlphaComponent(0.3).cgColor
      denyLabel.textColor = errorColor
      denyChevronIcon.contentTintColor = errorColor.withAlphaComponent(0.8)

      let accentColor = NSColor(Color.accent)
      approveSplitContainer.layer?.backgroundColor = accentColor.cgColor
      approveChevronDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor

      // Position button row after last visible content
      updateButtonRowPosition(model)
    }

    // MARK: - Structured Preview Content

    private func configurePreviewContent(_ model: ApprovalCardModel) {
      // Clear previous segments
      for view in segmentStack.arrangedSubviews {
        segmentStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }

      let accentColor = NSColor(model.risk.tintColor)

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
              view.widthAnchor.constraint(equalTo: segmentStack.widthAnchor).isActive = true
            }
          } else if let command = ApprovalPermissionPreviewHelpers.trimmed(model.command) {
            let view = makeSegmentView(
              command: command, operator: nil, isFirst: true, accentColor: accentColor
            )
            segmentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: segmentStack.widthAnchor).isActive = true
          } else if let manifest = ApprovalPermissionPreviewHelpers.trimmed(model.serverManifest) {
            let view = makeSegmentView(
              command: manifest, operator: nil, isFirst: true, accentColor: accentColor
            )
            segmentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: segmentStack.widthAnchor).isActive = true
          }

        default:
          if let value = ApprovalPermissionPreviewHelpers.previewValue(for: model) {
            let view = makeNonShellPreview(
              type: model.previewType,
              value: value,
              toolName: model.toolName,
              accentColor: accentColor
            )
            segmentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: segmentStack.widthAnchor).isActive = true
          } else if let manifest = ApprovalPermissionPreviewHelpers.trimmed(model.serverManifest) {
            let view = makeSegmentView(
              command: manifest, operator: nil, isFirst: true, accentColor: accentColor
            )
            segmentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: segmentStack.widthAnchor).isActive = true
          }
      }

      segmentStack.isHidden = segmentStack.arrangedSubviews.isEmpty
    }

    private func makeSegmentView(
      command: String,
      operator leadingOp: String?,
      isFirst: Bool,
      accentColor: NSColor
    ) -> NSView {
      let container = NSView()
      container.wantsLayer = true
      container.layer?.cornerRadius = CGFloat(Radius.md)
      container.layer?.masksToBounds = true
      container.layer?.backgroundColor = NSColor(Color.backgroundPrimary).cgColor
      container.translatesAutoresizingMaskIntoConstraints = false

      // Left accent bar
      let bar = NSView()
      bar.wantsLayer = true
      bar.layer?.backgroundColor = accentColor.cgColor
      bar.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(bar)

      // Operator pill (for piped/chained segments)
      var topAnchorView: NSView = container
      var topConstant = Layout.commandVerticalPadding

      if let op = leadingOp,
         let label = ApprovalPermissionPreviewHelpers.operatorLabel(op)
      {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 3
        pill.layer?.backgroundColor = NSColor(Color.backgroundTertiary).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pill)

        let opLabel = NSTextField(labelWithString: op)
        opLabel.translatesAutoresizingMaskIntoConstraints = false
        opLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .semibold)
        opLabel.textColor = NSColor(Color.textTertiary)
        pill.addSubview(opLabel)

        let descLabel = NSTextField(labelWithString: label)
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .regular)
        descLabel.textColor = NSColor(Color.textQuaternary)
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

      // Command text
      let textField = NSTextField(wrappingLabelWithString: "")
      textField.translatesAutoresizingMaskIntoConstraints = false
      textField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      textField.textColor = NSColor(Color.textPrimary)
      textField.isSelectable = true
      textField.lineBreakMode = .byCharWrapping
      textField.maximumNumberOfLines = 0

      // Add $ prefix for first segment without operator
      if isFirst, leadingOp == nil {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
          string: "$ ",
          attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .semibold),
            .foregroundColor: accentColor,
          ]
        ))
        attributed.append(NSAttributedString(
          string: command,
          attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular),
            .foregroundColor: NSColor(Color.textPrimary),
          ]
        ))
        textField.attributedStringValue = attributed
      } else {
        textField.stringValue = command
      }

      container.addSubview(textField)

      let textTopAnchor = topAnchorView === container
        ? container.topAnchor
        : topAnchorView.bottomAnchor

      // Cap text height to match the height calculation's maxCommandTextHeight clamp.
      let bottomPin = textField.bottomAnchor.constraint(
        equalTo: container.bottomAnchor,
        constant: -Layout.commandVerticalPadding
      )
      bottomPin.priority = .defaultHigh

      let textMaxHeight = textField.heightAnchor.constraint(
        lessThanOrEqualToConstant: Layout.maxCommandTextHeight
      )

      NSLayoutConstraint.activate([
        bar.topAnchor.constraint(equalTo: container.topAnchor),
        bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        bar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        textField.topAnchor.constraint(equalTo: textTopAnchor, constant: topConstant),
        textField.leadingAnchor.constraint(
          equalTo: bar.trailingAnchor,
          constant: Layout.commandHorizontalPadding
        ),
        textField.trailingAnchor.constraint(
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
      toolName: String?,
      accentColor: NSColor
    ) -> NSView {
      let container = NSView()
      container.wantsLayer = true
      container.layer?.cornerRadius = CGFloat(Radius.md)
      container.layer?.masksToBounds = true
      container.layer?.backgroundColor = NSColor(Color.backgroundPrimary).cgColor
      container.translatesAutoresizingMaskIntoConstraints = false

      let bar = NSView()
      bar.wantsLayer = true
      bar.layer?.backgroundColor = accentColor.cgColor
      bar.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(bar)

      // Type label
      let typeLabel = NSTextField(labelWithString: type.title)
      typeLabel.translatesAutoresizingMaskIntoConstraints = false
      typeLabel.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      typeLabel.textColor = NSColor(Color.textTertiary)
      container.addSubview(typeLabel)

      // Value
      let valueField = NSTextField(wrappingLabelWithString: value)
      valueField.translatesAutoresizingMaskIntoConstraints = false
      valueField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      valueField.textColor = NSColor(Color.textPrimary)
      valueField.isSelectable = true
      valueField.lineBreakMode = .byCharWrapping
      valueField.maximumNumberOfLines = 0
      container.addSubview(valueField)

      let bottomPin = valueField.bottomAnchor.constraint(
        equalTo: container.bottomAnchor,
        constant: -Layout.commandVerticalPadding
      )
      bottomPin.priority = .defaultHigh

      let valueMaxHeight = valueField.heightAnchor.constraint(
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

        valueField.topAnchor.constraint(
          equalTo: typeLabel.bottomAnchor,
          constant: CGFloat(Spacing.xxs)
        ),
        valueField.leadingAnchor.constraint(equalTo: typeLabel.leadingAnchor),
        valueField.trailingAnchor.constraint(
          equalTo: container.trailingAnchor,
          constant: -Layout.commandHorizontalPadding
        ),
        bottomPin,
        valueMaxHeight,
      ])

      return container
    }

    private func configureRiskFindings(_ model: ApprovalCardModel) {
      // Clear previous
      for view in riskFindingsStack.arrangedSubviews {
        riskFindingsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }

      guard !model.riskFindings.isEmpty else {
        riskFindingsStack.isHidden = true
        return
      }

      let tintColor = NSColor(model.risk.tintColor)

      for finding in model.riskFindings {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.caption, weight: .regular)
        icon.contentTintColor = tintColor
        row.addSubview(icon)

        let label = NSTextField(labelWithString: finding)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .regular)
        label.textColor = NSColor(Color.textSecondary)
        label.lineBreakMode = .byTruncatingTail
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
        row.widthAnchor.constraint(equalTo: riskFindingsStack.widthAnchor).isActive = true
      }

      riskFindingsStack.isHidden = false
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
      segmentStack.isHidden = true
      riskFindingsStack.isHidden = true
      buttonRow.isHidden = true
      riskBadge.isHidden = true
      takeoverDescription.isHidden = true
      takeoverButton.isHidden = true

      // Header
      let headerConfig = ApprovalCardConfiguration.headerConfig(for: model, mode: .question)
      headerIcon.image = NSImage(systemSymbolName: headerConfig.iconName, accessibilityDescription: nil)
      headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.subhead, weight: .semibold)
      headerIcon.contentTintColor = tint
      headerLabel.stringValue = headerConfig.label

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

      // Hide other modes
      segmentStack.isHidden = true
      riskFindingsStack.isHidden = true
      buttonRow.isHidden = true
      riskBadge.isHidden = true
      questionTextLabel.isHidden = true
      questionOptionsTopConstraint?.constant = 0
      questionOptionsStack.isHidden = true
      configureQuestionOptions([])
      clearQuestionFormState()
      answerField.isHidden = true
      submitButton.isHidden = true

      // Header
      let headerConfig = ApprovalCardConfiguration.headerConfig(for: model, mode: .takeover)
      headerIcon.image = NSImage(systemSymbolName: headerConfig.iconName, accessibilityDescription: nil)
      headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.subhead, weight: .semibold)
      headerIcon.contentTintColor = tint
      headerLabel.stringValue = headerConfig.label

      takeoverDescription.stringValue = "Take over this session to respond."
      takeoverButton.title = ApprovalCardConfiguration.takeoverButtonTitle(for: model)
      takeoverButton.layer?.backgroundColor = tint.withAlphaComponent(0.75).cgColor
    }

    private func updateButtonRowPosition(_ model: ApprovalCardModel) {
      // Remove existing position constraints for buttonRow
      for constraint in cardContainer.constraints where constraint.firstItem === buttonRow
        && constraint.firstAttribute == .top
      {
        constraint.isActive = false
      }

      let anchor: NSView = if !riskFindingsStack.isHidden {
        riskFindingsStack
      } else if !segmentStack.isHidden {
        segmentStack
      } else {
        headerIcon
      }

      let spacing: CGFloat = anchor === headerIcon ? CGFloat(Spacing.md) : CGFloat(Spacing.md)
      buttonRow.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: spacing).isActive = true
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

    // MARK: - Split Button Actions

    @objc private func denyMainClicked() {
      onDecision?("denied", nil, nil)
    }

    @objc private func denyChevronClicked() {
      let menu = NSMenu()

      for action in ApprovalCardConfiguration.denyMenuActions {
        if action.isDestructive { menu.addItem(.separator()) }
        let item = NSMenuItem(
          title: action.title,
          action: #selector(menuActionSelected(_:)),
          keyEquivalent: action.keyEquivalent
        )
        item.target = self
        item.representedObject = action.decision
        if action.isDestructive {
          item.attributedTitle = NSAttributedString(
            string: action.title,
            attributes: [.foregroundColor: NSColor(Color.statusError)]
          )
        }
        menu.addItem(item)
      }

      let location = NSPoint(x: 0, y: denySplitContainer.bounds.maxY)
      menu.popUp(positioning: nil, at: location, in: denySplitContainer)
    }

    @objc private func approveMainClicked() {
      onDecision?("approved", nil, nil)
    }

    @objc private func approveChevronClicked() {
      guard let model = currentModel else { return }
      let menu = NSMenu()

      for action in ApprovalCardConfiguration.approveMenuActions(for: model) {
        let item = NSMenuItem(
          title: action.title,
          action: #selector(menuActionSelected(_:)),
          keyEquivalent: action.keyEquivalent
        )
        item.target = self
        item.representedObject = action.decision
        menu.addItem(item)
      }

      let location = NSPoint(x: 0, y: approveSplitContainer.bounds.maxY)
      menu.popUp(positioning: nil, at: location, in: approveSplitContainer)
    }

    // MARK: - Menu Actions

    @objc private func menuActionSelected(_ sender: NSMenuItem) {
      guard let decision = sender.representedObject as? String else { return }
      if decision == "deny_reason" {
        showDenyReason = true
        denyReasonContainer.isHidden = false
        window?.makeFirstResponder(denyReasonField)
      } else {
        onDecision?(decision, nil, nil)
      }
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

    // MARK: - Question Options

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
        button.title = ApprovalCardHeightCalculator.questionOptionDisplayText(option)
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
            button.title = ApprovalCardHeightCalculator.questionOptionDisplayText(option)
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
      ApprovalCardHeightCalculator.requiredHeight(for: model, availableWidth: availableWidth)
    }

    private static func questionPrompts(for model: ApprovalCardModel) -> [ApprovalQuestionPrompt] {
      model.questions
    }

  }

#endif
