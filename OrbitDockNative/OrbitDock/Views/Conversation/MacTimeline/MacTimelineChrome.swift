#if os(macOS)
  import AppKit
  import SwiftUI

  enum MacTimelineChrome {
    static func styleCard(
      _ view: NSView,
      fill: NSColor,
      border: NSColor,
      radius: CGFloat = Radius.lg
    ) {
      view.wantsLayer = true
      view.layer?.cornerRadius = radius
      view.layer?.borderWidth = 1
      view.layer?.backgroundColor = fill.cgColor
      view.layer?.borderColor = border.cgColor
    }

    static func styleInsetPanel(
      _ view: NSView,
      fill: NSColor,
      border: NSColor
    ) {
      view.wantsLayer = true
      view.layer?.cornerRadius = Radius.md
      view.layer?.borderWidth = 1
      view.layer?.backgroundColor = fill.cgColor
      view.layer?.borderColor = border.cgColor
    }

    static func stylePill(
      _ label: NSTextField,
      textColor: NSColor,
      fill: NSColor
    ) {
      label.textColor = textColor
      label.alignment = .center
      label.lineBreakMode = .byTruncatingTail
      label.maximumNumberOfLines = 1
      label.wantsLayer = true
      label.layer?.cornerRadius = 8
      label.layer?.masksToBounds = true
      label.layer?.backgroundColor = fill.cgColor
    }
  }
#endif
