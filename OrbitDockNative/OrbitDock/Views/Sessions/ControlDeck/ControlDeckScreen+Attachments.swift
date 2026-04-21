import SwiftUI

extension ControlDeckScreen {
  var supportsImageClipboardPaste: Bool {
    PlatformAttachmentInput.supportsImageClipboardPaste
  }

  @discardableResult
  func pasteImageFromClipboard() -> Bool {
    guard let payload = PlatformAttachmentInput.pasteImageFromClipboard() else {
      return false
    }
    composer.appendDroppedImage(payload)
    return true
  }

  func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    PlatformAttachmentInput.handleDrop(providers) { payload in
      composer.appendDroppedImage(payload)
    }
  }
}
