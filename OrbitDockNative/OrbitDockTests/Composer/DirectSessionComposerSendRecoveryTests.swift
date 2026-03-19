import Foundation
@testable import OrbitDock
import Testing

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
    let userEntry = ServerConversationRowEntry(
      sessionId: "s1",
      sequence: 1,
      turnId: nil,
      row: .user(ServerConversationMessageRow(
        id: "user-1",
        content: "Nice, that still shows pending though. Which is interesting.",
        turnId: nil,
        timestamp: nil,
        isStreaming: false,
        images: nil
      ))
    )

    let shouldRecover = DirectSessionComposerSendRecovery.shouldRecover(
      pendingContent: "  Nice, that still shows pending though. Which is interesting.  ",
      pendingStartedAt: sentAt,
      latestUserEntry: userEntry
    )

    #expect(shouldRecover)
  }

  @Test func ignoresMismatchedUserMessages() {
    let sentAt = Date(timeIntervalSince1970: 1_000)
    let mismatchedEntry = ServerConversationRowEntry(
      sessionId: "s1",
      sequence: 2,
      turnId: nil,
      row: .user(ServerConversationMessageRow(
        id: "user-2",
        content: "Different content",
        turnId: nil,
        timestamp: nil,
        isStreaming: false,
        images: nil
      ))
    )

    #expect(
      !DirectSessionComposerSendRecovery.shouldRecover(
        pendingContent: "Same content",
        pendingStartedAt: sentAt,
        latestUserEntry: mismatchedEntry
      )
    )
  }
}
