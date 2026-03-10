import CoreGraphics
import Foundation

enum ConversationImageLayout {
  static let maxWidth: CGFloat = 400
  static let maxHeight: CGFloat = 300
  static let cornerRadius: CGFloat = 10
  static let spacing: CGFloat = 8
  static let thumbnailSize: CGFloat = 150
  static let headerHeight: CGFloat = 32
  static let dimensionLabelHeight: CGFloat = 16
  static let dimensionSpacing: CGFloat = 6

  static func displayMetrics(
    for image: MessageImage,
    availableWidth: CGFloat,
    displaySize: CGSize?
  ) -> (width: CGFloat, height: CGFloat) {
    let aspect: CGFloat
    if let displaySize, displaySize.height > 0 {
      aspect = displaySize.width / displaySize.height
    } else if let width = image.pixelWidth, let height = image.pixelHeight, height > 0 {
      aspect = CGFloat(width) / CGFloat(height)
    } else {
      aspect = 4.0 / 3.0
    }

    let displayWidth = min(maxWidth, availableWidth)
    let displayHeight = min(maxHeight, displayWidth / max(aspect, 0.1))
    let finalWidth = min(displayWidth, displayHeight * aspect)
    return (finalWidth, displayHeight)
  }

  static func formattedByteCount(_ bytes: Int) -> String {
    if bytes < 1_024 {
      "\(bytes) B"
    } else if bytes < 1_024 * 1_024 {
      String(format: "%.1f KB", Double(bytes) / 1_024)
    } else {
      String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
  }

  static func blockHeight(
    for images: [MessageImage],
    availableWidth: CGFloat,
    displaySizeProvider: (MessageImage) -> CGSize?
  ) -> CGFloat {
    guard !images.isEmpty else { return 0 }

    let headerTotal = spacing + headerHeight + spacing

    if images.count == 1 {
      let image = images[0]
      let metrics = displayMetrics(
        for: image,
        availableWidth: availableWidth,
        displaySize: displaySizeProvider(image)
      )
      return headerTotal + metrics.height + dimensionSpacing + dimensionLabelHeight
    } else {
      let cols = max(1, Int((availableWidth + spacing) / (thumbnailSize + spacing)))
      let rows = (images.count + cols - 1) / cols
      let gridHeight = CGFloat(rows) * thumbnailSize + CGFloat(max(0, rows - 1)) * spacing
      return headerTotal + gridHeight
    }
  }
}
