//
//  UIKitApprovalCardCell.swift
//  OrbitDock
//
//  Compact iOS approval/question summary card for the conversation timeline.
//  Detailed interaction now lives in the composer pending-action panel.
//

#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitApprovalCardCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitApprovalCardCell"

    private let cardContainer = UIView()
    private let accentBar = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let detailStack = UIStackView()
    private let actionButton = UIButton(type: .system)
    private lazy var cardTapGesture: UITapGestureRecognizer = {
      let gesture = UITapGestureRecognizer(target: self, action: #selector(cardTapped(_:)))
      gesture.cancelsTouchesInView = false
      return gesture
    }()

    private var currentModel: ApprovalCardModel?

    override init(frame: CGRect) {
      super.init(frame: frame)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    private func setup() {
      backgroundColor = .clear
      contentView.backgroundColor = .clear

      cardContainer.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.layer.cornerRadius = CGFloat(Radius.ml)
      cardContainer.layer.borderWidth = 1
      cardContainer.clipsToBounds = true
      cardContainer.addGestureRecognizer(cardTapGesture)
      contentView.addSubview(cardContainer)

      accentBar.translatesAutoresizingMaskIntoConstraints = false
      cardContainer.addSubview(accentBar)

      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.contentMode = .scaleAspectFit
      cardContainer.addSubview(iconView)

      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      titleLabel.textColor = UIColor(Color.textPrimary)
      titleLabel.numberOfLines = 0
      titleLabel.lineBreakMode = .byWordWrapping
      cardContainer.addSubview(titleLabel)

      subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
      subtitleLabel.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      subtitleLabel.textColor = UIColor(Color.textSecondary)
      subtitleLabel.numberOfLines = 0
      subtitleLabel.lineBreakMode = .byWordWrapping
      cardContainer.addSubview(subtitleLabel)

      detailStack.translatesAutoresizingMaskIntoConstraints = false
      detailStack.axis = .vertical
      detailStack.spacing = 3
      detailStack.alignment = .fill
      detailStack.distribution = .fill
      cardContainer.addSubview(detailStack)

      actionButton.translatesAutoresizingMaskIntoConstraints = false
      actionButton.titleLabel?.font = UIFont.systemFont(ofSize: TypeScale.micro, weight: .semibold)
      actionButton.setTitleColor(.white, for: .normal)
      actionButton.layer.cornerRadius = CGFloat(Radius.md)
      actionButton.addTarget(self, action: #selector(actionButtonTapped), for: .touchUpInside)
      cardContainer.addSubview(actionButton)

      let inset = ConversationLayout.laneHorizontalInset
      let pad: CGFloat = 10
      NSLayoutConstraint.activate([
        cardContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
        cardContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        cardContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        cardContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

        accentBar.topAnchor.constraint(equalTo: cardContainer.topAnchor),
        accentBar.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
        accentBar.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),
        accentBar.widthAnchor.constraint(equalToConstant: 2),

        iconView.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: pad),
        iconView.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: pad),
        iconView.widthAnchor.constraint(equalToConstant: 15),
        iconView.heightAnchor.constraint(equalToConstant: 15),

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
        actionButton.heightAnchor.constraint(equalToConstant: 30),
        actionButton.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor, constant: -pad),
      ])
    }

    func configure(model: ApprovalCardModel) {
      currentModel = model
      clearDetailRows()

      let header = ApprovalCardConfiguration.headerConfig(for: model, mode: model.mode)
      let tint = UIColor(model.risk.tintColor)
      cardContainer.layer.borderColor = tint.withAlphaComponent(0.28).cgColor
      cardContainer.backgroundColor = UIColor(Color.backgroundSecondary).withAlphaComponent(0.86)
      accentBar.backgroundColor = tint.withAlphaComponent(0.72)

      iconView.image = UIImage(systemName: header.iconName)
      iconView.tintColor = tint
      titleLabel.text = header.label

      switch model.mode {
        case .permission:
          configurePermissionSummary(model)
        case .question:
          configureQuestionSummary(model)
        case .takeover:
          configureTakeOverSummary(model)
        case .none:
          subtitleLabel.text = nil
          actionButton.isHidden = true
      }
    }

    private func configurePermissionSummary(_ model: ApprovalCardModel) {
      let segmentLines = ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model)
      subtitleLabel.text = segmentLines.count > 1
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

      actionButton.setTitle("Open Composer", for: .normal)
      actionButton.isHidden = false
      actionButton.backgroundColor = UIColor(Color.statusPermission).withAlphaComponent(0.7)
    }

    private func configureQuestionSummary(_ model: ApprovalCardModel) {
      let promptCount = model.questions.count
      subtitleLabel.text = promptCount > 0
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

      actionButton.setTitle("Open Composer", for: .normal)
      actionButton.isHidden = false
      actionButton.backgroundColor = UIColor(Color.statusQuestion).withAlphaComponent(0.72)
    }

    private func configureTakeOverSummary(_ model: ApprovalCardModel) {
      subtitleLabel.text = "Manual takeover required in composer."
      if let toolName = model.toolName, !toolName.isEmpty {
        addDetailRow("Pending tool: \(toolName)")
      }

      actionButton.setTitle("Open Composer", for: .normal)
      actionButton.isHidden = false
      actionButton.backgroundColor = UIColor(Color.accent).withAlphaComponent(0.72)
    }

    private func clearDetailRows() {
      for view in detailStack.arrangedSubviews {
        detailStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
    }

    private func addDetailRow(_ text: String, monospaced: Bool = false) {
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = monospaced
        ? UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
        : UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
      label.textColor = UIColor(Color.textTertiary)
      label.numberOfLines = 0
      label.lineBreakMode = monospaced ? .byCharWrapping : .byWordWrapping
      label.text = text
      detailStack.addArrangedSubview(label)
    }

    @objc private func actionButtonTapped() {
      openComposerPanel()
    }

    @objc private func cardTapped(_ gesture: UITapGestureRecognizer) {
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
      guard let model else { return 110 }

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
      h += 10 + 15 + 4
      h += measuredHeight(
        textBlocks.first ?? "",
        font: UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium),
        width: contentWidth
      )
      if textBlocks.count > 1 {
        let detailFont: UIFont = model.mode == .permission
          ? UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
          : UIFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
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
      h += 8 + 30 + 10
      h += 10

      let maxHeight: CGFloat = model.mode == .permission ? .greatestFiniteMagnitude : 196
      return max(110, min(h, maxHeight))
    }

    private static func measuredHeight(
      _ text: String,
      font: UIFont,
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
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
      return ceil(rect.height)
    }
  }

#endif
