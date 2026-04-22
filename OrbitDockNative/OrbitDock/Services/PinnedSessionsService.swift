import Foundation
import Observation

/// Manages pinned sessions stored in UserDefaults.
/// Pinned sessions appear at the top of the sidebar in a stable section.
@MainActor
@Observable
final class PinnedSessionsService {
  private static let storageKey = "dashboard.pinnedSessions"

  /// Ordered list of pinned session refs (most recently pinned last).
  private(set) var pinnedRefs: [SessionRef] = []

  /// Fast lookup for pin status.
  private var pinnedSet: Set<SessionRef> = []

  init() {
    load()
  }

  // MARK: - Public API

  func isPinned(_ ref: SessionRef) -> Bool {
    pinnedSet.contains(ref)
  }

  func pin(_ ref: SessionRef) {
    guard !pinnedSet.contains(ref) else { return }
    pinnedRefs.append(ref)
    pinnedSet.insert(ref)
    save()
  }

  func unpin(_ ref: SessionRef) {
    guard pinnedSet.contains(ref) else { return }
    pinnedRefs.removeAll { $0 == ref }
    pinnedSet.remove(ref)
    save()
  }

  func toggle(_ ref: SessionRef) {
    if isPinned(ref) {
      unpin(ref)
    } else {
      pin(ref)
    }
  }

  // MARK: - Persistence

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
          let refs = try? JSONDecoder().decode([SessionRef].self, from: data)
    else { return }
    pinnedRefs = refs
    pinnedSet = Set(refs)
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(pinnedRefs) else { return }
    UserDefaults.standard.set(data, forKey: Self.storageKey)
  }
}
