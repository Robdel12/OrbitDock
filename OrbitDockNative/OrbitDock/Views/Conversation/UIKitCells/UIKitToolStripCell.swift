//
//  UIKitToolStripCell.swift
//  OrbitDock
//
//  Tier-aware renderer of NativeCompactToolRowModel on iOS.
//  The server's ToolDisplay drives everything — displayTier determines
//  the visual treatment:
//
//   prominent (Question)      — 48pt, vibrant card, thick bar, bold text
//   standard  (Shell/Edit/…)  — 38pt, card with accent bar, detail line
//   compact   (Read/Glob/…)   — 26pt, no card, small muted inline text
//   minimal   (Skill/Plan/…)  — 20pt, no card, tiny dimmed text
//

#if os(iOS)

  import SwiftUI
  import UIKit

  final class UIKitToolStripCell: UICollectionViewCell {
    static let reuseIdentifier = "UIKitToolStripCell"

    private let cardBg = CellCardBackground()
    private let accentBar = UIView()
    private let glyphImage = UIImageView()
    private let summaryLabel = UILabel()
    private let dotSep = UILabel()
    private let subtitleLabel = UILabel()
    private let metaLabel = UILabel()
    private let metaPillBg = UIView()
    private let detailLabel = UILabel()
    private let diffBarTrack = UIView()
    private let diffBarAdded = UIView()
    private let diffBarRemoved = UIView()
    private let workerPill = UILabel()

    var onTap: (() -> Void)?
    var onFocusWorker: (() -> Void)?

    private var currentModel: NativeCompactToolRowModel?

    // Per-tier geometry (mirrors macOS TierMetrics)
    private struct TierMetrics {
      let baseH: CGFloat
      let vMargin: CGFloat
      let iconSize: CGFloat
      let iconPointSize: CGFloat
      let rowH: CGFloat
      let detailH: CGFloat
      let summaryMaxLines: Int
      let hasCard: Bool
      let hasAccentBar: Bool
      let hasDetail: Bool
      let hasWorker: Bool
      let accentBarWidth: CGFloat
      let accentBarInset: CGFloat

      static let prominent = TierMetrics(
        baseH: 48, vMargin: 3, iconSize: 16, iconPointSize: 13,
        rowH: 20, detailH: 14, summaryMaxLines: 3,
        hasCard: true, hasAccentBar: true,
        hasDetail: true, hasWorker: true,
        accentBarWidth: 4, accentBarInset: 0
      )
      static let standard = TierMetrics(
        baseH: 38, vMargin: 2, iconSize: 14, iconPointSize: 12,
        rowH: 18, detailH: 14, summaryMaxLines: 1,
        hasCard: true, hasAccentBar: true,
        hasDetail: true, hasWorker: true,
        accentBarWidth: EdgeBar.width, accentBarInset: 7
      )
      static let compact = TierMetrics(
        baseH: 26, vMargin: 1, iconSize: 11, iconPointSize: 10,
        rowH: 16, detailH: 0, summaryMaxLines: 1,
        hasCard: false, hasAccentBar: false,
        hasDetail: false, hasWorker: false,
        accentBarWidth: 0, accentBarInset: 0
      )
      static let minimal = TierMetrics(
        baseH: 20, vMargin: 1, iconSize: 10, iconPointSize: 9,
        rowH: 14, detailH: 0, summaryMaxLines: 1,
        hasCard: false, hasAccentBar: false,
        hasDetail: false, hasWorker: false,
        accentBarWidth: 0, accentBarInset: 0
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

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      contentView.backgroundColor = .clear

      cardBg.install(in: contentView)

      accentBar.layer.cornerRadius = 1.5
      contentView.addSubview(accentBar)

      glyphImage.contentMode = .scaleAspectFit
      contentView.addSubview(glyphImage)

      summaryLabel.lineBreakMode = .byTruncatingTail
      contentView.addSubview(summaryLabel)

      dotSep.text = "\u{00B7}"
      dotSep.isHidden = true
      contentView.addSubview(dotSep)

      subtitleLabel.lineBreakMode = .byTruncatingTail
      subtitleLabel.isHidden = true
      contentView.addSubview(subtitleLabel)

      metaPillBg.layer.cornerRadius = 4
      metaPillBg.isHidden = true
      contentView.addSubview(metaPillBg)

      metaLabel.textAlignment = .center
      metaLabel.lineBreakMode = .byTruncatingTail
      metaLabel.isHidden = true
      contentView.addSubview(metaLabel)

      detailLabel.lineBreakMode = .byTruncatingTail
      detailLabel.isHidden = true
      contentView.addSubview(detailLabel)

      diffBarTrack.layer.cornerRadius = 2
      diffBarTrack.backgroundColor = UIColor(Color.backgroundTertiary).withAlphaComponent(0.9)
      diffBarTrack.isHidden = true
      contentView.addSubview(diffBarTrack)

      diffBarAdded.layer.cornerRadius = 2
      diffBarTrack.addSubview(diffBarAdded)

      diffBarRemoved.layer.cornerRadius = 2
      diffBarTrack.addSubview(diffBarRemoved)

      workerPill.lineBreakMode = .byTruncatingTail
      workerPill.textAlignment = .center
      workerPill.layer.cornerRadius = 8
      workerPill.layer.masksToBounds = true
      workerPill.isHidden = true
      contentView.addSubview(workerPill)

      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
      contentView.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap() {
      onTap?()
    }

    // MARK: - Height

    static func requiredHeight(for model: NativeCompactToolRowModel, width: CGFloat) -> CGFloat {
      let t = TierMetrics.forTier(model.displayTier)
      var h = t.baseH

      // Prominent: measure multi-line summary
      if t.summaryMaxLines > 1 {
        let extraLines = measuredSummaryLineCount(model, tier: t, width: width) - 1
        if extraLines > 0 {
          h += CGFloat(extraLines) * (t.rowH - 2)
        }
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

    private static func measuredSummaryLineCount(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics, width: CGFloat
    ) -> Int {
      let font: UIFont = m.summaryFont == .mono
        ? .monospacedSystemFont(ofSize: TypeScale.subhead, weight: .semibold)
        : .systemFont(ofSize: TypeScale.subhead, weight: .semibold)

      let leading = 6 + t.accentBarWidth + 10 + t.iconSize + 6
      let trailing: CGFloat = 10
      let metaSpace: CGFloat = m.rightMeta != nil ? 100 : 0
      let availW = max(100, width - leading - trailing - metaSpace)

      let attr = NSAttributedString(string: m.summary, attributes: [.font: font])
      let rect = attr.boundingRect(
        with: CGSize(width: availW, height: CGFloat(t.summaryMaxLines) * font.pointSize * 1.5),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
      let lineH = font.pointSize * 1.3
      return min(t.summaryMaxLines, max(1, Int(ceil(rect.height / lineH))))
    }

    // MARK: - Configure

    func configure(model: NativeCompactToolRowModel) {
      let m = model
      currentModel = m
      let t = TierMetrics.forTier(m.displayTier)

      let accent: UIColor = m.glyphColor
      let isError = (m.rightMeta ?? "").hasPrefix("\u{2717}")

      configureCardChrome(m, tier: t, accent: accent, isError: isError)
      configureIcon(m, tier: t, accent: accent, isError: isError)
      configureSummary(m, tier: t)
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

      setNeedsLayout()
    }

    // MARK: Card Chrome

    private func configureCardChrome(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      accent: UIColor, isError: Bool
    ) {
      let errorColor = UIColor(Color.feedbackNegative)

      // Card visibility is handled by cardBg alpha in layout
      // For no-card tiers, we just make it transparent

      if t.hasAccentBar {
        accentBar.isHidden = false
        accentBar.backgroundColor = (isError ? errorColor : accent)
          .withAlphaComponent(m.isInProgress ? 0.90 : 0.55)
        accentBar.layer.cornerRadius = t.accentBarWidth > 3 ? 2 : 1.5
      } else {
        accentBar.isHidden = true
      }
    }

    // MARK: Icon

    private func configureIcon(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      accent: UIColor, isError: Bool
    ) {
      glyphImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: t.iconPointSize,
        weight: m.displayTier == .prominent ? .semibold : .medium
      )
      glyphImage.image = UIImage(systemName: m.glyphSymbol)

      switch m.displayTier {
        case .prominent, .standard:
          glyphImage.tintColor = isError ? UIColor(Color.feedbackNegative) : accent
        case .compact:
          glyphImage.tintColor = (isError ? UIColor(Color.feedbackNegative) : accent)
            .withAlphaComponent(0.50)
        case .minimal:
          glyphImage.tintColor = UIColor(Color.textQuaternary).withAlphaComponent(0.50)
      }
    }

    // MARK: Summary

    private func configureSummary(_ m: NativeCompactToolRowModel, tier t: TierMetrics) {
      summaryLabel.text = m.summary
      summaryLabel.numberOfLines = t.summaryMaxLines
      summaryLabel.lineBreakMode = t.summaryMaxLines > 1 ? .byWordWrapping : .byTruncatingTail

      switch m.displayTier {
        case .prominent:
          summaryLabel.font = m.summaryFont == .mono
            ? .monospacedSystemFont(ofSize: TypeScale.subhead, weight: .semibold)
            : .systemFont(ofSize: TypeScale.subhead, weight: .semibold)
          summaryLabel.textColor = UIColor(Color.textPrimary)

        case .standard:
          summaryLabel.font = m.summaryFont == .mono
            ? .monospacedSystemFont(ofSize: TypeScale.body, weight: .medium)
            : .systemFont(ofSize: TypeScale.body, weight: .medium)
          summaryLabel.textColor = UIColor(Color.textPrimary)

        case .compact:
          summaryLabel.font = m.summaryFont == .mono
            ? .monospacedSystemFont(ofSize: TypeScale.caption, weight: .regular)
            : .systemFont(ofSize: TypeScale.caption, weight: .regular)
          summaryLabel.textColor = UIColor(Color.textTertiary)

        case .minimal:
          summaryLabel.font = .systemFont(ofSize: TypeScale.mini, weight: .regular)
          summaryLabel.textColor = UIColor(Color.textQuaternary)
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
      subtitleLabel.text = sub

      switch m.displayTier {
        case .prominent:
          // Prominent: subtitle on its own line, no dot
          dotSep.isHidden = true
          subtitleLabel.font = .systemFont(ofSize: TypeScale.caption, weight: .medium)
          subtitleLabel.textColor = UIColor(Color.textTertiary)

        case .standard:
          dotSep.isHidden = false
          dotSep.font = .systemFont(ofSize: TypeScale.caption, weight: .medium)
          subtitleLabel.font = .systemFont(ofSize: TypeScale.caption, weight: .regular)
          subtitleLabel.textColor = UIColor(Color.textTertiary)
          dotSep.textColor = UIColor(Color.textQuaternary)

        case .compact:
          dotSep.isHidden = false
          dotSep.font = .systemFont(ofSize: TypeScale.micro, weight: .medium)
          subtitleLabel.font = .systemFont(ofSize: TypeScale.micro, weight: .regular)
          subtitleLabel.textColor = UIColor(Color.textQuaternary)
          dotSep.textColor = UIColor(Color.textQuaternary).withAlphaComponent(0.6)

        case .minimal:
          dotSep.isHidden = true
          subtitleLabel.isHidden = true
      }
    }

    // MARK: Meta

    private func configureMeta(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      accent: UIColor, isError: Bool
    ) {
      guard let meta = m.rightMeta, !meta.isEmpty else {
        metaLabel.isHidden = true
        metaPillBg.isHidden = true
        return
      }

      metaLabel.isHidden = false
      metaLabel.text = meta
      let pillColor = isError ? UIColor(Color.feedbackNegative) : accent

      switch m.displayTier {
        case .prominent:
          metaLabel.font = .monospacedSystemFont(ofSize: TypeScale.caption, weight: .semibold)
          metaPillBg.isHidden = false
          metaPillBg.backgroundColor = pillColor.withAlphaComponent(0.14)
          metaLabel.textColor = pillColor.withAlphaComponent(0.90)

        case .standard:
          metaLabel.font = .monospacedSystemFont(ofSize: TypeScale.mini, weight: .semibold)
          metaPillBg.isHidden = false
          metaPillBg.backgroundColor = pillColor.withAlphaComponent(0.10)
          metaLabel.textColor = pillColor.withAlphaComponent(0.85)

        case .compact:
          metaLabel.font = .monospacedSystemFont(ofSize: TypeScale.mini, weight: .regular)
          metaPillBg.isHidden = true
          metaLabel.textColor = UIColor(Color.textQuaternary)

        case .minimal:
          metaLabel.isHidden = true
          metaPillBg.isHidden = true
      }
    }

    // MARK: Detail

    private func configureDetail(_ m: NativeCompactToolRowModel, accent: UIColor) {
      if let diff = m.diffPreview {
        let prefixColor = diff.isAddition
          ? UIColor(Color.diffAddedAccent) : UIColor(Color.diffRemovedAccent)
        detailLabel.isHidden = false
        detailLabel.attributedText = NSAttributedString(
          string: "\(diff.snippetPrefix) \(diff.snippetText)",
          attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular),
            .foregroundColor: prefixColor.withAlphaComponent(0.7),
          ]
        )
        diffBarTrack.isHidden = false
        return
      }

      diffBarTrack.isHidden = true

      if let live = m.liveOutputPreview, !live.isEmpty {
        detailLabel.isHidden = false
        detailLabel.text = "> \(live)"
        detailLabel.font = .monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
        detailLabel.textColor = accent.withAlphaComponent(0.55)
        return
      }

      if let items = m.todoItems, !items.isEmpty {
        detailLabel.isHidden = false
        detailLabel.text = items.prefix(12).map { item in
          switch item.status {
            case .completed: "\u{2713}"
            case .inProgress: "\u{25C9}"
            case .pending, .unknown: "\u{25CB}"
            case .blocked, .canceled: "\u{2298}"
          }
        }.joined(separator: " ")
        detailLabel.font = .systemFont(ofSize: TypeScale.micro, weight: .medium)
        detailLabel.textColor = UIColor(Color.textTertiary)
        return
      }

      if let output = m.outputPreview, !output.isEmpty {
        let firstLine = output.components(separatedBy: .newlines)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .first(where: { !$0.isEmpty }) ?? output
        detailLabel.isHidden = false
        detailLabel.text = firstLine
        detailLabel.font = .monospacedSystemFont(ofSize: TypeScale.micro, weight: .regular)
        detailLabel.textColor = UIColor(Color.textQuaternary)
        return
      }

      detailLabel.isHidden = true
    }

    // MARK: Worker

    private func configureWorker(_ m: NativeCompactToolRowModel, accent: UIColor) {
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
      workerPill.text = text
      let pillColor = m.isFocusedWorker ? UIColor(Color.accent) : accent
      workerPill.textColor = pillColor
      workerPill.backgroundColor = pillColor.withAlphaComponent(0.12)
    }

    // MARK: - Layout (flipped — origin at top-left)

    override func layoutSubviews() {
      super.layoutSubviews()
      guard let m = currentModel else { return }
      let t = TierMetrics.forTier(m.displayTier)

      if t.hasCard {
        cardBg.layoutInBounds(contentView.bounds)
      } else {
        cardBg.layoutInBounds(.zero)
      }

      let cb = contentView.bounds
      guard cb.width > 0, cb.height > 0 else { return }

      // Accent bar: full-bleed for prominent, inset for standard
      let leading: CGFloat
      if t.hasAccentBar {
        accentBar.frame = CGRect(
          x: Self.accentX,
          y: t.accentBarInset,
          width: t.accentBarWidth,
          height: cb.height - t.accentBarInset * 2
        )
        accentBar.layer.cornerRadius = t.accentBarWidth > 3 ? 2 : 1.5
        leading = Self.accentX + t.accentBarWidth + Self.hPad
      } else {
        accentBar.frame = .zero
        leading = Spacing.sm
      }

      let trailing = cb.width - Self.hPad

      if m.displayTier == .prominent {
        layoutProminent(m, tier: t, leading: leading, trailing: trailing)
      } else {
        layoutStandard(m, tier: t, leading: leading, trailing: trailing)
      }
    }

    /// Top-down layout for prominent tier — multi-line summary, subtitle on own line.
    private func layoutProminent(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      leading: CGFloat, trailing: CGFloat
    ) {
      var cursorY: CGFloat = t.vMargin + 10 // top padding

      let iconY = cursorY
      glyphImage.frame = CGRect(x: leading, y: iconY, width: t.iconSize, height: t.iconSize)

      let textL = glyphImage.frame.maxX + 6
      let textR: CGFloat

      // Meta pinned to first line
      if metaLabel.isHidden {
        metaLabel.frame = .zero
        metaPillBg.frame = .zero
        textR = trailing
      } else {
        let metaW = min(120, metaLabel.intrinsicContentSize.width + 16)
        let metaX = trailing - metaW
        metaLabel.frame = CGRect(x: metaX, y: iconY, width: metaW, height: t.rowH)
        if !metaPillBg.isHidden {
          metaPillBg.frame = metaLabel.frame.insetBy(dx: -4, dy: -2)
        } else {
          metaPillBg.frame = .zero
        }
        textR = metaLabel.frame.minX - 8
      }

      // Multi-line summary
      let sumW = max(60, textR - textL)
      let summarySize = summaryLabel.sizeThatFits(CGSize(width: sumW, height: CGFloat(t.summaryMaxLines) * t.rowH))
      let summaryH = min(summarySize.height, CGFloat(t.summaryMaxLines) * t.rowH)
      summaryLabel.frame = CGRect(x: textL, y: cursorY, width: sumW, height: summaryH)
      cursorY = summaryLabel.frame.maxY

      // Subtitle on own line (no dot)
      dotSep.frame = .zero
      if !subtitleLabel.isHidden {
        cursorY += 2
        subtitleLabel.frame = CGRect(x: textL, y: cursorY, width: sumW, height: t.rowH - 4)
        cursorY = subtitleLabel.frame.maxY
      } else {
        subtitleLabel.frame = .zero
      }

      layoutDetailSection(m, tier: t, textL: textL, textR: textR, startY: cursorY + 4)
    }

    /// Center-aligned layout for standard, compact, and minimal.
    private func layoutStandard(
      _ m: NativeCompactToolRowModel, tier t: TierMetrics,
      leading: CGFloat, trailing: CGFloat
    ) {
      let centerY = t.baseH / 2
      let textY = centerY - t.rowH / 2
      let iconY = centerY - t.iconSize / 2

      glyphImage.frame = CGRect(x: leading, y: iconY, width: t.iconSize, height: t.iconSize)

      if metaLabel.isHidden {
        metaLabel.frame = .zero
        metaPillBg.frame = .zero
      } else {
        let metaW = min(120, metaLabel.intrinsicContentSize.width + 16)
        let metaX = trailing - metaW
        metaLabel.frame = CGRect(x: metaX, y: textY + 1, width: metaW, height: t.rowH)
        if !metaPillBg.isHidden {
          metaPillBg.frame = metaLabel.frame.insetBy(dx: -4, dy: -2)
        } else {
          metaPillBg.frame = .zero
        }
      }

      let textL = glyphImage.frame.maxX + 6
      let textR = metaLabel.isHidden ? trailing : metaLabel.frame.minX - 8

      let sumW = min(max(60, textR - textL), summaryLabel.intrinsicContentSize.width)
      summaryLabel.frame = CGRect(x: textL, y: textY, width: sumW, height: t.rowH)

      if !dotSep.isHidden {
        let dotX = summaryLabel.frame.maxX + 4
        dotSep.frame = CGRect(x: dotX, y: textY, width: 8, height: t.rowH)
        let subX = dotSep.frame.maxX + 2
        let subW = max(20, textR - subX)
        subtitleLabel.frame = CGRect(x: subX, y: textY, width: subW, height: t.rowH)
      } else {
        dotSep.frame = .zero
        subtitleLabel.frame = .zero
      }

      guard t.hasDetail else {
        detailLabel.frame = .zero
        diffBarTrack.frame = .zero
        diffBarAdded.frame = .zero
        diffBarRemoved.frame = .zero
        workerPill.frame = .zero
        return
      }

      layoutDetailSection(m, tier: t, textL: textL, textR: textR, startY: textY + t.rowH + 4)
    }

    /// Shared detail/diff/worker layout for both prominent and standard.
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
        detailLabel.frame = CGRect(x: textL, y: nextY, width: dw, height: t.detailH)
        nextY = detailLabel.frame.maxY + 2
      } else {
        detailLabel.frame = .zero
      }

      if !diffBarTrack.isHidden, let diff = m.diffPreview {
        let barW = min(100, textR - textL)
        diffBarTrack.frame = CGRect(x: textL, y: nextY, width: barW, height: 4)
        let widths = diff.barWidths(maxWidth: barW)
        diffBarAdded.frame = CGRect(x: 0, y: 0, width: widths.added, height: 4)
        diffBarAdded.backgroundColor = m.glyphColor.withAlphaComponent(0.9)
        diffBarRemoved.frame = CGRect(x: max(0, widths.added + 1), y: 0, width: widths.removed, height: 4)
        diffBarRemoved.backgroundColor = UIColor(Color.feedbackNegative).withAlphaComponent(0.7)
        nextY = diffBarTrack.frame.maxY + 2
      } else {
        diffBarTrack.frame = .zero
        diffBarAdded.frame = .zero
        diffBarRemoved.frame = .zero
      }

      if !workerPill.isHidden {
        let wpW = min(200, workerPill.intrinsicContentSize.width + 18)
        workerPill.frame = CGRect(x: textL, y: nextY, width: wpW, height: 18)
      } else {
        workerPill.frame = .zero
      }
    }

    // MARK: - Card Position (for turn grouping)

    func configureCardPosition(_ position: CardPosition, topInset: CGFloat, bottomInset: CGFloat) {
      guard currentModel?.displayTier != .compact && currentModel?.displayTier != .minimal else {
        // No card chrome for lightweight tiers
        return
      }
      cardBg.configure(position: position, topInset: topInset, bottomInset: bottomInset)
    }
  }

#endif
