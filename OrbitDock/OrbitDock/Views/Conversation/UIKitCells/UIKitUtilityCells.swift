//
//  UIKitUtilityCells.swift
//  OrbitDock
//
//  Native UICollectionViewCell subclasses for structural/utility rows on iOS.
//  Ports macOS NativeTurnHeaderCellView, NativeRollupSummaryCellView,
//  NativeLoadMoreCellView, NativeMessageCountCellView, NativeSpacerCellView.
//  All fixed height (see ConversationLayout).
//

#if os(iOS)

  import SwiftUI
  import UIKit

  // MARK: - Turn Header Cell (40pt)

  final class UIKitTurnHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitTurnHeaderCell"

    private let dividerLine = UIView()
    private let turnLabel = UILabel()
    private let statusCapsule = UIView()
    private let statusLabel = UILabel()
    private let toolsLabel = UILabel()

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

      let inset = ConversationLayout.laneHorizontalInset

      // Divider
      dividerLine.backgroundColor = UIColor(Color.textQuaternary).withAlphaComponent(0.5)
      dividerLine.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(dividerLine)

      // Turn label
      turnLabel.font = Self.roundedFont(size: 10, weight: .bold)
      turnLabel.textColor = UIColor(Color.textSecondary)
      turnLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(turnLabel)

      // Status capsule
      statusCapsule.layer.cornerRadius = 8
      statusCapsule.layer.masksToBounds = true
      statusCapsule.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(statusCapsule)

      // Status label
      statusLabel.font = Self.roundedFont(size: 9, weight: .bold)
      statusLabel.translatesAutoresizingMaskIntoConstraints = false
      statusCapsule.addSubview(statusLabel)

      // Tools label
      toolsLabel.font = UIFont.systemFont(ofSize: 10, weight: .medium)
      toolsLabel.textColor = UIColor(Color.textTertiary)
      toolsLabel.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(toolsLabel)

      NSLayoutConstraint.activate([
        dividerLine.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
        dividerLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        dividerLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
        dividerLine.heightAnchor.constraint(equalToConstant: 1),

        turnLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
        turnLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 4),

        statusCapsule.leadingAnchor.constraint(equalTo: turnLabel.trailingAnchor, constant: 10),
        statusCapsule.centerYAnchor.constraint(equalTo: turnLabel.centerYAnchor),

        statusLabel.topAnchor.constraint(equalTo: statusCapsule.topAnchor, constant: 3),
        statusLabel.bottomAnchor.constraint(equalTo: statusCapsule.bottomAnchor, constant: -3),
        statusLabel.leadingAnchor.constraint(equalTo: statusCapsule.leadingAnchor, constant: 7),
        statusLabel.trailingAnchor.constraint(equalTo: statusCapsule.trailingAnchor, constant: -7),

        toolsLabel.leadingAnchor.constraint(equalTo: statusCapsule.trailingAnchor, constant: 10),
        toolsLabel.centerYAnchor.constraint(equalTo: turnLabel.centerYAnchor),
      ])
    }

    func configure(turn: TurnSummary) {
      let turnAttrs: [NSAttributedString.Key: Any] = [
        .font: turnLabel.font as Any,
        .foregroundColor: turnLabel.textColor as Any,
        .kern: 1.0,
      ]
      turnLabel.attributedText = NSAttributedString(
        string: "TURN \(turn.turnNumber)",
        attributes: turnAttrs
      )

      let (label, color) = statusInfo(for: turn.status)
      let statusAttrs: [NSAttributedString.Key: Any] = [
        .font: statusLabel.font as Any,
        .foregroundColor: color,
        .kern: 0.8,
      ]
      statusLabel.attributedText = NSAttributedString(string: label, attributes: statusAttrs)
      statusCapsule.backgroundColor = color.withAlphaComponent(0.16)

      if turn.toolsUsed.isEmpty {
        toolsLabel.isHidden = true
      } else {
        toolsLabel.isHidden = false
        toolsLabel.text = "\(turn.toolsUsed.count) tools"
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      toolsLabel.isHidden = false
    }

    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
      let base = UIFont.systemFont(ofSize: size, weight: weight)
      if let rounded = base.fontDescriptor.withDesign(.rounded) {
        return UIFont(descriptor: rounded, size: size)
      }
      return base
    }

    private func statusInfo(for status: TurnStatus) -> (String, UIColor) {
      switch status {
        case .active:
          ("ACTIVE", UIColor(Color.accent))
        case .completed:
          ("DONE", UIColor(Color.textTertiary))
        case .failed:
          ("FAILED", UIColor(red: 0.95, green: 0.48, blue: 0.42, alpha: 1))
      }
    }
  }

  // MARK: - Rollup Summary Cell (40pt)

  final class UIKitRollupSummaryCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitRollupSummaryCell"

    private let accentLine = UIView()
    private let backgroundBox = UIView()
    private let chevronImage = UIImageView()
    private let countLabel = UILabel()
    private let actionsLabel = UILabel()
    private let separatorDot = UIView()
    private let breakdownStack = UIStackView()
    var onToggle: (() -> Void)?

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

      let inset = ConversationLayout.laneHorizontalInset

      // Accent line
      accentLine.backgroundColor = UIColor(Color.textQuaternary).withAlphaComponent(0.4)
      accentLine.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(accentLine)

      // Background pill
      backgroundBox.layer.cornerRadius = Radius.lg
      backgroundBox.layer.masksToBounds = true
      backgroundBox.backgroundColor = UIColor(Color.backgroundTertiary).withAlphaComponent(0.7)
      backgroundBox.layer.borderWidth = 0.5
      backgroundBox.layer.borderColor = UIColor(Color.surfaceBorder).withAlphaComponent(0.4).cgColor
      backgroundBox.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(backgroundBox)

      // Chevron
      let symbolConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
      chevronImage.preferredSymbolConfiguration = symbolConfig
      chevronImage.translatesAutoresizingMaskIntoConstraints = false
      backgroundBox.addSubview(chevronImage)

      // Count label
      countLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
      countLabel.textColor = UIColor(Color.textPrimary)
      countLabel.translatesAutoresizingMaskIntoConstraints = false
      backgroundBox.addSubview(countLabel)

      // Actions label
      actionsLabel.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      actionsLabel.textColor = UIColor(Color.textSecondary)
      actionsLabel.text = "actions"
      actionsLabel.translatesAutoresizingMaskIntoConstraints = false
      backgroundBox.addSubview(actionsLabel)

      // Separator dot
      separatorDot.layer.cornerRadius = 1.5
      separatorDot.backgroundColor = UIColor(Color.surfaceBorder)
      separatorDot.translatesAutoresizingMaskIntoConstraints = false
      backgroundBox.addSubview(separatorDot)

      // Breakdown stack
      breakdownStack.axis = .horizontal
      breakdownStack.spacing = 12
      breakdownStack.alignment = .center
      breakdownStack.translatesAutoresizingMaskIntoConstraints = false
      backgroundBox.addSubview(breakdownStack)

      NSLayoutConstraint.activate([
        accentLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset + 6),
        accentLine.widthAnchor.constraint(equalToConstant: 2),
        accentLine.topAnchor.constraint(equalTo: contentView.topAnchor),
        accentLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

        backgroundBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset + 16),
        backgroundBox.trailingAnchor.constraint(
          lessThanOrEqualTo: contentView.trailingAnchor,
          constant: -inset
        ),
        backgroundBox.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
        backgroundBox.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

        chevronImage.leadingAnchor.constraint(equalTo: backgroundBox.leadingAnchor, constant: 14),
        chevronImage.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),
        chevronImage.widthAnchor.constraint(equalToConstant: 10),

        countLabel.leadingAnchor.constraint(equalTo: chevronImage.trailingAnchor, constant: 6),
        countLabel.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),

        actionsLabel.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 4),
        actionsLabel.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),

        separatorDot.leadingAnchor.constraint(equalTo: actionsLabel.trailingAnchor, constant: 16),
        separatorDot.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),
        separatorDot.widthAnchor.constraint(equalToConstant: 3),
        separatorDot.heightAnchor.constraint(equalToConstant: 3),

        breakdownStack.leadingAnchor.constraint(equalTo: separatorDot.trailingAnchor, constant: 16),
        breakdownStack.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),
        breakdownStack.trailingAnchor.constraint(
          lessThanOrEqualTo: backgroundBox.trailingAnchor,
          constant: -14
        ),
      ])

      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
      contentView.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
      onToggle?()
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onToggle = nil
    }

    func configure(
      hiddenCount: Int, totalToolCount: Int, isExpanded: Bool,
      breakdown: [ToolBreakdownEntry]
    ) {
      let symbolName = isExpanded ? "chevron.down" : "chevron.right"
      chevronImage.image = UIImage(systemName: symbolName)

      let lineColor = isExpanded
        ? UIColor(Color.textQuaternary).withAlphaComponent(0.3)
        : UIColor(Color.textQuaternary).withAlphaComponent(0.4)
      accentLine.backgroundColor = lineColor

      if isExpanded {
        chevronImage.tintColor = UIColor(Color.textTertiary)
        countLabel.isHidden = true
        actionsLabel.textColor = UIColor(Color.textTertiary)
        actionsLabel.text = "Collapse tools"
        separatorDot.isHidden = true
        breakdownStack.isHidden = true
        backgroundBox.backgroundColor = UIColor.white.withAlphaComponent(0.02)
        backgroundBox.layer.borderColor = UIColor.clear.cgColor
      } else {
        chevronImage.tintColor = UIColor(Color.textSecondary)
        countLabel.isHidden = false
        countLabel.text = "\(hiddenCount)"
        actionsLabel.textColor = UIColor(Color.textSecondary)
        actionsLabel.text = "actions"
        separatorDot.isHidden = breakdown.isEmpty
        breakdownStack.isHidden = breakdown.isEmpty
        backgroundBox.backgroundColor =
          UIColor(Color.backgroundTertiary).withAlphaComponent(0.7)
        backgroundBox.layer.borderColor =
          UIColor(Color.surfaceBorder).withAlphaComponent(0.4).cgColor

        rebuildBreakdownChips(breakdown)
      }
    }

    private func rebuildBreakdownChips(_ breakdown: [ToolBreakdownEntry]) {
      breakdownStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

      for entry in breakdown.prefix(6) {
        let chip = UIStackView()
        chip.axis = .horizontal
        chip.spacing = 5
        chip.alignment = .center

        let icon = UIImageView()
        icon.image = UIImage(systemName: entry.icon)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        icon.tintColor = UIColor(Self.toolColor(for: entry.colorKey))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let count = UILabel()
        count.font = UIFont.monospacedDigitSystemFont(ofSize: TypeScale.body, weight: .bold)
        count.textColor = UIColor(Color.textSecondary)
        count.text = "\(entry.count)"

        let name = UILabel()
        name.font = UIFont.systemFont(ofSize: TypeScale.body, weight: .medium)
        name.textColor = UIColor(Color.textTertiary)
        name.text = Self.displayName(for: entry.name)
        name.lineBreakMode = .byTruncatingTail

        chip.addArrangedSubview(icon)
        chip.addArrangedSubview(count)
        chip.addArrangedSubview(name)
        breakdownStack.addArrangedSubview(chip)
      }
    }

    private static func toolColor(for key: String) -> Color {
      switch key {
        case "bash": .toolBash
        case "read": .toolRead
        case "write": .toolWrite
        case "search": .toolSearch
        case "task": .toolTask
        case "web": .toolWeb
        case "skill": .toolSkill
        case "plan": .toolPlan
        case "todo": .toolTodo
        case "question": .toolQuestion
        case "mcp": .toolMcp
        default: .textSecondary
      }
    }

    private static func displayName(for toolName: String) -> String {
      let lowered = toolName.lowercased()
      switch lowered {
        case "bash": return "Bash"
        case "read": return "Read"
        case "edit": return "Edit"
        case "write": return "Write"
        case "glob": return "Glob"
        case "grep": return "Grep"
        case "task": return "Task"
        case "webfetch": return "Fetch"
        case "websearch": return "Search"
        case "skill": return "Skill"
        case "enterplanmode", "exitplanmode": return "Plan"
        case "taskcreate", "taskupdate", "tasklist", "taskget": return "Todo"
        case "askuserquestion": return "Question"
        case "notebookedit": return "Notebook"
        default:
          if toolName.hasPrefix("mcp__") {
            return toolName
              .replacingOccurrences(of: "mcp__", with: "")
              .components(separatedBy: "__").last ?? "MCP"
          }
          return toolName
      }
    }
  }

  // MARK: - Load More Cell (38pt)

  final class UIKitLoadMoreCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitLoadMoreCell"

    private let button = UIButton(type: .system)
    var onLoadMore: (() -> Void)?

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

      button.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .medium)
      button.setTitleColor(UIColor(Color.accent), for: .normal)
      button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
      button.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(button)

      NSLayoutConstraint.activate([
        button.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        button.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      ])
    }

    @objc private func handleTap() {
      onLoadMore?()
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      onLoadMore = nil
    }

    func configure(remainingCount: Int) {
      button.setTitle("Load \(remainingCount) earlier messages", for: .normal)
    }
  }

  // MARK: - Message Count Cell (24pt)

  final class UIKitMessageCountCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitMessageCountCell"

    private let label = UILabel()

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

      label.font = UIFont.systemFont(ofSize: 10, weight: .medium)
      label.textColor = UIColor(Color.textTertiary)
      label.textAlignment = .center
      label.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(label)

      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      ])
    }

    func configure(displayedCount: Int, totalCount: Int) {
      label.text = "Showing \(displayedCount) of \(totalCount) messages"
    }
  }

  // MARK: - Spacer Cell (32pt)

  final class UIKitSpacerCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitSpacerCell"

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      backgroundColor = .clear
      contentView.backgroundColor = .clear
    }
  }

  // MARK: - Live Indicator Cell (40pt)

  final class UIKitLiveIndicatorCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitLiveIndicatorCell"
    static let cellHeight: CGFloat = 40

    private let dotView = UIView()
    private let iconView = UIImageView()
    private let primaryLabel = UILabel()
    private let separatorLabel = UILabel()
    private let detailLabel = UILabel()

    private static let dotSize: CGFloat = 6
    private static let statusColumnWidth: CGFloat = 20
    private static let hInset = ConversationLayout.metadataHorizontalInset
    private static let itemSpacing = Spacing.xs

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      contentView.backgroundColor = .clear
      setupSubviews()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setupSubviews()
    }

    private func setupSubviews() {
      dotView.layer.cornerRadius = Self.dotSize / 2
      dotView.clipsToBounds = true
      contentView.addSubview(dotView)

      iconView.contentMode = .center
      iconView.tintColor = UIColor(Color.statusPermission)
      contentView.addSubview(iconView)

      primaryLabel.font = .systemFont(ofSize: TypeScale.body, weight: .medium)
      contentView.addSubview(primaryLabel)

      separatorLabel.text = "\u{00B7}"
      separatorLabel.font = .systemFont(ofSize: TypeScale.body)
      separatorLabel.textColor = UIColor(Color.textQuaternary)
      contentView.addSubview(separatorLabel)

      detailLabel.font = .systemFont(ofSize: TypeScale.body)
      detailLabel.lineBreakMode = .byTruncatingTail
      contentView.addSubview(detailLabel)
    }

    struct Model {
      let workStatus: Session.WorkStatus
      let currentTool: String?
      let currentPrompt: String?
      let pendingToolName: String?
      let pendingToolInput: String?
      let provider: Provider
    }

    func configure(model: Model) {
      let h = Self.cellHeight
      let hInset = Self.hInset
      let dotSize = Self.dotSize
      let colW = Self.statusColumnWidth
      let sp = Self.itemSpacing

      // Reset visibility
      dotView.isHidden = true
      iconView.isHidden = true
      separatorLabel.isHidden = true
      detailLabel.isHidden = true

      // Status column center
      let colX = hInset
      let dotY = (h - dotSize) / 2

      // Text origin
      let textX = colX + colW + sp
      let maxTextW = contentView.bounds.width - textX - hInset

      switch model.workStatus {
        case .working:
          dotView.isHidden = false
          dotView.backgroundColor = UIColor(Color.statusWorking)
          dotView.frame = CGRect(x: colX + (colW - dotSize) / 2, y: dotY, width: dotSize, height: dotSize)

          primaryLabel.text = "Working"
          primaryLabel.textColor = UIColor(Color.statusWorking)
          primaryLabel.sizeToFit()
          primaryLabel.frame.origin = CGPoint(x: textX, y: (h - primaryLabel.frame.height) / 2)

          if let tool = model.currentTool {
            separatorLabel.isHidden = false
            separatorLabel.sizeToFit()
            separatorLabel.frame.origin = CGPoint(
              x: primaryLabel.frame.maxX + sp, y: (h - separatorLabel.frame.height) / 2
            )
            detailLabel.isHidden = false
            detailLabel.text = tool
            detailLabel.font = .monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
            detailLabel.textColor = UIColor(Color.textTertiary)
            let detailX = separatorLabel.frame.maxX + sp
            let detailW = max(0, maxTextW - (detailX - textX))
            detailLabel.frame = CGRect(
              x: detailX,
              y: (h - primaryLabel.frame.height) / 2,
              width: detailW,
              height: primaryLabel.frame.height
            )
          }

        case .waiting:
          dotView.isHidden = false
          dotView.backgroundColor = UIColor(Color.statusReply)
          dotView.frame = CGRect(x: colX + (colW - dotSize) / 2, y: dotY, width: dotSize, height: dotSize)

          primaryLabel.text = "Your turn"
          primaryLabel.textColor = UIColor(Color.statusReply)
          primaryLabel.sizeToFit()
          primaryLabel.frame.origin = CGPoint(x: textX, y: (h - primaryLabel.frame.height) / 2)

          separatorLabel.isHidden = false
          separatorLabel.sizeToFit()
          separatorLabel.frame.origin = CGPoint(
            x: primaryLabel.frame.maxX + sp, y: (h - separatorLabel.frame.height) / 2
          )
          detailLabel.isHidden = false
          detailLabel.text = model.provider == .codex ? "Send a message below" : "Respond in terminal"
          detailLabel.font = .systemFont(ofSize: TypeScale.body)
          detailLabel.textColor = UIColor(Color.textTertiary)
          let detailX = separatorLabel.frame.maxX + sp
          let detailW = max(0, maxTextW - (detailX - textX))
          detailLabel.frame = CGRect(
            x: detailX,
            y: (h - primaryLabel.frame.height) / 2,
            width: detailW,
            height: primaryLabel.frame.height
          )

        case .permission:
          iconView.isHidden = false
          let iconConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
          iconView.image = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: iconConfig)
          iconView.tintColor = UIColor(Color.statusPermission)
          iconView.frame = CGRect(x: colX, y: 0, width: colW, height: h)

          primaryLabel.text = "Permission"
          primaryLabel.textColor = UIColor(Color.statusPermission)
          primaryLabel.sizeToFit()
          primaryLabel.frame.origin = CGPoint(x: textX, y: (h - primaryLabel.frame.height) / 2)

          var nextX = primaryLabel.frame.maxX

          if let toolName = model.pendingToolName {
            separatorLabel.isHidden = false
            separatorLabel.sizeToFit()
            separatorLabel.frame.origin = CGPoint(
              x: nextX + sp, y: (h - separatorLabel.frame.height) / 2
            )
            nextX = separatorLabel.frame.maxX + sp

            let toolLabel = UILabel()
            toolLabel.text = toolName
            toolLabel.font = .systemFont(ofSize: TypeScale.body, weight: .bold)
            toolLabel.textColor = UIColor(Color.textPrimary)
            toolLabel.sizeToFit()
            toolLabel.frame.origin = CGPoint(x: nextX, y: (h - toolLabel.frame.height) / 2)
            contentView.addSubview(toolLabel)
            nextX = toolLabel.frame.maxX
          }

          if let detail = permissionDetail(toolName: model.pendingToolName, toolInput: model.pendingToolInput) {
            detailLabel.isHidden = false
            detailLabel.text = detail
            detailLabel.font = .monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
            detailLabel.textColor = UIColor(Color.textSecondary)
            let detailX = nextX + sp
            let detailW = max(0, maxTextW - (detailX - textX))
            detailLabel.frame = CGRect(
              x: detailX,
              y: (h - primaryLabel.frame.height) / 2,
              width: detailW,
              height: primaryLabel.frame.height
            )
          }

        case .unknown:
          primaryLabel.text = ""
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      // Remove any dynamically added tool name labels from permission state
      for sub in contentView.subviews
        where sub !== dotView && sub !== iconView && sub !== primaryLabel && sub !== separatorLabel && sub !==
        detailLabel
      {
        sub.removeFromSuperview()
      }
    }

    private func permissionDetail(toolName: String?, toolInput: String?) -> String? {
      guard let inputJson = toolInput,
            let data = inputJson.data(using: .utf8),
            let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }

      let name = toolName ?? ""
      switch name {
        case "Bash":
          if let cmd = String.shellCommandDisplay(from: input["command"])
            ?? String.shellCommandDisplay(from: input["cmd"])
          {
            return cmd.count > 50 ? String(cmd.prefix(47)) + "\u{2026}" : cmd
          }
        case "Edit", "Write", "Read":
          if let path = input["file_path"] as? String {
            return (path as NSString).lastPathComponent
          }
        default:
          break
      }
      return nil
    }
  }

#endif
