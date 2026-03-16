//
//  DiffChangeStrip.swift
//  OrbitDock
//
//  Thin vertical annotation strip showing where additions and deletions
//  occur in a diff, like VSCode's scrollbar annotations.
//  Rendered as colored marks at proportional positions within the strip.
//

import SwiftUI

struct DiffChangeStrip: View {
  let lines: [String]
  var height: CGFloat = 350

  var body: some View {
    Canvas { context, size in
      let total = lines.count
      guard total > 0 else { return }

      let stripWidth = size.width
      let stripHeight = size.height

      for (index, line) in lines.enumerated() {
        let color: Color?
        if line.hasPrefix("+") {
          color = .diffAddedEdge
        } else if line.hasPrefix("-") {
          color = .diffRemovedEdge
        } else {
          color = nil
        }

        guard let markColor = color else { continue }

        let y = (CGFloat(index) / CGFloat(total)) * stripHeight
        let markHeight = max(1.5, stripHeight / CGFloat(total))

        let rect = CGRect(x: 0, y: y, width: stripWidth, height: markHeight)
        context.fill(Path(rect), with: .color(markColor.opacity(0.7)))
      }
    }
    .frame(width: 3, height: height)
    .clipShape(RoundedRectangle(cornerRadius: 1))
  }
}
