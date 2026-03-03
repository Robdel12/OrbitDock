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

    private let hairline = NSView()

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

      hairline.wantsLayer = true
      hairline.layer?.backgroundColor = NSColor(Color.textQuaternary).withAlphaComponent(0.3).cgColor
      hairline.translatesAutoresizingMaskIntoConstraints = false
      addSubview(hairline)

      NSLayoutConstraint.activate([
        hairline.centerXAnchor.constraint(equalTo: centerXAnchor),
        hairline.centerYAnchor.constraint(equalTo: centerYAnchor),
        hairline.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.2),
        hairline.heightAnchor.constraint(equalToConstant: 0.5),
      ])
    }

    func configure(turn: TurnSummary) {
      if turn.turnNumber == 1 {
        hairline.isHidden = true
      } else {
        hairline.isHidden = false
      }
    }
  }

  // MARK: - Rollup Summary Cell

  final class NativeRollupSummaryCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeRollupSummaryCell")

    private let chevronImage = NSImageView()
    private let summaryLabel = NSTextField(labelWithString: "")
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

      // Chevron
      chevronImage.translatesAutoresizingMaskIntoConstraints = false
      chevronImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
      chevronImage.contentTintColor = NSColor(Color.textQuaternary)
      addSubview(chevronImage)

      // Summary text
      summaryLabel.translatesAutoresizingMaskIntoConstraints = false
      summaryLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .regular)
      summaryLabel.textColor = NSColor(Color.textTertiary)
      summaryLabel.lineBreakMode = .byTruncatingTail
      addSubview(summaryLabel)

      NSLayoutConstraint.activate([
        chevronImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 4),
        chevronImage.centerYAnchor.constraint(equalTo: centerYAnchor),
        chevronImage.widthAnchor.constraint(equalToConstant: 10),

        summaryLabel.leadingAnchor.constraint(equalTo: chevronImage.trailingAnchor, constant: 6),
        summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
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
        chevronImage.contentTintColor = isHovering
          ? NSColor(Color.accent)
          : NSColor(Color.textQuaternary)
        summaryLabel.textColor = isHovering
          ? NSColor(Color.textSecondary)
          : NSColor(Color.textTertiary)
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

      if isExpanded {
        summaryLabel.stringValue = "Collapse"
      } else {
        summaryLabel.stringValue = Self.buildBreakdownText(breakdown)
      }
    }

    private static func buildBreakdownText(_ breakdown: [ToolBreakdownEntry]) -> String {
      breakdown.prefix(6)
        .map { "\($0.count) \(displayName(for: $0.name))" }
        .joined(separator: ", ")
    }

    private static func displayName(for toolName: String) -> String {
      let lowered = toolName.lowercased()
      let normalized = lowered.split(separator: ":").last.map(String.init) ?? lowered
      switch normalized {
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
        case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan":
            return "Todo"
        case "askuserquestion": return "Question"
        case "mcp_approval": return "MCP Approval"
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

  // MARK: - Live Indicator Cell

  final class NativeLiveIndicatorCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeLiveIndicatorCell")

    private let shimmerBar = NSView()
    private let staticBar = NSView()
    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var shimmerLayer: CAGradientLayer?

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

      // Shimmer bar for working state
      shimmerBar.wantsLayer = true
      shimmerBar.translatesAutoresizingMaskIntoConstraints = false
      shimmerBar.isHidden = true
      addSubview(shimmerBar)

      // Static bar for permission state
      staticBar.wantsLayer = true
      staticBar.translatesAutoresizingMaskIntoConstraints = false
      staticBar.isHidden = true
      addSubview(staticBar)

      iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      iconView.contentTintColor = NSColor(Color.statusPermission)
      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.isHidden = true
      addSubview(iconView)

      primaryLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
      primaryLabel.translatesAutoresizingMaskIntoConstraints = false
      addSubview(primaryLabel)

      detailLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
      detailLabel.textColor = NSColor(Color.textTertiary)
      detailLabel.lineBreakMode = .byTruncatingTail
      detailLabel.translatesAutoresizingMaskIntoConstraints = false
      addSubview(detailLabel)

      NSLayoutConstraint.activate([
        shimmerBar.topAnchor.constraint(equalTo: topAnchor),
        shimmerBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        shimmerBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        shimmerBar.heightAnchor.constraint(equalToConstant: 2),

        staticBar.topAnchor.constraint(equalTo: topAnchor),
        staticBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        staticBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        staticBar.heightAnchor.constraint(equalToConstant: 2),

        iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        iconView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        iconView.widthAnchor.constraint(equalToConstant: 16),

        primaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
        primaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

        detailLabel.leadingAnchor.constraint(equalTo: primaryLabel.trailingAnchor, constant: Spacing.xs),
        detailLabel.centerYAnchor.constraint(equalTo: primaryLabel.centerYAnchor),
        detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
      ])
    }

    override func layout() {
      super.layout()
      shimmerLayer?.frame = shimmerBar.bounds
    }

    func configure(
      workStatus: Session.WorkStatus,
      currentTool: String?,
      pendingToolName: String?,
      pendingPermissionDetail: String?,
      provider: Provider
    ) {
      shimmerBar.isHidden = true
      staticBar.isHidden = true
      iconView.isHidden = true
      detailLabel.isHidden = true
      primaryLabel.stringValue = ""
      detailLabel.stringValue = ""
      removeShimmerAnimation()

      switch workStatus {
        case .working:
          shimmerBar.isHidden = false
          setupShimmerAnimation()

          primaryLabel.stringValue = "Working"
          primaryLabel.textColor = NSColor(Color.statusWorking).withAlphaComponent(0.8)
          primaryLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)

          // Shift primary label down to account for shimmer bar
          updateLabelLeadingConstraint(hasIcon: false)

          if let tool = currentTool, !tool.isEmpty {
            detailLabel.isHidden = false
            detailLabel.stringValue = "on \(tool)"
            detailLabel.textColor = NSColor(Color.textTertiary)
            detailLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
          }

        case .waiting:
          staticBar.isHidden = false
          staticBar.layer?.backgroundColor = NSColor(Color.statusReply).withAlphaComponent(0.4).cgColor

          primaryLabel.stringValue = "Waiting for reply"
          primaryLabel.textColor = NSColor(Color.statusReply).withAlphaComponent(0.8)
          primaryLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
          updateLabelLeadingConstraint(hasIcon: false)

        case .permission:
          staticBar.isHidden = false
          staticBar.layer?.backgroundColor = NSColor(Color.statusPermission).withAlphaComponent(0.4).cgColor

          iconView.isHidden = false
          iconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
          )
          iconView.contentTintColor = NSColor(Color.statusPermission)

          primaryLabel.stringValue = "Permission"
          primaryLabel.textColor = NSColor(Color.statusPermission)
          primaryLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
          updateLabelLeadingConstraint(hasIcon: true)

          if let toolName = pendingToolName, !toolName.isEmpty {
            detailLabel.isHidden = false
            detailLabel.stringValue = toolName
            detailLabel.textColor = NSColor(Color.textPrimary)
            detailLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .bold)
          }

        case .unknown:
          primaryLabel.stringValue = ""
      }
    }

    private var primaryLeadingConstraint: NSLayoutConstraint?

    private func updateLabelLeadingConstraint(hasIcon: Bool) {
      let inset = ConversationLayout.laneHorizontalInset
      primaryLeadingConstraint?.isActive = false
      if hasIcon {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: iconView.trailingAnchor, constant: Spacing.xs
        )
      } else {
        primaryLeadingConstraint = primaryLabel.leadingAnchor.constraint(
          equalTo: leadingAnchor, constant: inset
        )
      }
      primaryLeadingConstraint?.isActive = true
    }

    private func setupShimmerAnimation() {
      let gradient = CAGradientLayer()
      gradient.frame = shimmerBar.bounds
      gradient.colors = [
        NSColor.clear.cgColor,
        NSColor(Color.statusWorking).withAlphaComponent(0.3).cgColor,
        NSColor.clear.cgColor,
      ]
      gradient.locations = [0, 0.5, 1.0]
      gradient.startPoint = CGPoint(x: 0, y: 0.5)
      gradient.endPoint = CGPoint(x: 1, y: 0.5)
      shimmerBar.layer?.addSublayer(gradient)
      shimmerLayer = gradient

      let animation = CABasicAnimation(keyPath: "position.x")
      animation.fromValue = -shimmerBar.bounds.width
      animation.toValue = shimmerBar.bounds.width * 2
      animation.duration = 1.8
      animation.repeatCount = .infinity
      gradient.add(animation, forKey: "shimmer")
    }

    private func removeShimmerAnimation() {
      shimmerLayer?.removeAllAnimations()
      shimmerLayer?.removeFromSuperlayer()
      shimmerLayer = nil
    }
  }

  // MARK: - Compact Tool Cell

  final class NativeCompactToolCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeCompactToolCell")

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
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
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
      layer?.cornerRadius = Radius.sm

      let inset = ConversationLayout.laneHorizontalInset

      glyphImage.translatesAutoresizingMaskIntoConstraints = false
      glyphImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
      addSubview(glyphImage)

      summaryField.translatesAutoresizingMaskIntoConstraints = false
      summaryField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      summaryField.textColor = NSColor(Color.textTertiary)
      summaryField.lineBreakMode = .byTruncatingTail
      summaryField.maximumNumberOfLines = 1
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
        glyphImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 4),
        glyphImage.topAnchor.constraint(equalTo: topAnchor, constant: 7),
        glyphImage.widthAnchor.constraint(equalToConstant: 14),

        summaryField.leadingAnchor.constraint(equalTo: glyphImage.trailingAnchor, constant: 4),
        summaryField.topAnchor.constraint(equalTo: topAnchor, constant: 5),
        summaryField.trailingAnchor.constraint(lessThanOrEqualTo: metaField.leadingAnchor, constant: -8),

        metaField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        metaField.topAnchor.constraint(equalTo: topAnchor, constant: 7),

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
        diffBarContainer.topAnchor.constraint(equalTo: snippetField.bottomAnchor, constant: 2),
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
        layer?.backgroundColor = isHovering
          ? NSColor(Color.accent).withAlphaComponent(0.04).cgColor
          : NSColor.clear.cgColor
      }
    }

    @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
      onTap?()
    }

    static func requiredHeight(
      for width: CGFloat,
      summary: String,
      hasDiffPreview: Bool = false,
      hasContextLine: Bool = false,
      hasLivePreview: Bool = false
    ) -> CGFloat {
      let inset = ConversationLayout.laneHorizontalInset
      let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      // glyph leading: inset + 4 + 14 (glyph) + 4 (gap) = inset + 22
      // meta trailing area ~ 60pt reserve
      let textWidth = max(60, width - inset * 2 - 22 - 60)
      let textH = ExpandedToolLayout.measuredTextHeight(summary, font: font, maxWidth: textWidth)
      let baseHeight = max(ConversationLayout.compactToolRowHeight, textH + 10)
      if hasDiffPreview {
        let contextExtra: CGFloat = hasContextLine ? 14 : 0
        return baseHeight + 21 + contextExtra // snippet (~14pt) + gap (2pt) + bar (3pt) + gap (2pt) + context
      }
      if hasLivePreview {
        return baseHeight + 16
      }
      return baseHeight
    }

    func configure(model: NativeCompactToolRowModel) {
      glyphImage.image = NSImage(systemSymbolName: model.glyphSymbol, accessibilityDescription: nil)
      glyphImage.contentTintColor = model.glyphColor.withAlphaComponent(0.5)
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
      } else if let livePreview = model.liveOutputPreview {
        contextField.isHidden = true
        diffBarContainer.isHidden = true
        let color = NSColor(Color.toolBash).withAlphaComponent(0.72)
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
          string: "> ",
          attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: color,
          ]
        ))
        attributed.append(NSAttributedString(
          string: livePreview,
          attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color,
          ]
        ))
        snippetField.attributedStringValue = attributed
        snippetField.isHidden = false
      } else {
        contextField.isHidden = true
        snippetField.isHidden = true
        diffBarContainer.isHidden = true
      }
    }
  }

#endif
