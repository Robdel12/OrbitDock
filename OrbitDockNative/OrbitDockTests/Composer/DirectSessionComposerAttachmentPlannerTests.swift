import Foundation
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif
@testable import OrbitDock
import Testing

struct DirectSessionComposerAttachmentPlannerTests {
  @Test func buildMentionPrefersProjectAbsolutePath() {
    let file = ProjectFileIndex.ProjectFile(
      id: "file-1",
      name: "Widget.swift",
      relativePath: "Sources/Widget.swift"
    )

    let mention = DirectSessionComposerAttachmentPlanner.buildMention(
      file: file,
      projectPath: "/tmp/repo"
    )

    #expect(mention.name == "Widget.swift")
    #expect(mention.path == "/tmp/repo/Sources/Widget.swift")
  }

  @Test func resolveForSendExpandsMentionsAndPreservesImages() {
    let image = AttachedImage(
      id: "img-1",
      thumbnail: makePlatformImage(),
      uploadData: Data([1, 2, 3]),
      uploadMimeType: "image/png",
      displayName: "mock.png",
      pixelWidth: 16,
      pixelHeight: 16
    )
    let attachments = DirectSessionComposerAttachmentState(
      images: [image],
      mentions: [
        AttachedMention(id: "file-1", name: "Widget.swift", path: "/tmp/repo/Sources/Widget.swift")
      ]
    )

    let resolved = DirectSessionComposerAttachmentPlanner.resolveForSend(
      message: "Read @Widget.swift first",
      attachments: attachments
    )

    #expect(resolved.expandedContent == "Read /tmp/repo/Sources/Widget.swift first")
    #expect(resolved.mentionInputs.count == 1)
    #expect(resolved.mentionInputs.first?.name == "Widget.swift")
    #expect(resolved.mentionInputs.first?.path == "/tmp/repo/Sources/Widget.swift")
    #expect(resolved.images.map(\.id) == [image.id])
  }

  @Test func attachmentStateDeduplicatesMentionsAndResetsAfterSend() {
    var state = DirectSessionComposerAttachmentState()
    let mention = AttachedMention(id: "file-1", name: "Widget.swift", path: "/tmp/repo/Sources/Widget.swift")

    let firstAppend = state.appendMention(mention)
    let secondAppend = state.appendMention(mention)

    #expect(firstAppend)
    #expect(secondAppend == false)
    #expect(state.hasAttachments)

    state.clearAfterSend()

    #expect(state.images.isEmpty)
    #expect(state.mentions.isEmpty)
    #expect(state.hasAttachments == false)
  }

  private func makePlatformImage() -> PlatformImage {
    #if os(macOS)
      NSImage(size: NSSize(width: 1, height: 1))
    #else
      UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    #endif
  }
}
