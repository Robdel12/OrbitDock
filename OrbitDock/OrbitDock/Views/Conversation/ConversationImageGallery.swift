import ImageIO
import SwiftUI

// MARK: - Cached Image Entry

struct CachedImage {
  let displayImage: PlatformImage
  let originalWidth: Int
  let originalHeight: Int
}

// MARK: - Image Cache (ImageIO Downsampling)

/// Thread-safe cache for display-resolution images, keyed by MessageImage.id.
///
/// Uses ImageIO to decode images directly at display resolution — the full-resolution
/// bitmap is **never** loaded into memory. A 28MB Retina screenshot becomes a ~2MB
/// display-resolution thumbnail, eliminating scroll-time memory spikes.
final class ImageCache {
  static let shared = ImageCache()

  /// Max pixel dimension for cached display images.
  /// 800px covers 400pt single-image display at 2x Retina.
  private static let maxPixelSize = 1_200

  private var cache: [String: CachedImage] = [:]
  private let lock = NSLock()

  /// Returns the cached display image (downsampled) for scroll rendering.
  func image(for messageImage: MessageImage) -> PlatformImage? {
    cachedImage(for: messageImage)?.displayImage
  }

  /// Returns the full cache entry including original dimensions for labels.
  func cachedImage(for messageImage: MessageImage) -> CachedImage? {
    lock.lock()
    defer { lock.unlock() }

    if let cached = cache[messageImage.id] {
      return cached
    }

    guard let source = createImageSource(for: messageImage.source) else {
      return nil
    }

    // Read original dimensions from image header (no decode)
    let (origW, origH) = Self.originalDimensions(from: source)

    // Decode directly at display resolution — full bitmap never in memory
    let thumbOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
      source, 0, thumbOptions as CFDictionary
    ) else { return nil }

    #if os(macOS)
      let displayImage = NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
      )
    #else
      let displayImage = UIImage(cgImage: cgImage)
    #endif

    let entry = CachedImage(
      displayImage: displayImage,
      originalWidth: origW,
      originalHeight: origH
    )
    cache[messageImage.id] = entry
    return entry
  }

  // MARK: - Private

  private func createImageSource(for source: MessageImage.Source) -> CGImageSource? {
    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
    switch source {
      case let .filePath(path):
        let url = URL(fileURLWithPath: path) as CFURL
        return CGImageSourceCreateWithURL(url, opts)
      case let .dataURI(uri):
        guard let data = Self.decodeDataURI(uri) else { return nil }
        return CGImageSourceCreateWithData(data as CFData, opts)
    }
  }

  private static func originalDimensions(from source: CGImageSource) -> (Int, Int) {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return (0, 0) }
    return (w, h)
  }

  private static func decodeDataURI(_ uri: String) -> Data? {
    guard uri.hasPrefix("data:") else { return nil }
    let withoutScheme = String(uri.dropFirst(5))
    guard let commaIndex = withoutScheme.firstIndex(of: ",") else { return nil }
    let base64String = String(withoutScheme[withoutScheme.index(after: commaIndex)...])
    return Data(base64Encoded: base64String, options: .ignoreUnknownCharacters)
  }
}

// MARK: - Image Gallery (Multiple images with fullscreen + collapsible)

struct ImageGallery: View {
  let images: [MessageImage]
  @State private var selectedIndex: Int?
  @State private var isExpanded = true

