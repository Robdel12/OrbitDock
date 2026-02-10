//
//  QuestDetailView.swift
//  OrbitDock
//

import SwiftUI

struct QuestDetailView: View {
  let questId: String
  let onClose: () -> Void
  let onSelectSession: (String) -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "scope")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(.tertiary)

      Text("Quest detail is temporarily unavailable")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)

      Text("Quest management is being migrated to the server control plane.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Button("Close") {
        onClose()
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}

#Preview {
  QuestDetailView(questId: "preview", onClose: {}, onSelectSession: { _ in })
    .frame(width: 800, height: 600)
}
