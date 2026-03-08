//
//  ActivityStreamContent.swift
//  OrbitDock
//
//  Zone-based activity stream: sessions are visually grouped by urgency.
//  Attention → Working → Ready/Idle → History
//  Each zone uses a distinct card variant for instant visual differentiation.
//

import SwiftUI

struct ActivityStreamContent: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let sessions: [Session]
  let filter: ActiveSessionWorkbenchFilter
  let sort: ActiveSessionSort
  let providerFilter: ActiveSessionProviderFilter
  var projectFilter: String?
  var selectedIndex: Int = 0

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var stream: ActivityStream {
    ActivityStream.build(
      from: sessions,
      filter: filter,
      sort: sort,
      providerFilter: providerFilter,
      projectFilter: projectFilter
    )
  }

  /// Flat ordered list for keyboard navigation
  var navigableSessions: [Session] {
    stream.attention + stream.working + stream.ready
  }

  var body: some View {
    if stream.attention.isEmpty, stream.working.isEmpty, stream.ready.isEmpty {
      emptyState
    } else {
      streamContent
    }
  }

  // MARK: - Stream Content

  private var streamContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Zone 1: Attention — large colored cards
      if !stream.attention.isEmpty {
        attentionZone
      }

      // Zone 2: Working — medium cards, grid on desktop
      if !stream.working.isEmpty {
        workingZone
      }

      // Zone 3: Ready — compact rows
      if !stream.ready.isEmpty {
        readyZone
      }

      // History lives in Library view
    }
  }

  // MARK: - Attention Zone

  private var attentionZone: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      zoneHeader(
        icon: "exclamationmark.circle.fill",
        title: "Needs Attention",
        count: stream.attention.count,
        color: .statusPermission
      )

      ForEach(stream.attention, id: \.scopedID) { session in
        AttentionCard(session: session, onSelect: { selectSession(session) })
          .id(DashboardScrollIDs.session(session.scopedID))
      }
    }
    .padding(.bottom, Spacing.xl)
  }

  // MARK: - Working Zone

  private var workingZone: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      zoneHeader(
        icon: "bolt.fill",
        title: "Working",
        count: stream.working.count,
        color: .statusWorking
      )

      if layoutMode == .desktop, stream.working.count > 1 {
        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: Spacing.md),
            GridItem(.flexible(), spacing: Spacing.md),
          ],
          spacing: Spacing.md
        ) {
          ForEach(stream.working, id: \.scopedID) { session in
            WorkingCard(session: session, onSelect: { selectSession(session) })
              .id(DashboardScrollIDs.session(session.scopedID))
          }
        }
      } else {
        ForEach(stream.working, id: \.scopedID) { session in
          WorkingCard(session: session, onSelect: { selectSession(session) })
            .id(DashboardScrollIDs.session(session.scopedID))
        }
      }
    }
    .padding(.bottom, Spacing.xl)
  }

  // MARK: - Ready Zone

  private var readyZone: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      zoneHeader(
        icon: "bubble.left.fill",
        title: "Ready",
        count: stream.ready.count,
        color: .statusReply
      )

      ForEach(Array(stream.ready.enumerated()), id: \.element.scopedID) { index, session in
        let globalIndex = stream.attention.count + stream.working.count + index
        CompactSessionRow(
          session: session,
          onSelect: { selectSession(session) },
          isSelected: selectedIndex == globalIndex
        )
        .id(DashboardScrollIDs.session(session.scopedID))
      }
    }
    .padding(.bottom, Spacing.lg)
  }

  // MARK: - Zone Header

  private func zoneHeader(icon: String, title: String, count: Int, color: Color) -> some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(color)

      Text(title.uppercased())
        .font(.system(size: TypeScale.micro, weight: .heavy))
        .foregroundStyle(color)
        .tracking(0.8)

      Text("\(count)")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .foregroundStyle(color.opacity(0.7))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(OpacityTier.tint), in: Capsule())

      Spacer()
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.bottom, Spacing.sm)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(Color.textQuaternary)

      Text("No active sessions")
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Text("Start a new Claude or Codex session to get going")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textQuaternary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
  }

  // MARK: - Navigation

  private func selectSession(_ session: Session) {
    withAnimation(Motion.standard) {
      router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
    }
  }
}
