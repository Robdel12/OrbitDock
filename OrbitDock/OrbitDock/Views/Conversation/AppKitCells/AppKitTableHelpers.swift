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
