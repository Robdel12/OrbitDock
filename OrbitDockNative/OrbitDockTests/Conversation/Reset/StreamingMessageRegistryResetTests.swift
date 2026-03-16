@testable import OrbitDock
import XCTest

final class StreamingMessageRegistryResetTests: XCTestCase {
  func testStreamingRegistryCoalescesAndFinalizesMessage() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-1")
    var registry = StreamingMessageRegistry(session: session)

    registry.apply(.begin(messageID: "assistant-1", content: "Hel"))
    registry.apply(.append(messageID: "assistant-1", content: "lo", invalidatesHeight: false))

    let firstDrain = registry.drainPendingPatches()
    XCTAssertEqual(firstDrain.count, 1)
    XCTAssertEqual(firstDrain.first?.content, "Hello")
    XCTAssertFalse(firstDrain.first?.isFinal ?? true)

    registry.apply(.finalize(messageID: "assistant-1", content: "Hello world", invalidatesHeight: true))
    let finalDrain = registry.drainPendingPatches()

    XCTAssertEqual(finalDrain.count, 1)
    XCTAssertEqual(finalDrain.first?.content, "Hello world")
    XCTAssertTrue(finalDrain.first?.isFinal ?? false)
    XCTAssertTrue(registry.messagesByID["assistant-1"]?.isFinal ?? false)
  }

  func testRemovingStreamDropsPendingPatchAndHotState() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-2")
    var registry = StreamingMessageRegistry(session: session)

    registry.apply(.begin(messageID: "assistant-2", content: "Draft"))
    _ = registry.drainPendingPatches()

    registry.apply(.append(messageID: "assistant-2", content: " reply", invalidatesHeight: true))
    registry.apply(.remove(messageID: "assistant-2"))

    XCTAssertTrue(registry.drainPendingPatches().isEmpty)
    XCTAssertNil(registry.messagesByID["assistant-2"])
  }
}