  private var totalSize: String {
    let bytes = images.reduce(0) { $0 + $1.byteCount }
    if bytes < 1_024 {
      return "\(bytes) B"
    } else if bytes < 1_024 * 1_024 {
      return String(format: "%.1f KB", Double(bytes) / 1_024)
    } else {
      return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 11, weight: .semibold))
          Text(images.count == 1 ? "1 image" : "\(images.count) images")
            .font(.system(size: 12, weight: .medium))
          Text("•")
            .foregroundStyle(.quaternary)
          Text(totalSize)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.quaternary)

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.5))
        )
      }
      .buttonStyle(.plain)

      if isExpanded {
        if images.count == 1 {
          if let cached = ImageCache.shared.cachedImage(for: images[0]) {
            SingleImageView(
              platformImage: cached.displayImage,
              imageData: images[0],
              originalWidth: cached.originalWidth,
              originalHeight: cached.originalHeight
            ) {
              selectedIndex = 0
            }
          }
        } else {
          FlowLayout(spacing: 12) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
              if let img = ImageCache.shared.image(for: image) {
                ImageThumbnail(
                  platformImage: img,
                  imageData: image,
                  index: index
                ) {
                  selectedIndex = index
                }
              }
            }
          }
        }
      }
    }
    .sheet(item: Binding(
      get: { selectedIndex.map { ImageSelection(index: $0) } },
      set: { selectedIndex = $0?.index }
    )) { selection in
      ImageFullscreen(
        images: images,
        currentIndex: selection.index
      )
    }
  }
}

private struct ImageSelection: Identifiable {
  let index: Int

  var id: Int {
    index
  }
}

struct SingleImageView: View {
  let platformImage: PlatformImage
  let imageData: MessageImage
  let originalWidth: Int
  let originalHeight: Int
  let onTap: () -> Void

  @State private var isHovering = false

  private var imageDimensions: String {
    "\(originalWidth) \u{00D7} \(originalHeight)"
  }

  private var imageSize: String {
    let bytes = imageData.byteCount
    if bytes < 1_024 {
      return "\(bytes) B"
    } else if bytes < 1_024 * 1_024 {
      return String(format: "%.1f KB", Double(bytes) / 1_024)
    } else {
      return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
  }

  private var swiftUIImage: Image {
    #if os(macOS)
      Image(nsImage: platformImage)
    #else
      Image(uiImage: platformImage)
    #endif
  }

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .trailing, spacing: 6) {
        swiftUIImage
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: 400, maxHeight: 300)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(Color.white.opacity(isHovering ? 0.25 : 0.1), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
          .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.white)
              .padding(6)
              .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
              .padding(8)
              .opacity(isHovering ? 1 : 0)
          }

        HStack(spacing: 8) {
          Text(imageDimensions)
          Text("•")
          Text(imageSize)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.quaternary)
      }
      .scaleEffect(isHovering ? 1.01 : 1.0)
      .animation(.easeOut(duration: 0.15), value: isHovering)
    }
    .buttonStyle(.plain)
    #if os(macOS)
      .onHover { isHovering = $0 }
    #endif
  }
}

struct ImageThumbnail: View {
  let platformImage: PlatformImage
  let imageData: MessageImage
  let index: Int
  let onTap: () -> Void

  @State private var isHovering = false

  private var swiftUIImage: Image {
    #if os(macOS)
      Image(nsImage: platformImage)
    #else
      Image(uiImage: platformImage)
    #endif
  }

  var body: some View {
    Button(action: onTap) {
      ZStack(alignment: .topTrailing) {
        swiftUIImage
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 200, height: 150)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(Color.white.opacity(isHovering ? 0.3 : 0.12), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)

        Text("\(index + 1)")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .frame(width: 22, height: 22)
          .background(Color.accent.opacity(0.9), in: Circle())
          .padding(8)

        if isHovering {
          VStack {
            Spacer()
            HStack {
              Spacer()
              Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(6)
            }
          }
        }
      }
      .scaleEffect(isHovering ? 1.03 : 1.0)
      .animation(.easeOut(duration: 0.15), value: isHovering)
    }
    .buttonStyle(.plain)
    #if os(macOS)
      .onHover { isHovering = $0 }
    #endif
  }
}

struct ImageFullscreen: View {
  let images: [MessageImage]
  @State var currentIndex: Int
  /// AppKit dismiss closure — used when hosted via NSHostingController.presentAsSheet.
  var onDismiss: (() -> Void)?
  @Environment(\.dismiss) private var dismiss

  private var currentImage: MessageImage {
    images[currentIndex]
  }

  private var cachedEntry: CachedImage? {
    ImageCache.shared.cachedImage(for: currentImage)
  }

  private var displayImage: PlatformImage? {
    cachedEntry?.displayImage
  }

