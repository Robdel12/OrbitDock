//
//  FileTypeDistributionBar.swift
//  OrbitDock
//
//  Horizontal multi-segment bar showing file extension distribution,
//  color-coded by language. Used by Glob expanded view.
//

import SwiftUI

struct FileTypeDistributionBar: View {
  let files: [String]
  var maxWidth: CGFloat = 200

  /// Grouped extensions sorted by count descending.
  private var groups: [(ext: String, count: Int, color: Color)] {
    var counts: [String: Int] = [:]
    for file in files {
      let ext = file.components(separatedBy: ".").last?.lowercased() ?? "other"
      counts[ext, default: 0] += 1
    }
    return counts
      .sorted { $0.value > $1.value }
      .map { (ext: $0.key, count: $0.value, color: FileLanguageMapping.color(for: "file.\($0.key)")) }
  }

  private var total: Int {
    files.count
  }

  var body: some View {
    if total > 0 {
      let computed = groups
      VStack(alignment: .leading, spacing: Spacing.xs) {
        // Proportional bar
        GeometryReader { geo in
          let width = min(geo.size.width, maxWidth)
          HStack(spacing: 1) {
            ForEach(Array(computed.enumerated()), id: \.offset) { _, group in
              let segmentWidth = width * CGFloat(group.count) / CGFloat(total)
              RoundedRectangle(cornerRadius: Radius.xs)
                .fill(group.color)
                .frame(width: max(segmentWidth, 2))
            }
          }
          .frame(width: width, alignment: .leading)
        }
        .frame(maxWidth: maxWidth)
        .frame(height: 4)

        // Legend
        HStack(spacing: Spacing.sm_) {
          ForEach(Array(computed.enumerated()), id: \.offset) { index, group in
            if index > 0 {
              Text("\u{00B7}")
                .font(.system(size: TypeScale.mini))
                .foregroundStyle(Color.textQuaternary)
            }
            Text("\(group.count) .\(group.ext)")
              .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
              .foregroundStyle(group.color)
          }
        }
      }
    }
  }
}
