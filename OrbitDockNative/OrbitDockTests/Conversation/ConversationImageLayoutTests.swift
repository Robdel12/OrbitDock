import CoreGraphics
@testable import OrbitDock
import Testing

struct ConversationImageLayoutTests {
  @Test func displayMetricsUsePixelAspectWhenNoRenderedImageExists() {
    let image = MessageImage(
      id: "img-1",
      source: .serverAttachment(
        ServerAttachmentImageReference(endpointId: nil, sessionId: "session", attachmentId: "att-1")
      ),
      mimeType: "image/png",
      byteCount: 2_048,
      pixelWidth: 800,
      pixelHeight: 400
    )

    let metrics = ConversationImageLayout.displayMetrics(
      for: image,
      availableWidth: 320,
      displaySize: nil
    )

    #expect(metrics.width == 320)
    #expect(metrics.height == 160)
  }

  @Test func blockHeightUsesThumbnailGridForMultipleImages() {
    let images = [
      MessageImage(id: "1", source: .serverAttachment(ServerAttachmentImageReference(endpointId: nil, sessionId: "session", attachmentId: "att-1")), mimeType: "image/png", byteCount: 100, pixelWidth: 100, pixelHeight: 100),
      MessageImage(id: "2", source: .serverAttachment(ServerAttachmentImageReference(endpointId: nil, sessionId: "session", attachmentId: "att-2")), mimeType: "image/png", byteCount: 100, pixelWidth: 100, pixelHeight: 100),
      MessageImage(id: "3", source: .serverAttachment(ServerAttachmentImageReference(endpointId: nil, sessionId: "session", attachmentId: "att-3")), mimeType: "image/png", byteCount: 100, pixelWidth: 100, pixelHeight: 100),
    ]

    let height = ConversationImageLayout.blockHeight(for: images, availableWidth: 320) { _ in nil }

    let expectedHeader = ConversationImageLayout.spacing + ConversationImageLayout.headerHeight + ConversationImageLayout.spacing
    let expectedGrid = (ConversationImageLayout.thumbnailSize * 2) + ConversationImageLayout.spacing
    #expect(height == expectedHeader + expectedGrid)
  }
}
