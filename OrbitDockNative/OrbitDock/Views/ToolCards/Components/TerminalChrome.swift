//
//  TerminalChrome.swift
//  OrbitDock
//
//  Decorative terminal window header with traffic light dots and path display.
//  Used by BashExpandedView for a native terminal feel.
//

import SwiftUI

struct TerminalChrome: View {
  let path: String?

  var body: some View {
    HStack(spacing: 0) {
      // Traffic light dots (decorative)
      HStack(spacing: Spacing.sm_) {
        Circle().fill(Color(red: 1.0, green: 0.38, blue: 0.35)).frame(width: 8, height: 8)
        Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.2)).frame(width: 8, height: 8)
        Circle().fill(Color(red: 0.3, green: 0.8, blue: 0.35)).frame(width: 8, height: 8)
      }

      Spacer()

      if let path, !path.isEmpty {
        Text(path)
          .font(.system(size: TypeScale.meta, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
      }

      Spacer()

      // Balance the traffic lights
      HStack(spacing: Spacing.sm_) {
        Circle().fill(Color.clear).frame(width: 8, height: 8)
        Circle().fill(Color.clear).frame(width: 8, height: 8)
        Circle().fill(Color.clear).frame(width: 8, height: 8)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundCode.opacity(0.6))
  }
}
