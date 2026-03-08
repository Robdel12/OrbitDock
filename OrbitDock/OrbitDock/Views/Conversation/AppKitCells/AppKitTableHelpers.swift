//
//  AppKitTableHelpers.swift
//  OrbitDock
//
//  macOS-specific NSTableRowView / NSTableView / NSClipView subclasses
//  for the conversation timeline.
//

#if os(macOS)

  import AppKit

  // MARK: - Clear Row View

  /// Transparent row view that suppresses selection highlighting.
  final class ClearTableRowView: NSTableRowView {
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      wantsLayer = true
      layer?.masksToBounds = true
    }

    override var isOpaque: Bool {
      false
    }

    override var wantsUpdateLayer: Bool {
      true
    }

    override func updateLayer() {
      layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func drawSelection(in dirtyRect: NSRect) {}
  }

  // MARK: - Card Row View

  /// Row view that draws a subtle card background behind assistant turn content.
  /// Corner rounding is controlled by `cardPosition` — top, middle, bottom, or solo.
  final class CardTableRowView: NSTableRowView {
    var cardPosition: CardPosition = .solo {
      didSet {
        if oldValue != cardPosition { updateCorners() }
      }
    }

    /// Vertical inset for the card background layer (set by collection view).
    var cardTopInset: CGFloat = 0
    var cardBottomInset: CGFloat = 0

    private let cardLayer = CALayer()
    private let cardInset = ConversationLayout.cardHorizontalInset

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      commonInit()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      commonInit()
    }

    private func commonInit() {
      wantsLayer = true
      layer?.masksToBounds = true
      layer?.backgroundColor = NSColor.clear.cgColor

      cardLayer.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
      layer?.insertSublayer(cardLayer, at: 0)
      updateCorners()
    }

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
      layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func drawSelection(in dirtyRect: NSRect) {}

    override func layout() {
      super.layout()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      cardLayer.frame = NSRect(
        x: cardInset,
        y: cardTopInset,
        width: bounds.width - cardInset * 2,
        height: bounds.height - cardTopInset - cardBottomInset
      )
      CATransaction.commit()
    }

    private func updateCorners() {
      let r = ConversationLayout.cardCornerRadius
      switch cardPosition {
        case .solo:
          cardLayer.cornerRadius = r
          cardLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                     .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .top:
          cardLayer.cornerRadius = r
          cardLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .bottom:
          cardLayer.cornerRadius = r
          cardLayer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .middle:
          cardLayer.cornerRadius = 0
          cardLayer.maskedCorners = []
        case .none:
          cardLayer.cornerRadius = 0
          cardLayer.maskedCorners = []
      }
    }
  }

  // MARK: - Width-Clamped Table View

  /// NSTableView subclass that clamps its frame width to the enclosing clip view.
  /// NSTableView internally recomputes its frame from column metrics in `tile()`,
  /// which can make it wider than the scroll view. This override prevents that.
  final class WidthClampedTableView: NSTableView {
    override func tile() {
      super.tile()
      if let clipWidth = enclosingScrollView?.contentView.bounds.width,
         frame.width != clipWidth
      {
        frame.size.width = clipWidth
      }
    }
  }

  // MARK: - Vertical-Only Clip View

  final class VerticalOnlyClipView: NSClipView {
    override var isFlipped: Bool {
      true
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
      var constrained = super.constrainBoundsRect(proposedBounds)
      constrained.origin.x = 0
      return constrained
    }
  }

#endif
