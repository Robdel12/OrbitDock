//
//  MarkdownRepresentable.swift
//  OrbitDock
//
//  NSViewRepresentable / UIViewRepresentable wrapper around NativeMarkdownContentView.
//  Use this for any SwiftUI surface that needs to render markdown content.
//  All rendering goes through the single native path — no SwiftUI text bridging.
//

import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct MarkdownRepresentable: Equatable {
  let content: String
  var style: ContentStyle = .standard

}

#if os(macOS)
  extension MarkdownRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeMarkdownContentView {
      let view = NativeMarkdownContentView(frame: .zero)
      let blocks = MarkdownSystemParser.parse(content, style: style)
      view.configure(blocks: blocks, style: style)
      return view
    }

    func updateNSView(_ nsView: NativeMarkdownContentView, context: Context) {
      let blocks = MarkdownSystemParser.parse(content, style: style)
      nsView.configure(blocks: blocks, style: style)
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize,
      nsView: NativeMarkdownContentView,
      context: Context
    ) -> CGSize? {
      let width = proposal.width ?? 300
      let blocks = MarkdownSystemParser.parse(content, style: style)
      let height = NativeMarkdownContentView.requiredHeight(for: blocks, width: width, style: style)
      return CGSize(width: width, height: height)
    }
  }
#else
  extension MarkdownRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> NativeMarkdownContentView {
      let view = NativeMarkdownContentView(frame: .zero)
      let blocks = MarkdownSystemParser.parse(content, style: style)
      view.configure(blocks: blocks, style: style)
      return view
    }

    func updateUIView(_ uiView: NativeMarkdownContentView, context: Context) {
      let blocks = MarkdownSystemParser.parse(content, style: style)
      uiView.configure(blocks: blocks, style: style)
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize,
      uiView: NativeMarkdownContentView,
      context: Context
    ) -> CGSize? {
      let width = proposal.width ?? 300
      let blocks = MarkdownSystemParser.parse(content, style: style)
      let height = NativeMarkdownContentView.requiredHeight(for: blocks, width: width, style: style)
      return CGSize(width: width, height: height)
    }
  }
#endif
