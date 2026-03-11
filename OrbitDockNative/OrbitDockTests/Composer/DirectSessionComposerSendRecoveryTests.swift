import Foundation
import Testing
@testable import OrbitDock

struct DirectSessionComposerSendRecoveryTests {
  @Test func tracksOnlyNormalSendActions() {
    var state = DirectSessionComposerState()

    DirectSessionComposerSendRecovery.trackAttempt(
      in: &state,
      preparedAction: .steer(
        .init(
          content: "Keep going",
          mentions: [],
          localImages: []
        )
      )
    )

    #expect(state.pendingRecoveredSendContent == nil)
    #expect(state.pendingRecoveredSendStartedAt == nil)
  }

  @Test func recoversWhenMatchingUserMessageArrivesAfterFailedSend() {
    let sentAt = Date(timeIntervalSince1970: 1_000)
    let userMessage = TranscriptMessage(
      id: "user-1",
      type: .user,
      content: "Nice, that still shows pending though. Which is interesting.",
      timestamp: sentAt.addingTimeInterval(1)
    )

    let shouldRecover = DirectSessionComposerSendRecovery.shouldRecover(
      pendingContent: "  Nice, that still shows pending though. Which is interesting.  ",
      pendingStartedAt: sentAt,
      latestUserMessage: userMessage
    )

    #expect(shouldRecover)
  }

  @Test func ignoresOlderOrMismatchedUserMessages() {
    let sentAt = Date(timeIntervalSince1970: 1_000)
    let olderMessage = TranscriptMessage(
      id: "user-1",
      type: .user,
      content: "Same content",
      timestamp: sentAt.addingTimeInterval(-1)
    )
    let mismatchedMessage = TranscriptMessage(
      id: "user-2",
      type: .user,
      content: "Different content",
      timestamp: sentAt.addingTimeInterval(1)
    )

    #expect(
      !DirectSessionComposerSendRecovery.shouldRecover(
        pendingContent: "Same content",
        pendingStartedAt: sentAt,
        latestUserMessage: olderMessage
      )
    )
    #expect(
      !DirectSessionComposerSendRecovery.shouldRecover(
        pendingContent: "Same content",
        pendingStartedAt: sentAt,
        latestUserMessage: mismatchedMessage
      )
    )
  }
}
