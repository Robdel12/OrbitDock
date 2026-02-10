//
//  QuestListView.swift
//  OrbitDock
//

import SwiftUI

struct QuestListView: View {
  let onSelectSession: (String) -> Void
  var initialQuestId: String?

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "scope")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(.tertiary)

      Text("Quests are temporarily unavailable")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)

      Text("Quest management is being migrated to the server control plane.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}

#Preview {
  QuestListView(onSelectSession: { _ in })
    .frame(width: 900, height: 600)
}
