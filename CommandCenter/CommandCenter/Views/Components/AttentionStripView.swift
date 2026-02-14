//
//  AttentionStripView.swift
//  OrbitDock
//
//  Compact horizontal strip showing cross-session urgency.
//

import SwiftUI

struct AttentionStripView: View {
  let events: [AttentionEvent]
  let currentSessionId: String?
  var onNavigateToSession: ((String) -> Void)? = nil

  /// Events excluding the currently viewed session
  private var crossSessionEvents: [AttentionEvent] {
    events.filter { $0.sessionId != currentSessionId }
  }

  private var permissionCount: Int {
    crossSessionEvents.filter { $0.type == .permissionRequired }.count
  }

  private var questionCount: Int {
    crossSessionEvents.filter { $0.type == .questionWaiting }.count
  }

  private var diffCount: Int {
    crossSessionEvents.filter { $0.type == .unreviewedDiff }.count
  }

  var body: some View {
    if !crossSessionEvents.isEmpty {
      HStack(spacing: 12) {
        if permissionCount > 0 {
          eventBadge(
            count: permissionCount,
            label: "permission",
            color: .statusPermission,
            type: .permissionRequired
          )
        }

        if questionCount > 0 {
          eventBadge(
            count: questionCount,
            label: "question",
            color: .statusQuestion,
            type: .questionWaiting
          )
        }

        if diffCount > 0 {
          eventBadge(
            count: diffCount,
            label: "unreviewed",
            color: .accent,
            type: .unreviewedDiff
          )
        }

        Spacer()
      }
      .padding(.horizontal, 12)
      .frame(height: 28)
      .background(Color.backgroundTertiary)
      .transition(.opacity.combined(with: .move(edge: .top)))
    }
  }

  @ViewBuilder
  private func eventBadge(count: Int, label: String, color: Color, type: AttentionEventType) -> some View {
    let firstEvent = crossSessionEvents.first { $0.type == type }

    Button {
      if let sessionId = firstEvent?.sessionId {
        onNavigateToSession?(sessionId)
      }
    } label: {
      HStack(spacing: 4) {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)

        Text("\(count)")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(color)

        Text(label)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  VStack(spacing: 0) {
    AttentionStripView(
      events: [
        AttentionEvent(id: "1", sessionId: "s1", type: .permissionRequired, timestamp: Date()),
        AttentionEvent(id: "2", sessionId: "s2", type: .permissionRequired, timestamp: Date()),
        AttentionEvent(id: "3", sessionId: "s3", type: .questionWaiting, timestamp: Date()),
        AttentionEvent(id: "4", sessionId: "s4", type: .unreviewedDiff, timestamp: Date()),
      ],
      currentSessionId: "other"
    )

    Divider()

    AttentionStripView(
      events: [],
      currentSessionId: "test"
    )
  }
  .frame(width: 400)
  .background(Color.backgroundSecondary)
}
