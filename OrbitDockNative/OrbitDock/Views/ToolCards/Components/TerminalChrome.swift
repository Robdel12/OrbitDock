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
      #if os(macOS)
        // Traffic light dots (decorative, 6pt)
        HStack(spacing: Spacing.xs) {
          Circle().fill(Color(red: 1.0, green: 0.38, blue: 0.35)).frame(width: 6, height: 6)
          Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.2)).frame(width: 6, height: 6)
          Circle().fill(Color(red: 0.3, green: 0.8, blue: 0.35)).frame(width: 6, height: 6)
        }
      #endif

      Spacer()

      if let path, !path.isEmpty {
        Text(path)
          .font(.system(size: TypeScale.mini, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
      }

      Spacer()

      #if os(macOS)
        // Balance the traffic lights
        HStack(spacing: Spacing.xs) {
          Circle().fill(Color.clear).frame(width: 6, height: 6)
          Circle().fill(Color.clear).frame(width: 6, height: 6)
          Circle().fill(Color.clear).frame(width: 6, height: 6)
        }
      #endif
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
  }
}
