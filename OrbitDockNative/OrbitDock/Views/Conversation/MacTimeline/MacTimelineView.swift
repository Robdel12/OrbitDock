import SwiftUI

#if os(macOS)
  struct MacTimelineView: NSViewControllerRepresentable {
    let viewState: MacTimelineViewState
    let onLoadMore: (() -> Void)?
    let onToggleToolExpansion: ((String) -> Void)?
    let onToggleActivityExpansion: ((String) -> Void)?
    let onFocusWorker: ((String) -> Void)?

    func makeNSViewController(context: Context) -> MacTimelineHostViewController {
      let controller = MacTimelineHostViewController()
      controller.onLoadMore = onLoadMore
      controller.onToggleToolExpansion = onToggleToolExpansion
      controller.onToggleActivityExpansion = onToggleActivityExpansion
      controller.onFocusWorker = onFocusWorker
      controller.apply(viewState: viewState)
      return controller
    }

    func updateNSViewController(_ controller: MacTimelineHostViewController, context: Context) {
      controller.onLoadMore = onLoadMore
      controller.onToggleToolExpansion = onToggleToolExpansion
      controller.onToggleActivityExpansion = onToggleActivityExpansion
      controller.onFocusWorker = onFocusWorker
      controller.apply(viewState: viewState)
    }
  }
#endif
