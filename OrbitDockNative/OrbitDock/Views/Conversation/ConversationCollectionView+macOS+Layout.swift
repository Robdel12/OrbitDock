#if os(macOS)

  import AppKit

  extension ConversationCollectionViewController {
    func requestPinnedScroll() {
      guard isPinnedToBottom else { return }
      guard !pendingPinnedScroll else { return }
      pendingPinnedScroll = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.scrollToBottom(animated: false)
        self.pendingPinnedScroll = false
      }
    }

    func scrollToBottom(animated: Bool) {
      guard tableView.numberOfRows > 0 else { return }
      let targetY = max(0, tableView.bounds.height - scrollView.contentView.bounds.height)

      programmaticScrollInProgress = true
      if animated {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.18
          self.scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
        } completionHandler: { [weak self] in
          guard let self else { return }
          self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
          self.programmaticScrollInProgress = false
        }
      } else {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        programmaticScrollInProgress = false
      }
    }
  }

#endif
