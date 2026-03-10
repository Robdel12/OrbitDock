import Foundation

struct ReviewCanvasToolbarState: Equatable {
  struct HistoryState: Equatable {
    let isVisible: Bool
    let iconName: String
    let label: String
  }

  struct FollowState: Equatable {
    let isFollowing: Bool
    let label: String
  }

  let currentFileName: String?
  let totalAdditions: Int
  let totalDeletions: Int
  let history: HistoryState?
  let follow: FollowState?
}

enum ReviewCanvasToolbarPlanner {
  static func toolbarState(
    currentFilePath: String?,
    model: DiffModel,
    hasResolvedComments: Bool,
    showResolvedComments: Bool,
    isSessionActive: Bool,
    isFollowing: Bool
  ) -> ReviewCanvasToolbarState {
    ReviewCanvasToolbarState(
      currentFileName: currentFilePath.map { path in
        path.components(separatedBy: "/").last ?? path
      },
      totalAdditions: model.files.reduce(0) { $0 + $1.stats.additions },
      totalDeletions: model.files.reduce(0) { $0 + $1.stats.deletions },
      history: hasResolvedComments ? .init(
        isVisible: showResolvedComments,
        iconName: showResolvedComments ? "eye.fill" : "eye.slash",
        label: "History"
      ) : nil,
      follow: isSessionActive ? .init(
        isFollowing: isFollowing,
        label: isFollowing ? "Following" : "Paused"
      ) : nil
    )
  }
}
