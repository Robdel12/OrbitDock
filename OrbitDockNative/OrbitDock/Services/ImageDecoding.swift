import CoreGraphics
import Foundation
import ImageIO
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

enum ImageDecoding {
  static func downsampledImage(fromFile path: String, maxDimension: CGFloat) -> PlatformImage? {
    guard maxDimension > 0 else { return nil }
    let url = URL(fileURLWithPath: path)
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
    return downsampledImage(fromSource: source, maxDimension: maxDimension)
  }

  static func downsampledImage(fromData data: Data, maxDimension: CGFloat) -> PlatformImage? {
    guard maxDimension > 0, !data.isEmpty else { return nil }
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
    return downsampledImage(fromSource: source, maxDimension: maxDimension)
  }

  private static func downsampledImage(fromSource source: CGImageSource, maxDimension: CGFloat) -> PlatformImage? {
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension.rounded(.up)),
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
      return nil
    }

    #if os(macOS)
      return NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
      )
    #else
      return UIImage(cgImage: cgImage)
    #endif
  }
}
