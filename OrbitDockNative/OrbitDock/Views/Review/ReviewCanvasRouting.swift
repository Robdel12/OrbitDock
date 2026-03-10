import SwiftUI

enum ReviewCanvasRoutingPlanner {
  static func fileIndex(
    for requestedFileId: String,
    in model: DiffModel
  ) -> Int? {
    model.files.firstIndex(where: {
      $0.id == requestedFileId
        || $0.newPath == requestedFileId
        || $0.newPath.hasSuffix(requestedFileId)
        || requestedFileId.hasSuffix($0.newPath)
    })
  }

  static func selectedFileId(
    for target: ReviewCursorTarget?,
    in model: DiffModel
  ) -> String? {
    guard let target else { return nil }
    let fileIndex = target.fileIndex
    guard model.files.indices.contains(fileIndex) else { return nil }
    return model.files[fileIndex].id
  }
}

extension ReviewCanvas {
  func handlePendingNavigation() {
    guard let fileId = navigateToFileId?.wrappedValue, !fileId.isEmpty else { return }
    if let model = diffModel,
       let fileIndex = ReviewCanvasRoutingPlanner.fileIndex(for: fileId, in: model)
    {
      let targets = visibleTargets(model)
      if let targetIndex = targets.firstIndex(of: .fileHeader(fileIndex: fileIndex)) {
        cursorIndex = targetIndex
      }
    }
    navigateToFileId?.wrappedValue = nil
  }

  func fileListBinding(_ model: DiffModel) -> Binding<String?> {
    Binding<String?>(
      get: {
        ReviewCanvasRoutingPlanner.selectedFileId(
          for: currentTarget(model),
          in: model
        )
      },
      set: { newId in
        guard let id = newId,
              let fileIndex = ReviewCanvasRoutingPlanner.fileIndex(for: id, in: model)
        else { return }
        isFollowing = false
        let targets = visibleTargets(model)
        if let targetIndex = targets.firstIndex(of: .fileHeader(fileIndex: fileIndex)) {
          cursorIndex = targetIndex
        }
      }
    )
  }
}
