import Foundation
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif
@testable import OrbitDock
import Testing

struct DirectSessionComposerExecutionPlannerTests {
  @Test func sendPreparationPrependsShellContextAndResolvesSkills() {
    let availableSkills = [
      ServerSkillMetadata(
        name: "build",
        description: "Build the project",
        shortDescription: nil,
        path: "/skills/build",
        scope: .repo,
        enabled: true
      )
    ]
    let action = DirectSessionComposerExecutionPlanner.prepare(
      sendPlan: .send(content: "Use $build now", model: "claude-opus", effort: "high"),
      message: "Use $build now",
      attachments: DirectSessionComposerAttachmentState(),
      shellContext: "git status\nclean tree",
      selectedSkillPaths: [],
      availableSkills: availableSkills
    )

    guard case let .send(request) = action else {
      Issue.record("Expected send action, got \(action)")
      return
    }

    #expect(request.content == "git status\nclean tree\n\nUse $build now")
    #expect(request.model == "claude-opus")
    #expect(request.effort == "high")
    #expect(request.skills.map(\.name) == ["build"])
    #expect(request.skills.map(\.path) == ["/skills/build"])
    #expect(request.mentions.isEmpty)
    #expect(request.localImages.isEmpty)
  }

  @Test func steerPreparationPreservesMentionsAndImagesWithoutShellContext() {
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
      mentions: [AttachedMention(id: "file-1", name: "Widget.swift", path: "/tmp/repo/Widget.swift")]
    )

    let action = DirectSessionComposerExecutionPlanner.prepare(
      sendPlan: .steer(content: "Review @Widget.swift"),
      message: "Review @Widget.swift",
      attachments: attachments,
      shellContext: "git status",
      selectedSkillPaths: [],
      availableSkills: []
    )

    guard case let .steer(request) = action else {
      Issue.record("Expected steer action, got \(action)")
      return
    }

    #expect(request.content == "Review /tmp/repo/Widget.swift")
    #expect(request.mentions.count == 1)
    #expect(request.mentions.first?.name == "Widget.swift")
    #expect(request.mentions.first?.path == "/tmp/repo/Widget.swift")
    #expect(request.localImages.map(\.id) == [image.id])
  }

  private func makePlatformImage() -> PlatformImage {
    #if os(macOS)
      NSImage(size: NSSize(width: 1, height: 1))
    #else
      UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    #endif
  }
}
