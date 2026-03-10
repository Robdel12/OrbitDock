import CoreGraphics
import Foundation

struct ConversationRichMessageMeasurement {
  let bodyHeight: CGFloat
  let totalHeight: CGFloat
}

enum ConversationRichMessageSupport {
  static func imageMetadata(
    for image: MessageImage,
    originalWidth: Int?,
    originalHeight: Int?
  ) -> String {
    let width = originalWidth ?? image.pixelWidth
    let height = originalHeight ?? image.pixelHeight
    guard let width, let height, width > 0, height > 0 else {
      return ConversationImageLayout.formattedByteCount(image.byteCount)
    }
    return "\(width) \u{00D7} \(height)  \u{00B7}  \(ConversationImageLayout.formattedByteCount(image.byteCount))"
  }

  static func imageBlockHeight(
    for images: [MessageImage],
    availableWidth: CGFloat,
    displaySizeProvider: (MessageImage) -> CGSize?
  ) -> CGFloat {
    ConversationImageLayout.blockHeight(for: images, availableWidth: availableWidth) { image in
      displaySizeProvider(image)
    }
  }

  static func measureHeight(
    for width: CGFloat,
    model: NativeRichMessageRowModel,
    blocks: [MarkdownBlock],
    imageHeightProvider: (CGFloat) -> CGFloat
  ) -> ConversationRichMessageMeasurement {
    let bodyHeight = ConversationRichMessageLayout.bodyHeight(
      for: width,
      model: model,
      blocks: blocks,
      imageHeightProvider: imageHeightProvider
    )
    let totalHeight = ConversationRichMessageLayout.requiredHeight(
      for: width,
      model: model,
      blocks: blocks,
      imageHeightProvider: imageHeightProvider
    )
    return ConversationRichMessageMeasurement(
      bodyHeight: bodyHeight,
      totalHeight: totalHeight
    )
  }
}
