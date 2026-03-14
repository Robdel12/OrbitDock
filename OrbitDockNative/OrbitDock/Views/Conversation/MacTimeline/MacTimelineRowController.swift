#if os(macOS)
  import AppKit
  import SwiftUI

  protocol MacTimelineRowController: AnyObject {
    var id: String { get }
    var reuseIdentifier: NSUserInterfaceItemIdentifier { get }
    func height(for availableWidth: CGFloat) -> CGFloat
    func update(with record: MacTimelineRowRecord)
    func makeView() -> NSTableCellView
    func configure(_ view: NSTableCellView, availableWidth: CGFloat)
    func performPrimaryAction()
  }

  extension MacTimelineRowController {
    func performPrimaryAction() {
    }
  }

  enum MacTimelineRowControllerFactory {
    static func makeController(for record: MacTimelineRowRecord) -> any MacTimelineRowController {
      switch record {
        case .utility(let utility):
          return MacTimelineUtilityRowController(record: utility)
        case .tool(let tool):
          return MacTimelineToolRowController(record: tool)
        case .expandedTool(let tool):
          return MacTimelineExpandedToolRowController(record: tool)
        case .loadMore(let loadMore):
          return MacTimelineLoadMoreRowController(record: loadMore)
        case .spacer(let spacer):
          return MacTimelineSpacerRowController(record: spacer)
        case .message(let message):
          return MacTimelineMessageRowController(record: message)
      }
    }
  }

  // MARK: - Utility Row Controller

  final class MacTimelineUtilityRowController: MacTimelineRowController {
    private(set) var record: MacTimelineUtilityRecord
    var onToggleExpansion: ((String) -> Void)?

    init(record: MacTimelineUtilityRecord) {
      self.record = record
    }

    var id: String { record.id }
    let reuseIdentifier = NSUserInterfaceItemIdentifier("MacTimelineUtilityCellView")
    func height(for availableWidth: CGFloat) -> CGFloat {
      switch record.kind {
        case .approval:
          return record.spotlight == nil ? 122 : 144
        case .live:
          return record.subtitle == nil ? 88 : 108
        case .workers:
          return record.spotlight == nil ? 132 : 154
        case .activity:
          return record.subtitle == nil ? 92 : 110
      }
    }

    func update(with record: MacTimelineRowRecord) {
      guard case .utility(let utility) = record else { return }
      self.record = utility
    }

    func makeView() -> NSTableCellView {
      MacTimelineUtilityCellView(frame: .zero)
    }

    func configure(_ view: NSTableCellView, availableWidth: CGFloat) {
      guard let cell = view as? MacTimelineUtilityCellView else { return }
      cell.onActivate = { [weak self] in
        self?.performPrimaryAction()
      }
      cell.configure(record: record)
    }

    func performPrimaryAction() {
      guard record.kind == .activity, let anchorID = record.activityAnchorID else { return }
      onToggleExpansion?(anchorID)
    }
  }

  // MARK: - Load More Row Controller

  final class MacTimelineLoadMoreRowController: MacTimelineRowController {
    private(set) var record: MacTimelineLoadMoreRecord
    var onLoadMore: (() -> Void)?

    init(record: MacTimelineLoadMoreRecord) {
      self.record = record
    }

    var id: String { record.id }
    let reuseIdentifier = NSUserInterfaceItemIdentifier("MacTimelineLoadMoreCellView")
    func height(for availableWidth: CGFloat) -> CGFloat { 56 }

    func update(with record: MacTimelineRowRecord) {
      guard case .loadMore(let loadMore) = record else { return }
      self.record = loadMore
    }

    func makeView() -> NSTableCellView {
      let view = MacTimelineLoadMoreCellView(frame: .zero)
      view.onLoadMore = onLoadMore
      return view
    }

    func configure(_ view: NSTableCellView, availableWidth: CGFloat) {
      let cell = view as? MacTimelineLoadMoreCellView
      cell?.onLoadMore = onLoadMore
      cell?.configure(record: record)
    }
  }

  // MARK: - Spacer Row Controller

  final class MacTimelineSpacerRowController: MacTimelineRowController {
    private(set) var record: MacTimelineSpacerRecord

    init(record: MacTimelineSpacerRecord) {
      self.record = record
    }

    var id: String { record.id }
    let reuseIdentifier = NSUserInterfaceItemIdentifier("MacTimelineSpacerCellView")

    func height(for availableWidth: CGFloat) -> CGFloat {
      record.height
    }

    func update(with record: MacTimelineRowRecord) {
      guard case .spacer(let spacer) = record else { return }
      self.record = spacer
    }

    func makeView() -> NSTableCellView {
      MacTimelineSpacerCellView(frame: .zero)
    }

    func configure(_ view: NSTableCellView, availableWidth: CGFloat) {
      (view as? MacTimelineSpacerCellView)?.configure(record: record)
    }
  }

  // MARK: - Tool Row Controller

  final class MacTimelineToolRowController: MacTimelineRowController {
    private(set) var record: MacTimelineToolRecord
    var onToggleExpansion: ((String) -> Void)?

    init(record: MacTimelineToolRecord) {
      self.record = record
    }

    var id: String { record.id }
    let reuseIdentifier = NSUserInterfaceItemIdentifier("MacTimelineToolCellView")

    func height(for availableWidth: CGFloat) -> CGFloat {
      MacTimelineToolCellView.requiredHeight(for: record.model, width: availableWidth)
    }

    func update(with record: MacTimelineRowRecord) {
      guard case .tool(let tool) = record else { return }
      self.record = tool
    }

    func makeView() -> NSTableCellView {
      MacTimelineToolCellView(frame: .zero)
    }

    func configure(_ view: NSTableCellView, availableWidth: CGFloat) {
      guard let cell = view as? MacTimelineToolCellView else { return }
      cell.onActivate = { [weak self] in
        self?.performPrimaryAction()
      }
      cell.configure(record: record)
    }

    func performPrimaryAction() {
      onToggleExpansion?(record.id)
    }
  }

  // MARK: - Expanded Tool Row Controller

  final class MacTimelineExpandedToolRowController: MacTimelineRowController {
    private(set) var record: MacTimelineExpandedToolRecord
    var onToggleExpansion: ((String) -> Void)?
    var onFocusWorker: ((String) -> Void)?
    var onMeasuredHeightChange: ((String, CGFloat) -> Void)?
    private var measuredHeight: CGFloat?

    init(record: MacTimelineExpandedToolRecord) {
      self.record = record
    }

    var id: String { record.id }
    let reuseIdentifier = NativeExpandedToolCellView.reuseIdentifier

    func height(for availableWidth: CGFloat) -> CGFloat {
      measuredHeight ?? ExpandedToolLayout.requiredHeight(for: availableWidth, model: record.model)
    }

    func update(with record: MacTimelineRowRecord) {
      guard case .expandedTool(let tool) = record else { return }
      self.record = tool
      measuredHeight = nil
    }

    func makeView() -> NSTableCellView {
      NativeExpandedToolCellView(frame: .zero)
    }

    func configure(_ view: NSTableCellView, availableWidth: CGFloat) {
      guard let cell = view as? NativeExpandedToolCellView else { return }
      cell.onCollapse = { [weak self] messageID in
        self?.onToggleExpansion?(messageID)
      }
      cell.onFocusWorker = { [weak self] workerID in
        self?.onFocusWorker?(workerID)
      }
      cell.onMeasuredHeightChange = { [weak self] messageID, height in
        guard let self, messageID == self.record.id else { return }
        if self.measuredHeight == nil || abs((self.measuredHeight ?? 0) - height) > 1 {
          self.measuredHeight = height
          self.onMeasuredHeightChange?(messageID, height)
        }
      }
      cell.configure(model: record.model, width: availableWidth)
    }

    func performPrimaryAction() {
      onToggleExpansion?(record.id)
    }
  }

  // MARK: - Message Row Controller

  final class MacTimelineMessageRowController: MacTimelineRowController {
    private(set) var record: MacTimelineMessageRecord

    init(record: MacTimelineMessageRecord) {
      self.record = record
    }

    var id: String { record.id }
    let reuseIdentifier = NSUserInterfaceItemIdentifier("MacTimelineMessageCellView")

    func height(for availableWidth: CGFloat) -> CGFloat {
      NativeRichMessageCellView.requiredHeight(for: availableWidth, model: record.model)
    }

    func update(with record: MacTimelineRowRecord) {
      guard case .message(let message) = record else { return }
      self.record = message
    }

    func makeView() -> NSTableCellView {
      NativeRichMessageCellView(frame: .zero)
    }

    func configure(_ view: NSTableCellView, availableWidth: CGFloat) {
      (view as? NativeRichMessageCellView)?.configure(model: record.model, width: availableWidth)
    }
  }

  // MARK: - Utility Cell View

  final class MacTimelineUtilityCellView: NSTableCellView {
    var onActivate: (() -> Void)?
    private let cardView = NSView()
    private let accentBar = NSView()
    private let iconWell = NSView()
    private let iconView = NSImageView()
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let spotlightLabel = NSTextField(wrappingLabelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let disclosureView = NSImageView()
    private let chipsStack = NSStackView()
    private let spotlightPanel = NSView()

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      translatesAutoresizingMaskIntoConstraints = false
      cardView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(cardView)

      accentBar.wantsLayer = true
      accentBar.translatesAutoresizingMaskIntoConstraints = false
      accentBar.layer?.cornerRadius = 2
      cardView.addSubview(accentBar)

      iconWell.wantsLayer = true
      iconWell.translatesAutoresizingMaskIntoConstraints = false
      iconWell.layer?.cornerRadius = 10
      cardView.addSubview(iconWell)

      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
      iconWell.addSubview(iconView)

      titleLabel.font = .systemFont(ofSize: TypeScale.body, weight: .semibold)
      titleLabel.textColor = NSColor(Color.textPrimary)
      titleLabel.lineBreakMode = .byTruncatingTail
      eyebrowLabel.font = .systemFont(ofSize: TypeScale.mini, weight: .semibold)
      eyebrowLabel.textColor = NSColor(Color.textTertiary)
      subtitleLabel.font = .systemFont(ofSize: TypeScale.meta)
      subtitleLabel.textColor = NSColor(Color.textSecondary)
      subtitleLabel.lineBreakMode = .byWordWrapping
      subtitleLabel.maximumNumberOfLines = 2
      spotlightLabel.font = .systemFont(ofSize: TypeScale.meta, weight: .medium)
      spotlightLabel.textColor = NSColor(Color.textQuaternary)
      spotlightLabel.maximumNumberOfLines = 2

      badgeLabel.font = .monospacedSystemFont(ofSize: TypeScale.mini, weight: .semibold)
      badgeLabel.translatesAutoresizingMaskIntoConstraints = false

      disclosureView.translatesAutoresizingMaskIntoConstraints = false
      disclosureView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      disclosureView.contentTintColor = NSColor(Color.textTertiary)
      disclosureView.isHidden = true

      spotlightPanel.translatesAutoresizingMaskIntoConstraints = false
      spotlightPanel.addSubview(spotlightLabel)
      spotlightLabel.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        spotlightLabel.leadingAnchor.constraint(equalTo: spotlightPanel.leadingAnchor, constant: Spacing.sm),
        spotlightLabel.trailingAnchor.constraint(equalTo: spotlightPanel.trailingAnchor, constant: -Spacing.sm),
        spotlightLabel.topAnchor.constraint(equalTo: spotlightPanel.topAnchor, constant: Spacing.xs),
        spotlightLabel.bottomAnchor.constraint(equalTo: spotlightPanel.bottomAnchor, constant: -Spacing.xs),
      ])

      chipsStack.orientation = .horizontal
      chipsStack.alignment = .leading
      chipsStack.spacing = Spacing.xs
      chipsStack.translatesAutoresizingMaskIntoConstraints = false

      let stack = NSStackView(views: [eyebrowLabel, titleLabel, subtitleLabel, spotlightPanel, chipsStack])
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 6
      stack.translatesAutoresizingMaskIntoConstraints = false

      let trailingStack = NSStackView(views: [badgeLabel, disclosureView])
      trailingStack.orientation = .horizontal
      trailingStack.alignment = .centerY
      trailingStack.spacing = Spacing.xs
      trailingStack.translatesAutoresizingMaskIntoConstraints = false

      let row = NSStackView(views: [iconWell, stack, trailingStack])
      row.orientation = .horizontal
      row.alignment = .top
      row.spacing = Spacing.md
      row.translatesAutoresizingMaskIntoConstraints = false
      cardView.addSubview(row)

      NSLayoutConstraint.activate([
        cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ConversationLayout.laneHorizontalInset),
        cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ConversationLayout.laneHorizontalInset),
        cardView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

        accentBar.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: Spacing.sm),
        accentBar.topAnchor.constraint(equalTo: cardView.topAnchor, constant: Spacing.sm),
        accentBar.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -Spacing.sm),
        accentBar.widthAnchor.constraint(equalToConstant: EdgeBar.width),

        iconWell.widthAnchor.constraint(equalToConstant: 26),
        iconWell.heightAnchor.constraint(equalToConstant: 26),
        iconView.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
        iconView.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
        iconView.widthAnchor.constraint(equalToConstant: 14),
        iconView.heightAnchor.constraint(equalToConstant: 14),

        badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
        badgeLabel.heightAnchor.constraint(equalToConstant: 18),

        row.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: Spacing.md),
        row.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -Spacing.md),
        row.topAnchor.constraint(equalTo: cardView.topAnchor, constant: Spacing.sm),
        row.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -Spacing.sm),
      ])
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
      if hitTest(convert(event.locationInWindow, from: nil)) != nil, onActivate != nil {
        onActivate?()
      } else {
        super.mouseDown(with: event)
      }
    }

    func configure(record: MacTimelineUtilityRecord) {
      let accentColor = color(named: record.accentColorName)
      accentBar.layer?.backgroundColor = accentColor.cgColor
      iconWell.layer?.backgroundColor = accentColor.withAlphaComponent(0.12).cgColor
      iconView.image = NSImage(systemSymbolName: record.iconName, accessibilityDescription: nil)
      iconView.contentTintColor = accentColor
      eyebrowLabel.stringValue = record.eyebrow ?? ""
      eyebrowLabel.isHidden = record.eyebrow == nil
      titleLabel.stringValue = record.title
      subtitleLabel.stringValue = record.subtitle ?? ""
      subtitleLabel.isHidden = record.subtitle == nil
      spotlightLabel.stringValue = record.spotlight ?? ""
      spotlightPanel.isHidden = record.spotlight == nil
      badgeLabel.stringValue = record.trailingBadge ?? badgeText(for: record.kind)
      badgeLabel.isHidden = badgeLabel.stringValue.isEmpty
      MacTimelineChrome.stylePill(
        badgeLabel,
        textColor: accentColor.withAlphaComponent(0.95),
        fill: accentColor.withAlphaComponent(0.12)
      )
      if record.kind == .activity, record.activityAnchorID != nil {
        disclosureView.isHidden = false
        disclosureView.image = NSImage(
          systemSymbolName: record.isExpanded ? "chevron.down" : "chevron.right",
          accessibilityDescription: record.isExpanded ? "Collapse activity" : "Expand activity"
        )
      } else {
        disclosureView.isHidden = true
        disclosureView.image = nil
      }
      chipsStack.arrangedSubviews.forEach {
        chipsStack.removeArrangedSubview($0)
        $0.removeFromSuperview()
      }
      for chip in record.chips.prefix(4) {
        chipsStack.addArrangedSubview(makeChipView(chip))
      }
      chipsStack.isHidden = record.chips.isEmpty
      MacTimelineChrome.styleCard(
        cardView,
        fill: backgroundFill(for: record.kind, accentColor: accentColor),
        border: accentColor.withAlphaComponent(record.kind == .approval ? 0.28 : 0.14)
      )
      MacTimelineChrome.styleInsetPanel(
        spotlightPanel,
        fill: accentColor.withAlphaComponent(0.08),
        border: accentColor.withAlphaComponent(0.14)
      )
    }

    private func color(named name: String) -> NSColor {
      switch name {
        case "permission": return NSColor(Color.statusPermission)
        case "working": return NSColor(Color.statusWorking)
        case "reply": return NSColor(Color.statusReply)
        case "task": return NSColor(Color.toolTask)
        case "positive": return NSColor(Color.feedbackPositive)
        case "negative": return NSColor(Color.feedbackNegative)
        case "caution": return NSColor(Color.feedbackCaution)
        default: return NSColor(Color.accent)
      }
    }

    private func badgeText(for kind: MacTimelineUtilityRecord.Kind) -> String {
      switch kind {
        case .approval: return "ACTION"
        case .live: return "LIVE"
        case .workers: return "AGENTS"
        case .activity: return "TOOLS"
      }
    }

    private func backgroundFill(for kind: MacTimelineUtilityRecord.Kind, accentColor: NSColor) -> NSColor {
      switch kind {
        case .approval:
          return NSColor(Color.backgroundSecondary).blended(withFraction: 0.28, of: accentColor.withAlphaComponent(0.18))
            ?? NSColor(Color.backgroundSecondary)
        case .live:
          return NSColor(Color.backgroundSecondary).blended(withFraction: 0.18, of: accentColor.withAlphaComponent(0.12))
            ?? NSColor(Color.backgroundSecondary)
        case .workers:
          return NSColor(Color.backgroundSecondary).blended(withFraction: 0.22, of: accentColor.withAlphaComponent(0.14))
            ?? NSColor(Color.backgroundSecondary)
        case .activity:
          return NSColor(Color.backgroundSecondary).blended(withFraction: 0.16, of: accentColor.withAlphaComponent(0.1))
            ?? NSColor(Color.backgroundSecondary)
      }
    }

    private func makeChipView(_ chip: MacTimelineUtilityRecord.Chip) -> NSView {
      let view = NSView()
      let accentColor = color(named: chip.accentColorName)
      view.wantsLayer = true
      view.layer?.backgroundColor = accentColor.withAlphaComponent(chip.isActive ? 0.16 : 0.08).cgColor
      view.layer?.cornerRadius = 10

      let dot = NSImageView()
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
      dot.image = NSImage(systemSymbolName: chip.isActive ? "dot.radiowaves.left.and.right" : "circle.fill", accessibilityDescription: nil)
      dot.contentTintColor = accentColor

      let label = NSTextField(labelWithString: chip.title)
      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = .systemFont(ofSize: TypeScale.mini, weight: .semibold)
      label.textColor = NSColor(Color.textPrimary)

      let status = NSTextField(labelWithString: chip.statusText)
      status.translatesAutoresizingMaskIntoConstraints = false
      status.font = .monospacedSystemFont(ofSize: TypeScale.mini, weight: .medium)
      status.textColor = accentColor.withAlphaComponent(0.9)

      view.addSubview(dot)
      view.addSubview(label)
      view.addSubview(status)
      NSLayoutConstraint.activate([
        dot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
        dot.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        dot.widthAnchor.constraint(equalToConstant: 10),
        dot.heightAnchor.constraint(equalToConstant: 10),
        label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
        status.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
        status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
        status.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        label.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
        label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
      ])
      return view
    }
  }

  // MARK: - Load More Cell View

  final class MacTimelineLoadMoreCellView: NSTableCellView {
    var onLoadMore: (() -> Void)?
    private let button = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      button.bezelStyle = .rounded
      button.target = self
      button.action = #selector(handleTap)
      button.translatesAutoresizingMaskIntoConstraints = false
      addSubview(button)

      NSLayoutConstraint.activate([
        button.centerXAnchor.constraint(equalTo: centerXAnchor),
        button.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    func configure(record: MacTimelineLoadMoreRecord) {
      button.title = "Load \(record.remainingCount) more"
    }

    @objc private func handleTap() {
      onLoadMore?()
    }
  }

  final class MacTimelineSpacerCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = false
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    func configure(record: MacTimelineSpacerRecord) {
      frame.size.height = record.height
    }
  }

  // MARK: - Tool Cell View
  //
  // Tier-aware renderer of NativeCompactToolRowModel. The server's ToolDisplay
  // drives everything — displayTier determines the visual treatment:
  //
  //   prominent (Question)      — 48pt, vibrant card, thick bar, bold text
  //   standard  (Shell/Edit/…)  — 38pt, card with accent bar, detail line
  //   compact   (Read/Glob/…)   — 26pt, no card, small muted inline text
  //   minimal   (Skill/Plan/…)  — 20pt, no card, tiny dimmed text
  //
  // Non-flipped coordinates (origin at bottom-left).

  final class MacTimelineToolCellView: NSTableCellView {
    var onActivate: (() -> Void)?

    // Decoration layers (hidden for compact/minimal)
    private let cardView = NSView()
    private let accentBar = NSView()

    // Content (all children of self, positioned with frames)
    private let glyphView = NSImageView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let dotSep = NSTextField(labelWithString: "\u{00B7}")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let metaPill = NSView()
    private let detailLabel = NSTextField(labelWithString: "")
    private let diffBarTrack = NSView()
    private let diffBarAdded = NSView()
    private let diffBarRemoved = NSView()
    private let workerPill = NSTextField(labelWithString: "")

    private var currentModel: NativeCompactToolRowModel?

    // Per-tier geometry
    private struct TierMetrics {
      let baseH: CGFloat       // Base height before detail/worker additions
      let vMargin: CGFloat
      let iconSize: CGFloat
      let iconPointSize: CGFloat
      let rowH: CGFloat        // Single text line height
      let detailH: CGFloat
      let summaryMaxLines: Int // Summary wrapping limit
      let hasCard: Bool
      let hasAccentBar: Bool
      let hasDetail: Bool
      let hasWorker: Bool
      let accentBarWidth: CGFloat
      let accentBarInset: CGFloat // Vertical inset from card edges
      let borderWidth: CGFloat

      static let prominent = TierMetrics(
        baseH: 48, vMargin: 3, iconSize: 16, iconPointSize: 13,
        rowH: 20, detailH: 14, summaryMaxLines: 3,
        hasCard: true, hasAccentBar: true,
        hasDetail: true, hasWorker: true,
        accentBarWidth: 4, accentBarInset: 0, borderWidth: 1.5
      )
      static let standard = TierMetrics(
        baseH: 38, vMargin: 2, iconSize: 14, iconPointSize: 12,
        rowH: 18, detailH: 14, summaryMaxLines: 1,
        hasCard: true, hasAccentBar: true,
        hasDetail: true, hasWorker: true,
        accentBarWidth: EdgeBar.width, accentBarInset: 7, borderWidth: 1
      )
      static let compact = TierMetrics(
        baseH: 26, vMargin: 1, iconSize: 11, iconPointSize: 10,
        rowH: 16, detailH: 0, summaryMaxLines: 1,
        hasCard: false, hasAccentBar: false,
        hasDetail: false, hasWorker: false,
        accentBarWidth: 0, accentBarInset: 0, borderWidth: 0
      )
      static let minimal = TierMetrics(
        baseH: 20, vMargin: 1, iconSize: 10, iconPointSize: 9,
        rowH: 14, detailH: 0, summaryMaxLines: 1,
        hasCard: false, hasAccentBar: false,
        hasDetail: false, hasWorker: false,
        accentBarWidth: 0, accentBarInset: 0, borderWidth: 0
      )

      static func forTier(_ tier: DisplayTier) -> TierMetrics {
        switch tier {
          case .prominent: .prominent
          case .standard: .standard
          case .compact: .compact
          case .minimal: .minimal
        }
      }
    }

    private static let hPad: CGFloat = 10
    private static let accentX: CGFloat = 6
    private static let accentVInset: CGFloat = 7

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true

      // Card background (frame-based, positioned in layout)
      cardView.wantsLayer = true
      addSubview(cardView)

      // Accent bar
      accentBar.wantsLayer = true
      accentBar.layer?.cornerRadius = 1.5
      addSubview(accentBar)

      // Icon
      glyphView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
      addSubview(glyphView)

      // Summary
      summaryLabel.lineBreakMode = .byTruncatingTail
      summaryLabel.maximumNumberOfLines = 1
      addSubview(summaryLabel)

      // Middot
      dotSep.textColor = NSColor(Color.textQuaternary)
      dotSep.isHidden = true
      addSubview(dotSep)

      // Subtitle
      subtitleLabel.lineBreakMode = .byTruncatingTail
      subtitleLabel.maximumNumberOfLines = 1
      subtitleLabel.isHidden = true
      addSubview(subtitleLabel)

      // Meta pill bg
      metaPill.wantsLayer = true
      metaPill.layer?.cornerRadius = 4
      metaPill.isHidden = true
      addSubview(metaPill)

      // Meta label
      metaLabel.alignment = .center
      metaLabel.lineBreakMode = .byTruncatingTail
      metaLabel.maximumNumberOfLines = 1
      metaLabel.isHidden = true
      addSubview(metaLabel)

      // Detail label
      detailLabel.lineBreakMode = .byTruncatingTail
      detailLabel.maximumNumberOfLines = 1
      detailLabel.isHidden = true
      addSubview(detailLabel)

      // Diff bar
      diffBarTrack.wantsLayer = true
      diffBarTrack.layer?.cornerRadius = 2
      diffBarTrack.layer?.backgroundColor = NSColor(Color.backgroundTertiary).withAlphaComponent(0.9).cgColor
      diffBarTrack.isHidden = true
      addSubview(diffBarTrack)

      diffBarAdded.wantsLayer = true
      diffBarAdded.layer?.cornerRadius = 2
      diffBarTrack.addSubview(diffBarAdded)

      diffBarRemoved.wantsLayer = true
      diffBarRemoved.layer?.cornerRadius = 2
      diffBarTrack.addSubview(diffBarRemoved)

      // Worker pill
      workerPill.lineBreakMode = .byTruncatingTail
      workerPill.maximumNumberOfLines = 1
      workerPill.isHidden = true
      addSubview(workerPill)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
      if hitTest(convert(event.locationInWindow, from: nil)) != nil, onActivate != nil {
        onActivate?()
      } else {
        super.mouseDown(with: event)
      }
    }

    // MARK: - Height

    static func requiredHeight(for model: NativeCompactToolRowModel, width: CGFloat) -> CGFloat {
      let t = TierMetrics.forTier(model.displayTier)
      var h = t.baseH

      // Prominent tier: measure summary for multi-line wrapping
      if t.summaryMaxLines > 1 {
        let extraLines = measuredSummaryLineCount(model, tier: t, width: width) - 1
        if extraLines > 0 {
          h += CGFloat(extraLines) * (t.rowH - 2)
        }
        // Prominent subtitle goes on its own line below summary
        if model.subtitle != nil {
          h += t.rowH - 4
        }
      }

      if t.hasDetail {
        if model.diffPreview != nil { h += 22 }
        else if detailVisible(model) { h += 16 }
      }
      if t.hasWorker, (model.linkedWorkerLabel ?? model.linkedWorkerID) != nil {
        h += 20
      }
      return h + t.vMargin * 2
    }

    private static func detailVisible(_ m: NativeCompactToolRowModel) -> Bool {
      m.liveOutputPreview != nil
        || (m.todoItems?.isEmpty == false)
        || m.outputPreview != nil
    }

    /// Measure how many lines the summary will occupy for multi-line tiers.
    private static func measuredSummaryLineCount(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics, width: CGFloat
    ) -> Int {
      let font: NSFont = m.summaryFont == .mono
        ? .monospacedSystemFont(ofSize: TypeScale.subhead, weight: .semibold)
        : .systemFont(ofSize: TypeScale.subhead, weight: .semibold)

      let inset = ConversationLayout.laneHorizontalInset
      let leading = 6 + t.accentBarWidth + 10 + t.iconSize + 6 // accentX + bar + hPad + icon + gap
      let trailing: CGFloat = 10 // hPad
      let metaSpace: CGFloat = m.rightMeta != nil ? 100 : 0
      let availW = max(100, width - inset * 2 - leading - trailing - metaSpace)

      let attr = NSAttributedString(string: m.summary, attributes: [.font: font])
      let rect = attr.boundingRect(
        with: NSSize(width: availW, height: CGFloat(t.summaryMaxLines) * font.pointSize * 1.5),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      )
      let lineH = font.pointSize * 1.3
      return min(t.summaryMaxLines, max(1, Int(ceil(rect.height / lineH))))
    }

    // MARK: - Configure

    func configure(record: MacTimelineToolRecord) {
      let m = record.model
      currentModel = m
      let t = TierMetrics.forTier(m.displayTier)

      let accent = m.glyphColor
      let isError = (m.rightMeta ?? "").hasPrefix("\u{2717}")

      // --- Tier-aware appearance ---

      configureCardChrome(m, tier: t, accent: accent, isError: isError)
      configureIcon(m, tier: t, accent: accent, isError: isError)
      configureSummary(m, tier: t, isError: isError)
      configureSubtitle(m, tier: t)
      configureMeta(m, tier: t, accent: accent, isError: isError)

      if t.hasDetail {
        configureDetail(m, accent: accent)
      } else {
        detailLabel.isHidden = true
        diffBarTrack.isHidden = true
      }

      if t.hasWorker {
        configureWorker(m, accent: accent)
      } else {
        workerPill.isHidden = true
      }

      needsLayout = true
    }

    // MARK: Card Chrome

    private func configureCardChrome(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      accent: NSColor, isError: Bool
    ) {
      let errorColor = NSColor(Color.feedbackNegative)

      if t.hasCard {
        cardView.isHidden = false
        let fillAccent = isError ? errorColor : accent

        switch m.displayTier {
          case .prominent:
            // Vibrant fill — stronger tint for questions
            let fillBlend: CGFloat = m.isInProgress ? 0.18 : 0.10
            let fill = NSColor(Color.backgroundSecondary).blended(
              withFraction: fillBlend,
              of: fillAccent.withAlphaComponent(0.25)
            ) ?? NSColor(Color.backgroundSecondary)
            let border = m.isFocusedWorker
              ? NSColor(Color.accent).withAlphaComponent(0.50)
              : fillAccent.withAlphaComponent(m.isInProgress ? 0.28 : 0.18)
            MacTimelineChrome.styleCard(cardView, fill: fill, border: border)
            cardView.layer?.borderWidth = t.borderWidth

          default:
            // Standard card
            let fillBlend: CGFloat = m.isInProgress ? 0.12 : 0.06
            let fill = NSColor(Color.backgroundSecondary).blended(
              withFraction: fillBlend,
              of: fillAccent.withAlphaComponent(0.15)
            ) ?? NSColor(Color.backgroundSecondary)
            let border = m.isFocusedWorker
              ? NSColor(Color.accent).withAlphaComponent(0.42)
              : fillAccent.withAlphaComponent(m.isInProgress ? 0.18 : 0.10)
            MacTimelineChrome.styleCard(cardView, fill: fill, border: border)
        }
      } else {
        cardView.isHidden = true
      }

      if t.hasAccentBar {
        accentBar.isHidden = false
        accentBar.layer?.backgroundColor = (isError ? errorColor : accent)
          .withAlphaComponent(m.isInProgress ? 0.90 : 0.55).cgColor
        accentBar.layer?.cornerRadius = t.accentBarWidth > 3 ? 2 : 1.5
      } else {
        accentBar.isHidden = true
      }
    }

    // MARK: Icon

    private func configureIcon(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      accent: NSColor, isError: Bool
    ) {
      glyphView.symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: t.iconPointSize,
        weight: m.displayTier == .prominent ? .semibold : .medium
      )
      glyphView.image = NSImage(systemSymbolName: m.glyphSymbol, accessibilityDescription: nil)

      switch m.displayTier {
        case .prominent:
          glyphView.contentTintColor = isError ? NSColor(Color.feedbackNegative) : accent
        case .standard:
          glyphView.contentTintColor = isError ? NSColor(Color.feedbackNegative) : accent
        case .compact:
          glyphView.contentTintColor = (isError ? NSColor(Color.feedbackNegative) : accent)
            .withAlphaComponent(0.50)
        case .minimal:
          glyphView.contentTintColor = NSColor(Color.textQuaternary).withAlphaComponent(0.50)
      }
    }

    // MARK: Summary

    private func configureSummary(_ m: NativeCompactToolRowModel, tier t: TierMetrics, isError: Bool) {
      summaryLabel.stringValue = m.summary
      summaryLabel.maximumNumberOfLines = t.summaryMaxLines
      summaryLabel.lineBreakMode = t.summaryMaxLines > 1 ? .byWordWrapping : .byTruncatingTail

      switch m.displayTier {
        case .prominent:
          summaryLabel.font = m.summaryFont == .mono
            ? .monospacedSystemFont(ofSize: TypeScale.subhead, weight: .semibold)
            : .systemFont(ofSize: TypeScale.subhead, weight: .semibold)
          summaryLabel.textColor = NSColor(Color.textPrimary)

        case .standard:
          summaryLabel.font = m.summaryFont == .mono
            ? .monospacedSystemFont(ofSize: TypeScale.body, weight: .medium)
            : .systemFont(ofSize: TypeScale.body, weight: .medium)
          summaryLabel.textColor = NSColor(Color.textPrimary)

        case .compact:
          summaryLabel.font = m.summaryFont == .mono
            ? .monospacedSystemFont(ofSize: TypeScale.caption, weight: .regular)
            : .systemFont(ofSize: TypeScale.caption, weight: .regular)
          summaryLabel.textColor = NSColor(Color.textTertiary)

        case .minimal:
          summaryLabel.font = .systemFont(ofSize: TypeScale.mini, weight: .regular)
          summaryLabel.textColor = NSColor(Color.textQuaternary)
      }
    }

    // MARK: Subtitle

    private func configureSubtitle(_ m: NativeCompactToolRowModel, tier t: TierMetrics) {
      guard let sub = m.subtitle, !sub.isEmpty else {
        dotSep.isHidden = true
        subtitleLabel.isHidden = true
        return
      }
      subtitleLabel.isHidden = false
      subtitleLabel.stringValue = sub

      switch m.displayTier {
        case .prominent:
          // Prominent: subtitle goes on its own line below summary — no dot separator
          dotSep.isHidden = true
          subtitleLabel.font = .systemFont(ofSize: TypeScale.caption, weight: .medium)
          subtitleLabel.textColor = NSColor(Color.textTertiary)

        case .standard:
          dotSep.isHidden = false
          dotSep.font = .systemFont(ofSize: TypeScale.caption, weight: .medium)
          subtitleLabel.font = .systemFont(ofSize: TypeScale.caption, weight: .regular)
          subtitleLabel.textColor = NSColor(Color.textTertiary)
          dotSep.textColor = NSColor(Color.textQuaternary)

        case .compact:
          dotSep.isHidden = false
          dotSep.font = .systemFont(ofSize: TypeScale.micro, weight: .medium)
          subtitleLabel.font = .systemFont(ofSize: TypeScale.micro, weight: .regular)
          subtitleLabel.textColor = NSColor(Color.textQuaternary)
          dotSep.textColor = NSColor(Color.textQuaternary).withAlphaComponent(0.6)

        case .minimal:
          dotSep.isHidden = true
          subtitleLabel.isHidden = true
      }
    }

    // MARK: Meta

    private func configureMeta(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      accent: NSColor, isError: Bool
    ) {
      guard let meta = m.rightMeta, !meta.isEmpty else {
        metaLabel.isHidden = true
        metaPill.isHidden = true
        return
      }

      metaLabel.isHidden = false
      metaLabel.stringValue = meta
      let pillColor = isError ? NSColor(Color.feedbackNegative) : accent

      switch m.displayTier {
        case .prominent:
          metaLabel.font = .monospacedSystemFont(ofSize: TypeScale.caption, weight: .semibold)
          metaPill.isHidden = false
          metaPill.layer?.backgroundColor = pillColor.withAlphaComponent(0.14).cgColor
          metaLabel.textColor = pillColor.withAlphaComponent(0.90)

        case .standard:
          metaLabel.font = .monospacedSystemFont(ofSize: TypeScale.mini, weight: .semibold)
          metaPill.isHidden = false
          metaPill.layer?.backgroundColor = pillColor.withAlphaComponent(0.10).cgColor
          metaLabel.textColor = pillColor.withAlphaComponent(0.85)

        case .compact:
          metaLabel.font = .monospacedSystemFont(ofSize: TypeScale.mini, weight: .regular)
          metaPill.isHidden = true
          metaLabel.textColor = NSColor(Color.textQuaternary)

        case .minimal:
          metaLabel.isHidden = true
          metaPill.isHidden = true
      }
    }

    // MARK: Detail

    private func configureDetail(_ m: NativeCompactToolRowModel, accent: NSColor) {
      if let diff = m.diffPreview {
        let prefixColor = diff.isAddition
          ? NSColor(Color.diffAddedAccent) : NSColor(Color.diffRemovedAccent)
        detailLabel.isHidden = false
        detailLabel.attributedStringValue = NSAttributedString(
          string: "\(diff.snippetPrefix) \(diff.snippetText)",
          attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular),
            .foregroundColor: prefixColor.withAlphaComponent(0.7),
          ]
        )
        diffBarTrack.isHidden = false
        return
      }

      diffBarTrack.isHidden = true

      if let live = m.liveOutputPreview, !live.isEmpty {
        detailLabel.isHidden = false
        detailLabel.stringValue = "> \(live)"
        detailLabel.font = .monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
        detailLabel.textColor = accent.withAlphaComponent(0.55)
        return
      }

      if let items = m.todoItems, !items.isEmpty {
        detailLabel.isHidden = false
        detailLabel.stringValue = items.prefix(12).map { item in
          switch item.status {
            case .completed: "\u{2713}"
            case .inProgress: "\u{25C9}"
            case .pending, .unknown: "\u{25CB}"
            case .blocked, .canceled: "\u{2298}"
          }
        }.joined(separator: " ")
        detailLabel.font = .systemFont(ofSize: TypeScale.micro, weight: .medium)
        detailLabel.textColor = NSColor(Color.textTertiary)
        return
      }

      if let output = m.outputPreview, !output.isEmpty {
        let firstLine = output.components(separatedBy: .newlines)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .first(where: { !$0.isEmpty }) ?? output
        detailLabel.isHidden = false
        detailLabel.stringValue = firstLine
        detailLabel.font = .monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
        detailLabel.textColor = NSColor(Color.textQuaternary)
        return
      }

      detailLabel.isHidden = true
    }

    // MARK: Worker

    private func configureWorker(_ m: NativeCompactToolRowModel, accent: NSColor) {
      guard let label = m.linkedWorkerLabel ?? m.linkedWorkerID else {
        workerPill.isHidden = true
        return
      }
      workerPill.isHidden = false
      workerPill.font = .monospacedSystemFont(ofSize: TypeScale.mini, weight: .semibold)
      var text = label.uppercased()
      if let status = m.linkedWorkerStatusText, !status.isEmpty {
        text += " \u{00B7} \(status.uppercased())"
      }
      workerPill.stringValue = text
      let pillColor = m.isFocusedWorker ? NSColor(Color.accent) : accent
      MacTimelineChrome.stylePill(workerPill, textColor: pillColor, fill: pillColor.withAlphaComponent(0.12))
    }

    // MARK: - Layout (non-flipped: origin at bottom-left, top = maxY)

    override func layout() {
      super.layout()
      guard let m = currentModel else { return }
      let t = TierMetrics.forTier(m.displayTier)
      let bw = bounds.width
      let bh = bounds.height
      guard bw > 0, bh > 0 else { return }

      let inset = ConversationLayout.laneHorizontalInset

      // Card background
      if t.hasCard {
        cardView.frame = NSRect(
          x: inset, y: t.vMargin,
          width: bw - inset * 2, height: bh - t.vMargin * 2
        )
      } else {
        cardView.frame = .zero
      }

      let contentL = inset
      let contentR = bw - inset

      // Accent bar: full-bleed for prominent, inset for standard
      let leading: CGFloat
      if t.hasAccentBar {
        let barX = contentL + Self.accentX
        let barTop = t.vMargin + t.accentBarInset
        let barH = bh - t.vMargin * 2 - t.accentBarInset * 2
        accentBar.frame = NSRect(
          x: barX, y: barTop,
          width: t.accentBarWidth, height: max(4, barH)
        )
        leading = barX + t.accentBarWidth + Self.hPad
      } else {
        accentBar.frame = .zero
        leading = contentL + Spacing.sm
      }

      let trailing = contentR - Self.hPad

      if m.displayTier == .prominent {
        layoutProminent(m, tier: t, leading: leading, trailing: trailing, bh: bh)
      } else {
        layoutStandard(m, tier: t, leading: leading, trailing: trailing, bh: bh)
      }
    }

    /// Top-down layout for prominent tier — multi-line summary, subtitle on own line.
    private func layoutProminent(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      leading: CGFloat, trailing: CGFloat, bh: CGFloat
    ) {
      // Non-flipped: build from top (maxY) downward
      var cursorY = bh - t.vMargin - 10 // top padding inside card

      // Icon aligned to first line of summary
      let iconY = cursorY - t.iconSize
      glyphView.frame = NSRect(x: leading, y: iconY, width: t.iconSize, height: t.iconSize)

      let textL = glyphView.frame.maxX + 6
      let textR: CGFloat

      // Meta (right-aligned, pinned to first line)
      if metaLabel.isHidden {
        metaLabel.frame = .zero
        metaPill.frame = .zero
        textR = trailing
      } else {
        let metaW = min(120, metaLabel.intrinsicContentSize.width + 16)
        let metaX = trailing - metaW
        metaLabel.frame = NSRect(x: metaX, y: iconY, width: metaW, height: t.rowH)
        if !metaPill.isHidden {
          metaPill.frame = metaLabel.frame.insetBy(dx: -4, dy: -2)
        } else {
          metaPill.frame = .zero
        }
        textR = metaLabel.frame.minX - 8
      }

      // Summary — multi-line, measured to fit
      let sumW = max(60, textR - textL)
      let summarySize = summaryLabel.sizeThatFits(NSSize(width: sumW, height: CGFloat(t.summaryMaxLines) * t.rowH))
      let summaryH = min(summarySize.height, CGFloat(t.summaryMaxLines) * t.rowH)
      summaryLabel.frame = NSRect(x: textL, y: cursorY - summaryH, width: sumW, height: summaryH)
      cursorY = summaryLabel.frame.minY

      // Subtitle on its own line (no dot separator for prominent)
      dotSep.frame = .zero
      if !subtitleLabel.isHidden {
        cursorY -= 2
        subtitleLabel.frame = NSRect(x: textL, y: cursorY - t.rowH + 4, width: sumW, height: t.rowH - 4)
        cursorY = subtitleLabel.frame.minY
      } else {
        subtitleLabel.frame = .zero
      }

      // Detail / diff / worker below
      layoutDetailSection(m, tier: t, textL: textL, textR: textR, startY: cursorY - 4)
    }

    /// Center-aligned layout for standard, compact, and minimal tiers.
    private func layoutStandard(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      leading: CGFloat, trailing: CGFloat, bh: CGFloat
    ) {
      // Center content in the baseH zone at the top (non-flipped)
      let centerY = bh - t.vMargin - t.baseH / 2
      let textY = centerY - t.rowH / 2
      let iconY = centerY - t.iconSize / 2

      glyphView.frame = NSRect(x: leading, y: iconY, width: t.iconSize, height: t.iconSize)

      // Meta (right-aligned)
      if metaLabel.isHidden {
        metaLabel.frame = .zero
        metaPill.frame = .zero
      } else {
        let metaW = min(120, metaLabel.intrinsicContentSize.width + 16)
        let metaX = trailing - metaW
        metaLabel.frame = NSRect(x: metaX, y: textY + 1, width: metaW, height: t.rowH)
        if !metaPill.isHidden {
          metaPill.frame = metaLabel.frame.insetBy(dx: -4, dy: -2)
        } else {
          metaPill.frame = .zero
        }
      }

      let textL = glyphView.frame.maxX + 6
      let textR = metaLabel.isHidden ? trailing : metaLabel.frame.minX - 8

      // Summary (single line)
      let sumW = min(max(60, textR - textL), summaryLabel.intrinsicContentSize.width)
      summaryLabel.frame = NSRect(x: textL, y: textY, width: sumW, height: t.rowH)

      // Dot + subtitle inline
      if !dotSep.isHidden {
        let dotX = summaryLabel.frame.maxX + 4
        dotSep.frame = NSRect(x: dotX, y: textY, width: 8, height: t.rowH)
        let subX = dotSep.frame.maxX + 2
        let subW = max(20, textR - subX)
        subtitleLabel.frame = NSRect(x: subX, y: textY, width: subW, height: t.rowH)
      } else {
        dotSep.frame = .zero
        if !subtitleLabel.isHidden {
          // Prominent case already handled — this shouldn't fire, but safety
          subtitleLabel.frame = .zero
        } else {
          subtitleLabel.frame = .zero
        }
      }

      // Detail / diff / worker below
      guard t.hasDetail else {
        detailLabel.frame = .zero
        diffBarTrack.frame = .zero
        diffBarAdded.frame = .zero
        diffBarRemoved.frame = .zero
        workerPill.frame = .zero
        return
      }

      layoutDetailSection(m, tier: t, textL: textL, textR: textR, startY: textY - 4)
    }

    /// Shared detail/diff/worker layout, used by both prominent and standard.
    private func layoutDetailSection(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      textL: CGFloat, textR: CGFloat, startY: CGFloat
    ) {
      guard t.hasDetail else {
        detailLabel.frame = .zero
        diffBarTrack.frame = .zero
        diffBarAdded.frame = .zero
        diffBarRemoved.frame = .zero
        workerPill.frame = .zero
        return
      }

      var nextY = startY

      if !detailLabel.isHidden {
        let dw = textR - textL
        detailLabel.frame = NSRect(x: textL, y: nextY - t.detailH, width: dw, height: t.detailH)
        nextY = detailLabel.frame.minY - 2
      } else {
        detailLabel.frame = .zero
      }

      if !diffBarTrack.isHidden, let diff = m.diffPreview {
        let barW: CGFloat = min(100, textR - textL)
        diffBarTrack.frame = NSRect(x: textL, y: nextY - 4, width: barW, height: 4)
        let widths = diff.barWidths(maxWidth: barW)
        diffBarAdded.frame = NSRect(x: 0, y: 0, width: widths.added, height: 4)
        diffBarAdded.layer?.backgroundColor = m.glyphColor.withAlphaComponent(0.9).cgColor
        diffBarRemoved.frame = NSRect(x: max(0, widths.added + 1), y: 0, width: widths.removed, height: 4)
        diffBarRemoved.layer?.backgroundColor = NSColor(Color.feedbackNegative).withAlphaComponent(0.7).cgColor
        nextY = diffBarTrack.frame.minY - 2
      } else {
        diffBarTrack.frame = .zero
        diffBarAdded.frame = .zero
        diffBarRemoved.frame = .zero
      }

      if !workerPill.isHidden {
        let wpW = min(200, workerPill.intrinsicContentSize.width + 18)
        workerPill.frame = NSRect(x: textL, y: nextY - 18, width: wpW, height: 18)
      } else {
        workerPill.frame = .zero
      }
    }
  }

#endif
