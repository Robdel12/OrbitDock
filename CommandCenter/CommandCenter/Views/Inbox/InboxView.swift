//
//  InboxView.swift
//  OrbitDock
//

import SwiftUI

struct InboxView: View {
  var onClose: (() -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "tray.and.arrow.down")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(.tertiary)

      Text("Inbox is temporarily unavailable")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)

      Text("Inbox capture is being migrated to the server control plane.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if let onClose {
        Button("Close") {
          onClose()
        }
        .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}

#Preview {
  InboxView(onClose: {})
    .frame(width: 500, height: 600)
}
