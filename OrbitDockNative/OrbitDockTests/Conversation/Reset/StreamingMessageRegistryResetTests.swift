import Foundation
@testable import OrbitDock
import Testing

@Suite("StreamingMessageRegistry")
@MainActor
struct StreamingMessageRegistryResetTests {
  @Test func streamingRegistryCoalescesAndFinalizesMessage() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-1")
    var registry = StreamingMessageRegistry(session: session)

    registry.apply(.begin(messageID: "assistant-1", content: "Hel"))
    registry.apply(.append(messageID: "assistant-1", content: "lo", invalidatesHeight: false))

    let firstDrain = registry.drainPendingPatches()
    #expect(firstDrain.count == 1)
    #expect(firstDrain.first?.content == "Hello")
    #expect(firstDrain.first?.isFinal == false)

    registry.apply(.finalize(messageID: "assistant-1", content: "Hello world", invalidatesHeight: true))
    let finalDrain = registry.drainPendingPatches()

    #expect(finalDrain.count == 1)
    #expect(finalDrain.first?.content == "Hello world")
    #expect(finalDrain.first?.isFinal == true)
    #expect(registry.messagesByID["assistant-1"]?.isFinal == true)
  }

  @Test func removingStreamDropsPendingPatchAndHotState() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-2")
    var registry = StreamingMessageRegistry(session: session)

    registry.apply(.begin(messageID: "assistant-2", content: "Draft"))
    _ = registry.drainPendingPatches()

    registry.apply(.append(messageID: "assistant-2", content: " reply", invalidatesHeight: true))
    registry.apply(.remove(messageID: "assistant-2"))

    #expect(registry.drainPendingPatches().isEmpty)
    #expect(registry.messagesByID["assistant-2"] == nil)
  }
}
