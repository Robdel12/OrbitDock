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

  /// Incremented when a code block expands/collapses inside the native view,
  /// forcing SwiftUI to recreate the bridge and re-measure height.
  @State private var codeBlockRevision = 0

  private var blocks: [MarkdownBlock] {
    MarkdownSystemParser.parse(content, style: style)
  }

  private var measuredHeight: CGFloat {
    NativeMarkdownContentView.requiredHeight(for: blocks, width: availableWidth, style: style)
  }

  var body: some View {
    MarkdownBridge(content: content, style: style, width: availableWidth, onCodeBlockToggle: {
      codeBlockRevision += 1
    })
    .id(codeBlockRevision)
    .frame(height: max(1, measuredHeight))
  }
}

#if os(macOS)
  private struct MarkdownBridge: NSViewRepresentable {
    let content: String
    let style: ContentStyle
    let width: CGFloat
    var onCodeBlockToggle: (() -> Void)?

    func makeNSView(context: Context) -> NativeMarkdownContentView {
      let view = NativeMarkdownContentView(frame: .zero)
      view.onCodeBlockToggle = onCodeBlockToggle
      return view
    }

    func updateNSView(_ view: NativeMarkdownContentView, context: Context) {
      view.onCodeBlockToggle = onCodeBlockToggle
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
    var onCodeBlockToggle: (() -> Void)?

    func makeUIView(context: Context) -> NativeMarkdownContentView {
      let view = NativeMarkdownContentView(frame: .zero)
      view.onCodeBlockToggle = onCodeBlockToggle
      return view
    }

    func updateUIView(_ view: NativeMarkdownContentView, context: Context) {
      view.onCodeBlockToggle = onCodeBlockToggle
      let blocks = MarkdownSystemParser.parse(content, style: style)
      let height = NativeMarkdownContentView.requiredHeight(for: blocks, width: width, style: style)
      view.frame = CGRect(x: 0, y: 0, width: width, height: height)
      view.configure(blocks: blocks, style: style)
    }
  }
#endif
