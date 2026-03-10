//
//  AppKitStructuralBaseCells.swift
//  OrbitDock
//
//  macOS-specific NSTableCellView subclasses for simple structural timeline rows:
//  spacers, load-more buttons, and message counts.
//

#if os(macOS)

  import AppKit
  import SwiftUI

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
      button.font = NSFont.systemFont(ofSize: TypeScale.meta, weight: .medium)
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
      label.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .medium)
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

#endif
