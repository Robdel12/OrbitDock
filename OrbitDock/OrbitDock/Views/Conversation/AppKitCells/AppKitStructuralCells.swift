//
//  AppKitStructuralCells.swift
//  OrbitDock
//
//  macOS-specific NSTableCellView subclasses for structural timeline rows:
//  spacers, turn headers, rollup summaries, load-more buttons, message counts,
//  and compact tool rows.
//

#if os(macOS)

  import AppKit
  import SwiftUI

  // MARK: - Spacer Cell

  final class NativeSpacerCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeSpacerCell")

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
    }
  }

  // MARK: - Turn Header Cell

  final class NativeTurnHeaderCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeTurnHeaderCell")

    private let dividerLine = NSView()
    private let turnLabel = NSTextField(labelWithString: "")
    private let statusCapsule = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let toolsLabel = NSTextField(labelWithString: "")

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

      // Subtle horizontal divider at the top of the cell
      dividerLine.wantsLayer = true
      dividerLine.layer?.backgroundColor = NSColor(Color.textQuaternary).withAlphaComponent(0.5).cgColor
      dividerLine.translatesAutoresizingMaskIntoConstraints = false
      addSubview(dividerLine)

      turnLabel.translatesAutoresizingMaskIntoConstraints = false
      turnLabel.font = Self.roundedFont(size: 10, weight: .bold)
      turnLabel.textColor = NSColor(Color.textSecondary)
      turnLabel.lineBreakMode = .byTruncatingTail
      addSubview(turnLabel)

      statusCapsule.translatesAutoresizingMaskIntoConstraints = false
      statusCapsule.wantsLayer = true
      statusCapsule.layer?.cornerRadius = 8
      statusCapsule.layer?.masksToBounds = true
      addSubview(statusCapsule)

      statusLabel.translatesAutoresizingMaskIntoConstraints = false
      statusLabel.font = Self.roundedFont(size: 9, weight: .bold)
      statusLabel.lineBreakMode = .byTruncatingTail
      statusCapsule.addSubview(statusLabel)

      toolsLabel.translatesAutoresizingMaskIntoConstraints = false
      toolsLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
      toolsLabel.textColor = NSColor(Color.textTertiary)
      toolsLabel.lineBreakMode = .byTruncatingTail
      addSubview(toolsLabel)

      let inset = ConversationLayout.laneHorizontalInset
      NSLayoutConstraint.activate([
        dividerLine.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        dividerLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        dividerLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        dividerLine.heightAnchor.constraint(equalToConstant: 1),

        turnLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        turnLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4),

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
      // Uppercase labels need wider tracking for legibility (Typography.md §Micro-Typography)
      let turnAttrs: [NSAttributedString.Key: Any] = [
        .font: turnLabel.font as Any,
        .foregroundColor: turnLabel.textColor as Any,
        .kern: 1.0,
      ]
      turnLabel.attributedStringValue = NSAttributedString(
        string: "TURN \(turn.turnNumber)",
        attributes: turnAttrs
      )

      let (label, color) = statusInfo(for: turn.status)
      let statusAttrs: [NSAttributedString.Key: Any] = [
        .font: statusLabel.font as Any,
        .foregroundColor: color,
        .kern: 0.8,
      ]
      statusLabel.attributedStringValue = NSAttributedString(string: label, attributes: statusAttrs)
      statusCapsule.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor

      if turn.toolsUsed.isEmpty {
        toolsLabel.isHidden = true
      } else {
        toolsLabel.isHidden = false
        toolsLabel.stringValue = "\(turn.toolsUsed.count) tools"
      }
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
      let base = NSFont.systemFont(ofSize: size, weight: weight)
      if let rounded = base.fontDescriptor.withDesign(.rounded) {
        return NSFont(descriptor: rounded, size: size) ?? base
      }
      return base
    }

    private func statusInfo(for status: TurnStatus) -> (String, NSColor) {
      switch status {
        case .active:
          ("ACTIVE", NSColor(Color.accent))
        case .completed:
          ("DONE", NSColor(Color.textTertiary))
        case .failed:
          ("FAILED", NSColor(calibratedRed: 0.95, green: 0.48, blue: 0.42, alpha: 1))
      }
    }
  }

  // MARK: - Rollup Summary Cell

  final class NativeRollupSummaryCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeRollupSummaryCell")

    private let accentLine = NSView()
    private let backgroundBox = NSView()
    private let chevronImage = NSImageView()
    private let countLabel = NSTextField(labelWithString: "")
    private let actionsLabel = NSTextField(labelWithString: "")
    private let separatorDot = NSView()
    private let breakdownStack = NSStackView()
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    var onToggle: (() -> Void)?

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

      let inset = ConversationLayout.laneHorizontalInset

      // Thin left accent line — visual thread connector
      accentLine.wantsLayer = true
      accentLine.layer?.backgroundColor = NSColor(Color.textQuaternary).withAlphaComponent(0.4).cgColor
      accentLine.translatesAutoresizingMaskIntoConstraints = false
      addSubview(accentLine)

      // Background pill
      backgroundBox.translatesAutoresizingMaskIntoConstraints = false
      backgroundBox.wantsLayer = true
      backgroundBox.layer?.cornerRadius = Radius.lg
      backgroundBox.layer?.masksToBounds = true
      backgroundBox.layer?.backgroundColor = NSColor(Color.backgroundTertiary).withAlphaComponent(0.7).cgColor
      backgroundBox.layer?.borderWidth = 0.5
      backgroundBox.layer?.borderColor = NSColor(Color.surfaceBorder).withAlphaComponent(0.4).cgColor
      addSubview(backgroundBox)

      // Chevron
      chevronImage.translatesAutoresizingMaskIntoConstraints = false
      chevronImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
      backgroundBox.addSubview(chevronImage)

      // Count — bold monospaced
      countLabel.translatesAutoresizingMaskIntoConstraints = false
      countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
      countLabel.textColor = NSColor(Color.textPrimary)
      backgroundBox.addSubview(countLabel)

      // "actions" label
      actionsLabel.translatesAutoresizingMaskIntoConstraints = false
      actionsLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      actionsLabel.textColor = NSColor(Color.textSecondary)
      actionsLabel.stringValue = "actions"
      backgroundBox.addSubview(actionsLabel)

      // Separator dot
      separatorDot.translatesAutoresizingMaskIntoConstraints = false
      separatorDot.wantsLayer = true
      separatorDot.layer?.cornerRadius = 1.5
      separatorDot.layer?.backgroundColor = NSColor(Color.surfaceBorder).cgColor
      backgroundBox.addSubview(separatorDot)

      // Tool breakdown stack
      breakdownStack.translatesAutoresizingMaskIntoConstraints = false
      breakdownStack.orientation = .horizontal
      breakdownStack.spacing = 12
      breakdownStack.alignment = .centerY
      backgroundBox.addSubview(breakdownStack)

      NSLayoutConstraint.activate([
        accentLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 6),
        accentLine.widthAnchor.constraint(equalToConstant: 2),
        accentLine.topAnchor.constraint(equalTo: topAnchor),
        accentLine.bottomAnchor.constraint(equalTo: bottomAnchor),

        backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 16),
        backgroundBox.trailingAnchor.constraint(
          lessThanOrEqualTo: trailingAnchor,
          constant: -inset
        ),
        backgroundBox.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        backgroundBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

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

      let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
      addGestureRecognizer(click)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let existing = trackingArea { removeTrackingArea(existing) }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInActiveApp],
        owner: self
      )
      addTrackingArea(area)
      trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
      isHovering = true
      updateHoverState()
    }

    override func mouseExited(with event: NSEvent) {
      isHovering = false
      updateHoverState()
    }

    private func updateHoverState() {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.15
        ctx.allowsImplicitAnimation = true
        backgroundBox.layer?.backgroundColor = isHovering
          ? NSColor(Color.backgroundTertiary).cgColor
          : NSColor(Color.backgroundTertiary).withAlphaComponent(0.7).cgColor
        backgroundBox.layer?.borderColor = isHovering
          ? NSColor(Color.accent).withAlphaComponent(0.15).cgColor
          : NSColor(Color.surfaceBorder).withAlphaComponent(0.4).cgColor
        chevronImage.contentTintColor = isHovering
          ? NSColor(Color.accent)
          : NSColor(Color.textSecondary)
      }
    }

    @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
      onToggle?()
    }

    func configure(
      hiddenCount: Int, totalToolCount: Int, isExpanded: Bool,
      breakdown: [ToolBreakdownEntry]
    ) {
      let symbolName = isExpanded ? "chevron.down" : "chevron.right"
      chevronImage.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)

      let lineColor = isExpanded
        ? NSColor(Color.textQuaternary).withAlphaComponent(0.3)
        : NSColor(Color.textQuaternary).withAlphaComponent(0.4)
      accentLine.layer?.backgroundColor = lineColor.cgColor

      if isExpanded {
        chevronImage.contentTintColor = NSColor(Color.textTertiary)
        countLabel.isHidden = true
        actionsLabel.textColor = NSColor(Color.textTertiary)
        actionsLabel.stringValue = "Collapse tools"
        separatorDot.isHidden = true
        breakdownStack.isHidden = true
        backgroundBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
        backgroundBox.layer?.borderColor = NSColor.clear.cgColor
      } else {
        chevronImage.contentTintColor = NSColor(Color.textSecondary)
        countLabel.isHidden = false
        countLabel.stringValue = "\(hiddenCount)"
        actionsLabel.textColor = NSColor(Color.textSecondary)
        actionsLabel.stringValue = "actions"
        separatorDot.isHidden = breakdown.isEmpty
        breakdownStack.isHidden = breakdown.isEmpty
        backgroundBox.layer?.backgroundColor =
          NSColor(Color.backgroundTertiary).withAlphaComponent(0.7).cgColor
        backgroundBox.layer?.borderColor =
          NSColor(Color.surfaceBorder).withAlphaComponent(0.4).cgColor

        rebuildBreakdownChips(breakdown)
      }
    }

    private func rebuildBreakdownChips(_ breakdown: [ToolBreakdownEntry]) {
      breakdownStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

      for entry in breakdown.prefix(6) {
        let chip = NSStackView()
        chip.orientation = .horizontal
        chip.spacing = 5
        chip.alignment = .centerY

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: entry.icon, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        icon.contentTintColor = NSColor(Self.toolColor(for: entry.colorKey))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let count = NSTextField(labelWithString: "\(entry.count)")
        count.font = NSFont.monospacedDigitSystemFont(ofSize: TypeScale.body, weight: .bold)
        count.textColor = NSColor(Color.textSecondary)

        let name = NSTextField(labelWithString: Self.displayName(for: entry.name))
        name.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
        name.textColor = NSColor(Color.textTertiary)
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

  // MARK: - Load More Cell

  final class NativeLoadMoreCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeLoadMoreCell")

    private let button = NSButton(title: "", target: nil, action: nil)
    var onLoadMore: (() -> Void)?

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

      button.translatesAutoresizingMaskIntoConstraints = false
      button.isBordered = false
      button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
      button.contentTintColor = NSColor(Color.accent)
      button.target = self
      button.action = #selector(handleClick)
      addSubview(button)

      NSLayoutConstraint.activate([
        button.centerXAnchor.constraint(equalTo: centerXAnchor),
        button.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    @objc private func handleClick() {
      onLoadMore?()
    }

    func configure(remainingCount: Int) {
      button.title = "Load \(remainingCount) earlier messages"
    }
  }

  // MARK: - Message Count Cell

  final class NativeMessageCountCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeMessageCountCell")

    private let label = NSTextField(labelWithString: "")

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

      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
      label.textColor = NSColor(Color.textTertiary)
      label.alignment = .center
      addSubview(label)

      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: centerXAnchor),
        label.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    func configure(displayedCount: Int, totalCount: Int) {
      label.stringValue = "Showing \(displayedCount) of \(totalCount) messages"
    }
  }

  // MARK: - Compact Tool Cell

  final class NativeCompactToolCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeCompactToolCell")

    private let threadLine = NSView()
    private let glyphImage = NSImageView()
    private let summaryField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let contextField = NSTextField(labelWithString: "")
    private let snippetField = NSTextField(labelWithString: "")
    private let diffBarContainer = NSView()
    private let diffBarAdded = NSView()
    private let diffBarRemoved = NSView()
    private var diffBarAddedWidth: NSLayoutConstraint?
    private var diffBarRemovedWidth: NSLayoutConstraint?
    var onTap: (() -> Void)?

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

      let inset = ConversationLayout.laneHorizontalInset

      // Thread line — connects to rollup above/below
      threadLine.wantsLayer = true
      threadLine.layer?.backgroundColor = NSColor(Color.textQuaternary).withAlphaComponent(0.4).cgColor
      threadLine.translatesAutoresizingMaskIntoConstraints = false
      addSubview(threadLine)

      glyphImage.translatesAutoresizingMaskIntoConstraints = false
      glyphImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
      addSubview(glyphImage)

      summaryField.translatesAutoresizingMaskIntoConstraints = false
      summaryField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      summaryField.textColor = NSColor.white.withAlphaComponent(0.58)
      summaryField.lineBreakMode = .byCharWrapping
      summaryField.maximumNumberOfLines = 0
      summaryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      addSubview(summaryField)

      metaField.translatesAutoresizingMaskIntoConstraints = false
      metaField.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
      metaField.textColor = NSColor(Color.textTertiary)
      metaField.lineBreakMode = .byTruncatingTail
      metaField.alignment = .right
      metaField.setContentCompressionResistancePriority(.required, for: .horizontal)
      addSubview(metaField)

      // Context label — unchanged line before the edit (dimmed)
      contextField.translatesAutoresizingMaskIntoConstraints = false
      contextField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
      contextField.textColor = NSColor.white.withAlphaComponent(0.25)
      contextField.lineBreakMode = .byTruncatingTail
      contextField.maximumNumberOfLines = 1
      contextField.isHidden = true
      addSubview(contextField)

      // Snippet label — first changed line preview
      snippetField.translatesAutoresizingMaskIntoConstraints = false
      snippetField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
      snippetField.lineBreakMode = .byTruncatingTail
      snippetField.maximumNumberOfLines = 1
      snippetField.isHidden = true
      addSubview(snippetField)

      // Diff bar — green/red ratio indicator
      diffBarContainer.wantsLayer = true
      diffBarContainer.translatesAutoresizingMaskIntoConstraints = false
      diffBarContainer.isHidden = true
      addSubview(diffBarContainer)

      diffBarAdded.wantsLayer = true
      diffBarAdded.layer?.cornerRadius = 1.5
      diffBarAdded.translatesAutoresizingMaskIntoConstraints = false
      diffBarContainer.addSubview(diffBarAdded)

      diffBarRemoved.wantsLayer = true
      diffBarRemoved.layer?.cornerRadius = 1.5
      diffBarRemoved.translatesAutoresizingMaskIntoConstraints = false
      diffBarContainer.addSubview(diffBarRemoved)

      let addedW = diffBarAdded.widthAnchor.constraint(equalToConstant: 0)
      let removedW = diffBarRemoved.widthAnchor.constraint(equalToConstant: 0)
      diffBarAddedWidth = addedW
      diffBarRemovedWidth = removedW

      NSLayoutConstraint.activate([
        threadLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 6),
        threadLine.widthAnchor.constraint(equalToConstant: 2),
        threadLine.topAnchor.constraint(equalTo: topAnchor),
        threadLine.bottomAnchor.constraint(equalTo: bottomAnchor),

        glyphImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 16),
        glyphImage.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        glyphImage.widthAnchor.constraint(equalToConstant: 18),

        summaryField.leadingAnchor.constraint(equalTo: glyphImage.trailingAnchor, constant: 4),
        summaryField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        summaryField.trailingAnchor.constraint(lessThanOrEqualTo: metaField.leadingAnchor, constant: -8),

        metaField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        metaField.topAnchor.constraint(equalTo: topAnchor, constant: 8),

        // Context — below summary (shown when surrounding context exists)
        contextField.leadingAnchor.constraint(equalTo: summaryField.leadingAnchor),
        contextField.topAnchor.constraint(equalTo: summaryField.bottomAnchor, constant: 2),
        contextField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),

        // Snippet — below context (or summary when no context)
        snippetField.leadingAnchor.constraint(equalTo: summaryField.leadingAnchor),
        snippetField.topAnchor.constraint(equalTo: contextField.bottomAnchor, constant: 0),
        snippetField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),

        // Diff bar — below snippet
        diffBarContainer.leadingAnchor.constraint(equalTo: summaryField.leadingAnchor),
        diffBarContainer.topAnchor.constraint(equalTo: snippetField.bottomAnchor, constant: 3),
        diffBarContainer.heightAnchor.constraint(equalToConstant: 3),
        diffBarContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 80),

        diffBarAdded.leadingAnchor.constraint(equalTo: diffBarContainer.leadingAnchor),
        diffBarAdded.topAnchor.constraint(equalTo: diffBarContainer.topAnchor),
        diffBarAdded.heightAnchor.constraint(equalToConstant: 3),
        addedW,

        diffBarRemoved.leadingAnchor.constraint(equalTo: diffBarAdded.trailingAnchor, constant: 1),
        diffBarRemoved.topAnchor.constraint(equalTo: diffBarContainer.topAnchor),
        diffBarRemoved.heightAnchor.constraint(equalToConstant: 3),
        removedW,
      ])

      let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
      addGestureRecognizer(click)
    }

    @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
      onTap?()
    }

    static func requiredHeight(
      for width: CGFloat,
      summary: String,
      hasDiffPreview: Bool = false,
      hasContextLine: Bool = false
    ) -> CGFloat {
      let inset = ConversationLayout.laneHorizontalInset
      let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      // glyph leading: inset + 16 + 18 (glyph) + 4 (gap) = inset + 38
      // meta trailing area ~ 60pt reserve
      let textWidth = max(60, width - inset * 2 - 38 - 60)
      let textH = ExpandedToolLayout.measuredTextHeight(summary, font: font, maxWidth: textWidth)
      let baseHeight = max(ConversationLayout.compactToolRowHeight, textH + 12)
      if hasDiffPreview {
        let contextExtra: CGFloat = hasContextLine ? 14 : 0
        return baseHeight + 22 + contextExtra // snippet (~14pt) + gap (2pt) + bar (3pt) + gap (3pt) + context
      }
      return baseHeight
    }

    func configure(model: NativeCompactToolRowModel) {
      glyphImage.image = NSImage(systemSymbolName: model.glyphSymbol, accessibilityDescription: nil)
      glyphImage.contentTintColor = model.glyphColor.withAlphaComponent(0.7)
      summaryField.stringValue = model.summary
      glyphImage.alphaValue = model.isInProgress ? 0.4 : 0.8

      if let meta = model.rightMeta {
        metaField.isHidden = false
        metaField.stringValue = meta
      } else {
        metaField.isHidden = true
      }

      if let preview = model.diffPreview {
        // Context line (unchanged code before the edit)
        if let ctx = preview.contextLine {
          contextField.stringValue = "  \(ctx)"
          contextField.isHidden = false
        } else {
          contextField.isHidden = true
        }

        // Snippet
        let prefixColor = preview.isAddition
          ? ExpandedToolLayout.addedAccentColor
          : ExpandedToolLayout.removedAccentColor
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
          string: "\(preview.snippetPrefix) ",
          attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: prefixColor.withAlphaComponent(0.7),
          ]
        ))
        attributed.append(NSAttributedString(
          string: preview.snippetText,
          attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: prefixColor.withAlphaComponent(0.7),
          ]
        ))
        snippetField.attributedStringValue = attributed
        snippetField.isHidden = false

        // Diff bar
        let total = CGFloat(preview.additions + preview.deletions)
        let maxBarWidth: CGFloat = 80
        let addedFraction = total > 0 ? CGFloat(preview.additions) / total : 1
        let addedWidth = round(addedFraction * maxBarWidth)
        let removedWidth = max(0, maxBarWidth - addedWidth - 1) // -1 for gap

        diffBarAddedWidth?.constant = addedWidth
        diffBarRemovedWidth?.constant = preview.deletions > 0 ? removedWidth : 0

        diffBarAdded.layer?.backgroundColor = ExpandedToolLayout.addedAccentColor.withAlphaComponent(0.6).cgColor
        diffBarRemoved.layer?.backgroundColor = ExpandedToolLayout.removedAccentColor.withAlphaComponent(0.6).cgColor
        diffBarRemoved.isHidden = preview.deletions == 0
        diffBarContainer.isHidden = false
      } else {
        contextField.isHidden = true
        snippetField.isHidden = true
        diffBarContainer.isHidden = true
      }
    }
  }

#endif