  private var imageDimensions: String {
    guard let entry = cachedEntry else { return "" }
    return "\(entry.originalWidth) \u{00D7} \(entry.originalHeight)"
  }

  private var imageSize: String {
    let bytes = currentImage.byteCount
    if bytes < 1_024 {
      return "\(bytes) B"
    } else if bytes < 1_024 * 1_024 {
      return String(format: "%.1f KB", Double(bytes) / 1_024)
    } else {
      return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
  }

  var body: some View {
    GeometryReader { _ in
      ZStack {
        Color.black

        if let displayImage {
          #if os(macOS)
            let img = Image(nsImage: displayImage)
          #else
            let img = Image(uiImage: displayImage)
          #endif
          img
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 50)
            .padding(.bottom, images.count > 1 ? 80 : 12)
            .id(currentIndex)
        }

        VStack(spacing: 0) {
          HStack {
            if images.count > 1 {
              Text("\(currentIndex + 1) of \(images.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
            }

            Spacer()

            HStack(spacing: 8) {
              Text(imageDimensions)
              Text("•")
              Text(imageSize)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Button {
              if let onDismiss { onDismiss() } else { dismiss() }
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
              .keyboardShortcut(.escape, modifiers: [])
            #endif
          }
          .padding(12)

          Spacer()

          if images.count > 1 {
            HStack(spacing: 16) {
              Button {
                withAnimation(.easeOut(duration: 0.2)) {
                  currentIndex = (currentIndex - 1 + images.count) % images.count
                }
              } label: {
                Image(systemName: "chevron.left")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundStyle(.white)
                  .frame(width: 40, height: 40)
                  .background(.white.opacity(0.15), in: Circle())
              }
              .buttonStyle(.plain)
              #if os(macOS)
                .keyboardShortcut(.leftArrow, modifiers: [])
              #endif

              HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                  if let thumb = ImageCache.shared.image(for: image) {
                    Button {
                      withAnimation(.easeOut(duration: 0.2)) {
                        currentIndex = index
                      }
                    } label: {
                      #if os(macOS)
                        let thumbImg = Image(nsImage: thumb)
                      #else
                        let thumbImg = Image(uiImage: thumb)
                      #endif
                      thumbImg
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                          RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(index == currentIndex ? Color.accent : Color.clear, lineWidth: 2)
                        )
                        .opacity(index == currentIndex ? 1.0 : 0.5)
                    }
                    .buttonStyle(.plain)
                  }
                }
              }
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(.black.opacity(0.5), in: Capsule())

              Button {
                withAnimation(.easeOut(duration: 0.2)) {
                  currentIndex = (currentIndex + 1) % images.count
                }
              } label: {
                Image(systemName: "chevron.right")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundStyle(.white)
                  .frame(width: 40, height: 40)
                  .background(.white.opacity(0.15), in: Circle())
              }
              .buttonStyle(.plain)
              #if os(macOS)
                .keyboardShortcut(.rightArrow, modifiers: [])
              #endif
            }
            .padding(.bottom, 16)
          }
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 800, idealWidth: 1_000, minHeight: 600, idealHeight: 750)
    #endif
  }
}

struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = layout(proposal: proposal, subviews: subviews)
    return result.size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = layout(proposal: proposal, subviews: subviews)
    for (index, position) in result.positions.enumerated() {
      subviews[index].place(
        at: CGPoint(
          x: bounds.maxX - position.x - subviews[index].sizeThatFits(.unspecified).width,
          y: bounds.minY + position.y
        ),
        proposal: .unspecified
      )
    }
  }

  private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
    let maxWidth = proposal.width ?? .infinity
    var positions: [CGPoint] = []
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var lineHeight: CGFloat = 0
    var totalWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)

      if currentX + size.width > maxWidth, currentX > 0 {
        currentX = 0
        currentY += lineHeight + spacing
        lineHeight = 0
      }

      positions.append(CGPoint(x: currentX, y: currentY))
      currentX += size.width + spacing
      lineHeight = max(lineHeight, size.height)
      totalWidth = max(totalWidth, currentX - spacing)
    }

    return (CGSize(width: totalWidth, height: currentY + lineHeight), positions)
  }
}
