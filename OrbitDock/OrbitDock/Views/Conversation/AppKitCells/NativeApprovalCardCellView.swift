//
//  NativeApprovalCardCellView.swift
//  OrbitDock
//
//  Compact macOS approval/question summary card for the conversation timeline.
//  Detailed interaction now lives in the composer pending-action panel.
//

#if os(macOS)

  import AppKit
  import SwiftUI

  final class NativeApprovalCardCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeApprovalCardCell")

    private let cardContainer = NSView()
    private let accentBar = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailStack = NSStackView()
    private let actionButton = NSButton()
    private lazy var cardClickGesture = NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:)))

    private var currentModel: ApprovalCardModel?

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    private func setup() {
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor

      cardContainer.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.wantsLayer = true
      cardContainer.layer?.cornerRadius = CGFloat(Radius.ml)
      cardContainer.layer?.borderWidth = 1
      cardContainer.addGestureRecognizer(cardClickGesture)
      addSubview(cardContainer)

      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.wantsLayer = true
      cardContainer.addSubview(accentBar)

      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.imageScaling = .scaleProportionallyDown
      cardContainer.addSubview(iconView)

      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      titleLabel.textColor = NSColor(Color.textPrimary)
      titleLabel.lineBreakMode = .byWordWrapping
      titleLabel.maximumNumberOfLines = 0
      cardContainer.addSubview(titleLabel)

      subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
      subtitleLabel.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      subtitleLabel.textColor = NSColor(Color.textSecondary)
      subtitleLabel.lineBreakMode = .byWordWrapping
      subtitleLabel.maximumNumberOfLines = 0
      cardContainer.addSubview(subtitleLabel)

      detailStack.translatesAutoresizingMaskIntoConstraints = false
      detailStack.orientation = .vertical
      detailStack.spacing = 3
      detailStack.alignment = .width
      detailStack.distribution = .fill
      detailStack.detachesHiddenViews = true
      cardContainer.addSubview(detailStack)

      actionButton.translatesAutoresizingMaskIntoConstraints = false
      actionButton.bezelStyle = .rounded
      actionButton.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
      actionButton.wantsLayer = true
      actionButton.layer?.cornerRadius = CGFloat(Radius.md)
      actionButton.layer?.masksToBounds = true
      actionButton.layer?.backgroundColor = NSColor(Color.statusQuestion).withAlphaComponent(0.8).cgColor
      actionButton.contentTintColor = .white
      actionButton.target = self
      actionButton.action = #selector(actionButtonClicked)
      cardContainer.addSubview(actionButton)

      let inset = ConversationLayout.laneHorizontalInset
      let pad: CGFloat = 10
      NSLayoutConstraint.activate([
        cardContainer.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        cardContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        cardContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        cardContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

        accentBar.topAnchor.constraint(equalTo: cardContainer.topAnchor),
        accentBar.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
        accentBar.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),
        accentBar.widthAnchor.constraint(equalToConstant: 2),

        iconView.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: pad),
        iconView.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: pad),
        iconView.widthAnchor.constraint(equalToConstant: 14),
        iconView.heightAnchor.constraint(equalToConstant: 14),

        titleLabel.topAnchor.constraint(equalTo: iconView.topAnchor),
        titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
        titleLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        subtitleLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        detailStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
        detailStack.leadingAnchor.constraint(equalTo: subtitleLabel.leadingAnchor),
        detailStack.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -pad),

        actionButton.topAnchor.constraint(equalTo: detailStack.bottomAnchor, constant: 8),
        actionButton.leadingAnchor.constraint(equalTo: subtitleLabel.leadingAnchor),
        actionButton.trailingAnchor.constraint(lessThanOrEqualTo: cardContainer.trailingAnchor, constant: -pad),
        actionButton.heightAnchor.constraint(equalToConstant: 24),
        actionButton.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor, constant: -pad),
      ])
    }

    func configure(model: ApprovalCardModel) {
      currentModel = model
      clearDetailRows()

      let header = ApprovalCardConfiguration.headerConfig(for: model, mode: model.mode)
      let tint = NSColor(model.risk.tintColor)
      cardContainer.layer?.borderColor = tint.withAlphaComponent(0.28).cgColor
      cardContainer.layer?.backgroundColor = NSColor(Color.backgroundSecondary).withAlphaComponent(0.84).cgColor
      accentBar.layer?.backgroundColor = tint.withAlphaComponent(0.72).cgColor

      iconView.image = NSImage(systemSymbolName: header.iconName, accessibilityDescription: nil)
      iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.caption, weight: .semibold)
      iconView.contentTintColor = tint
      titleLabel.stringValue = header.label

      switch model.mode {
        case .permission:
          configurePermissionSummary(model)
        case .question:
          configureQuestionSummary(model)
        case .takeover:
          configureTakeOverSummary(model)
        case .none:
          subtitleLabel.stringValue = ""
          actionButton.isHidden = true
      }
    }

    private func configurePermissionSummary(_ model: ApprovalCardModel) {
      let segmentLines = ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model)
      subtitleLabel.stringValue = segmentLines.count > 1
        ? "\(segmentLines.count)-step command chain awaiting approval."
        : "Command awaiting approval."
      if !segmentLines.isEmpty {
        for line in segmentLines {
          addDetailRow(line, monospaced: true)
        }
      } else if let command = model.command, !command.isEmpty {
        addDetailRow(command, monospaced: true)
      } else if let path = model.filePath, !path.isEmpty {
        addDetailRow(path, monospaced: true)
      }
      if !model.riskFindings.isEmpty {
        addDetailRow("Risk: \(model.riskFindings[0])")
        if model.riskFindings.count > 1 {
          addDetailRow("+\(model.riskFindings.count - 1) more risk check\(model.riskFindings.count == 2 ? "" : "s")")
        }
      }

      actionButton.title = "Open Composer"
      actionButton.isHidden = false
      actionButton.layer?.backgroundColor = NSColor(Color.statusPermission).withAlphaComponent(0.68).cgColor
    }

    private func configureQuestionSummary(_ model: ApprovalCardModel) {
      let promptCount = model.questions.count
      subtitleLabel.stringValue = promptCount > 0
        ? "\(promptCount) question\(promptCount == 1 ? "" : "s") waiting in composer."
        : "A response is required before the session can continue."

      if !model.questions.isEmpty {
        for (index, prompt) in model.questions.prefix(2).enumerated() {
          let header = prompt.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          if header.isEmpty {
            addDetailRow("\(index + 1). Question \(index + 1)")
          } else {
            addDetailRow("\(index + 1). \(header.uppercased())")
          }
        }
        if model.questions.count > 2 {
          addDetailRow("+\(model.questions.count - 2) more")
        }
      }

      actionButton.title = "Open Composer"
      actionButton.isHidden = false
      actionButton.layer?.backgroundColor = NSColor(Color.statusQuestion).withAlphaComponent(0.7).cgColor
    }

    private func configureTakeOverSummary(_ model: ApprovalCardModel) {
      subtitleLabel.stringValue = "Manual takeover required in composer."
      if let toolName = model.toolName, !toolName.isEmpty {
        addDetailRow("Pending tool: \(toolName)")
      }

      actionButton.title = "Open Composer"
      actionButton.isHidden = false
      actionButton.layer?.backgroundColor = NSColor(Color.accent).withAlphaComponent(0.7).cgColor
    }

    private func clearDetailRows() {
      for view in detailStack.arrangedSubviews {
        detailStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
    }

    private func addDetailRow(_ text: String, monospaced: Bool = false) {
      let label = NSTextField(wrappingLabelWithString: text)
      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = monospaced
        ? NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
        : NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      label.textColor = NSColor(Color.textTertiary)
      label.lineBreakMode = monospaced ? .byCharWrapping : .byWordWrapping
      label.maximumNumberOfLines = 0
      detailStack.addArrangedSubview(label)
      label.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
    }

    @objc private func actionButtonClicked() {
      openComposerPanel()
    }

    @objc private func cardClicked(_ gesture: NSClickGestureRecognizer) {
      let point = gesture.location(in: cardContainer)
      guard !actionButton.frame.contains(point) else { return }
      openComposerPanel()
    }

    private func openComposerPanel() {
      guard let model = currentModel else { return }

      NotificationCenter.default.post(
        name: .openPendingActionPanel,
        object: nil,
        userInfo: ["sessionId": model.sessionId]
      )
    }

    static func requiredHeight(for model: ApprovalCardModel?, availableWidth: CGFloat) -> CGFloat {
      guard let model else { return 104 }

      let laneInset = ConversationLayout.laneHorizontalInset
      let contentWidth = max(220, availableWidth - laneInset * 2 - 20 - 20)

      var textBlocks: [String] = []
      switch model.mode {
        case .permission:
          let segmentLines = ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model)
          textBlocks.append(
            segmentLines.count > 1
              ? "\(segmentLines.count)-step command chain awaiting approval."
              : "Command awaiting approval."
          )
          if !segmentLines.isEmpty {
            textBlocks.append(contentsOf: segmentLines)
          } else if let command = model.command, !command.isEmpty {
            textBlocks.append(command)
          } else if let path = model.filePath, !path.isEmpty {
            textBlocks.append(path)
          }
          if let firstFinding = model.riskFindings.first {
            textBlocks.append("Risk: \(firstFinding)")
          }
          if model.riskFindings.count > 1 {
            textBlocks
              .append("+\(model.riskFindings.count - 1) more risk check\(model.riskFindings.count == 2 ? "" : "s")")
          }
        case .question:
          if model.questions.isEmpty {
            textBlocks.append("Response required")
          } else {
            textBlocks.append(contentsOf: model.questions.prefix(2).map {
              let header = $0.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              return header.isEmpty ? $0.question : header
            })
          }
        case .takeover:
          textBlocks.append("Manual takeover required in composer.")
        case .none:
          break
      }

      var h: CGFloat = 10
      h += 10 + 14 + 4
      h += measuredHeight(
        textBlocks.first ?? "",
        font: NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium),
        width: contentWidth
      )
      if textBlocks.count > 1 {
        let detailFont: NSFont = model.mode == .permission
          ? NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
          : NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
        let detailCharWrap = model.mode == .permission
        for row in textBlocks.dropFirst() {
          h += 6
          h += measuredHeight(
            row,
            font: detailFont,
            width: contentWidth,
            charWrap: detailCharWrap
          )
        }
      }
      h += 8 + 24 + 10
      h += 10

      let maxHeight: CGFloat = model.mode == .permission ? .greatestFiniteMagnitude : 178
      return max(104, min(h, maxHeight))
    }

    private static func measuredHeight(
      _ text: String,
      font: NSFont,
      width: CGFloat,
      charWrap: Bool = false
    ) -> CGFloat {
      guard !text.isEmpty else { return 0 }
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.lineBreakMode = charWrap ? .byCharWrapping : .byWordWrapping
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: paragraphStyle,
      ]
      let rect = NSAttributedString(string: text, attributes: attributes).boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      )
      return ceil(rect.height)
    }
  }

#endif
