//
//  MarkdownContentView.swift
//  OrbitDock
//
//  Drop-in SwiftUI replacement for MarkdownContentRepresentable.
//  No availableWidth, no height measurement, no NSViewRepresentable.
//

import SwiftUI

struct MarkdownContentView: View {
  let content: String
  let style: ContentStyle

  var body: some View {
    let blocks = MarkdownSystemParser.parse(content, style: style)
    if !blocks.isEmpty {
      MarkdownBlockView(blocks: blocks, style: style)
    }
  }
}
