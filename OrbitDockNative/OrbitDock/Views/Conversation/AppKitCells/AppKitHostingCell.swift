//
//  AppKitHostingCell.swift
//  OrbitDock
//
//  macOS-specific hosting cell that wraps SwiftUI content in an NSTableCellView
//  for fallback rows (images, live indicator). Includes a layout-observing
//  hosting view that reports intrinsic content size changes.
//

#if os(macOS)

  import AppKit
  import SwiftUI

  // MARK: - Hosting Table Cell

  final class HostingTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationHostingTableCell")

    private var hostingView: LayoutObservingHostingView?
    private var isConfiguringContent = false
    private var isMeasuringHeight = false
    var onContentHeightDidChange: ((CGFloat) -> Void)?

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
      canDrawSubviewsIntoLayer = true
    }

    func clearContent() {
      isConfiguringContent = true
      defer { isConfiguringContent = false }
      hostingView?.rootView = AnyView(EmptyView())
    }

    func configure(with content: AnyView, maxWidth: CGFloat) {
      isConfiguringContent = true
      defer { isConfiguringContent = false }

      let clampedWidth = max(1, maxWidth)
      let horizontalInsets = ConversationLayout.railHorizontalInset
      let maxConversationRailWidth = ConversationLayout.railMaxWidth
      let innerWidth = max(1, clampedWidth - (horizontalInsets * 2))
      let railWidth = min(innerWidth, maxConversationRailWidth)
      let constrainedContent = AnyView(
        content
          .frame(maxWidth: railWidth, alignment: .leading)
          .frame(maxWidth: innerWidth, alignment: .center)
          .padding(.horizontal, horizontalInsets)
          .frame(maxWidth: clampedWidth, alignment: .center)
          .fixedSize(horizontal: false, vertical: true)
      )
      if let hostingView {
        hostingView.rootView = constrainedContent
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.resetObservedHeight()
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
      } else {
        let hostingView = LayoutObservingHostingView(rootView: constrainedContent)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.onIntrinsicContentSizeInvalidated = { [weak self] height in
          guard let self else { return }
          guard !self.isConfiguringContent, !self.isMeasuringHeight else { return }
          self.onContentHeightDidChange?(height)
        }
        addSubview(hostingView)
        NSLayoutConstraint.activate([
          hostingView.topAnchor.constraint(equalTo: topAnchor),
          hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
          hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
          hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hostingView.layoutSubtreeIfNeeded()
        hostingView.resetObservedHeight()
        self.hostingView = hostingView
      }
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
      guard width > 1 else { return 1 }
      isMeasuringHeight = true
      defer { isMeasuringHeight = false }

      // Reset both frames to a clean baseline so previous row's dimensions
      // don't pollute fittingSize/intrinsicContentSize of the current row.
      let baseline = NSRect(x: 0, y: 0, width: width, height: 1)
      frame = baseline
      guard let hostingView else { return 1 }
      hostingView.frame = baseline

      hostingView.invalidateIntrinsicContentSize()
      hostingView.layoutSubtreeIfNeeded()

      let intrinsic = hostingView.intrinsicContentSize
      let fitting = hostingView.fittingSize

      // Prefer intrinsicContentSize — it reflects what SwiftUI actually needs.
      // fittingSize can be polluted by the hosting view's current frame height.
      let height: CGFloat = if intrinsic.height.isFinite, intrinsic.height > 0,
                               intrinsic.height != NSView.noIntrinsicMetric
      {
        intrinsic.height
      } else {
        fitting.height
      }

      return max(1, height)
    }
  }

  // MARK: - Layout Observing Hosting View

  final class LayoutObservingHostingView: NSHostingView<AnyView> {
    var onIntrinsicContentSizeInvalidated: ((CGFloat) -> Void)?
    private var lastObservedHeight: CGFloat?

    override func invalidateIntrinsicContentSize() {
      super.invalidateIntrinsicContentSize()
      publishObservedHeightIfNeeded()
    }

    override func layout() {
      super.layout()
      publishObservedHeightIfNeeded()
    }

    func resetObservedHeight() {
      lastObservedHeight = nil
    }

    private var measuredIntrinsicHeight: CGFloat {
      let intrinsic = intrinsicContentSize.height
      if intrinsic.isFinite, intrinsic > 0, intrinsic != NSView.noIntrinsicMetric {
        return intrinsic
      }
      return fittingSize.height
    }

    private func publishObservedHeightIfNeeded() {
      let measuredHeight = measuredIntrinsicHeight
      guard measuredHeight.isFinite, measuredHeight > 1 else { return }
      // Skip small deltas to reduce callback churn — the engine-level
      // oscillation guard handles the real protection.
      if let previous = lastObservedHeight, abs(previous - measuredHeight) < 4.0 {
        return
      }
      lastObservedHeight = measuredHeight
      onIntrinsicContentSizeInvalidated?(measuredHeight)
    }
  }

#endif
