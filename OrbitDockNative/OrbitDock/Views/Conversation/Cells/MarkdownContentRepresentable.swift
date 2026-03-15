//
//  MarkdownContentRepresentable.swift
//  OrbitDock
//
//  Bridges NativeMarkdownContentView (AppKit/UIKit) into SwiftUI.
//  Takes an explicit availableWidth for deterministic height calculation.
//

import SwiftUI

struct MarkdownContentRepresentable: View {
  let content: String
  let style: ContentStyle
  let availableWidth: CGFloat

  private var blocks: [MarkdownBlock] {
    MarkdownSystemParser.parse(content, style: style)
  }

  private var measuredHeight: CGFloat {
    NativeMarkdownContentView.requiredHeight(for: blocks, width: availableWidth, style: style)
  }

  var body: some View {
    MarkdownBridge(content: content, style: style, width: availableWidth)
      .frame(height: max(1, measuredHeight))
  }
}

#if os(macOS)
  private struct MarkdownBridge: NSViewRepresentable {
    let content: String
    let style: ContentStyle
    let width: CGFloat

    func makeNSView(context: Context) -> NativeMarkdownContentView {
      NativeMarkdownContentView(frame: .zero)
    }

    func updateNSView(_ view: NativeMarkdownContentView, context: Context) {
      let blocks = MarkdownSystemParser.parse(content, style: style)
      let height = NativeMarkdownContentView.requiredHeight(for: blocks, width: width, style: style)
      view.frame = CGRect(x: 0, y: 0, width: width, height: height)
      view.configure(blocks: blocks, style: style)
    }
  }
#else
  private struct MarkdownBridge: UIViewRepresentable {
    let content: String
    let style: ContentStyle
    let width: CGFloat

    func makeUIView(context: Context) -> NativeMarkdownContentView {
      NativeMarkdownContentView(frame: .zero)
    }

    func updateUIView(_ view: NativeMarkdownContentView, context: Context) {
      let blocks = MarkdownSystemParser.parse(content, style: style)
      let height = NativeMarkdownContentView.requiredHeight(for: blocks, width: width, style: style)
      view.frame = CGRect(x: 0, y: 0, width: width, height: height)
      view.configure(blocks: blocks, style: style)
    }
  }
#endif
