import ImageIO
import SwiftUI

extension Notification.Name {
  static let conversationImageCacheDidUpdate = Notification.Name("conversation-image-cache-did-update")
}

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
  private var inFlightLoads: Set<String> = []
  private var sessionStoresByEndpointId: [UUID: WeakSessionStoreBox] = [:]
  private let lock = NSLock()

  private struct AttachmentLoadPreparation {
    let shouldStart: Bool
    let sessionStore: SessionStore?
  }

  /// Returns the cached display image (downsampled) for scroll rendering.
  func image(for messageImage: MessageImage) -> PlatformImage? {
    cachedImage(for: messageImage)?.displayImage
  }

  /// Returns the full cache entry including original dimensions for labels.
  func cachedImage(for messageImage: MessageImage) -> CachedImage? {
    if let cached = cachedImageIfPresent(for: messageImage.id) {
      return cached
    }

    startLoadIfNeeded(for: messageImage)
    return nil
  }

  // MARK: - Private

  func register(sessionStore: SessionStore) {
    lock.lock()
    sessionStoresByEndpointId[sessionStore.endpointId] = WeakSessionStoreBox(sessionStore)
    lock.unlock()
  }

  private func cachedImageIfPresent(for imageId: String) -> CachedImage? {
    lock.lock()
    defer { lock.unlock() }
    return cache[imageId]
  }

  private func startLoadIfNeeded(for messageImage: MessageImage) {
    switch messageImage.source {
      case .serverAttachment(let reference):
        startAttachmentLoadIfNeeded(reference: reference, imageId: messageImage.id)
      case .filePath, .dataURI, .inlineData:
        startLocalDecodeIfNeeded(messageImage: messageImage)
    }
  }

  private func startLocalDecodeIfNeeded(messageImage: MessageImage) {
    guard beginLoadIfNeeded(imageId: messageImage.id) else { return }

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      defer { DispatchQueue.main.async { self.finishAttachmentLoad(imageId: messageImage.id) } }

      let opts = [kCGImageSourceShouldCache: false] as CFDictionary
      let source: CGImageSource?
      switch messageImage.source {
        case let .filePath(path):
          source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, opts)
        case let .dataURI(uri):
          guard uri.hasPrefix("data:") else { return }
          let withoutScheme = String(uri.dropFirst(5))
          guard let commaIndex = withoutScheme.firstIndex(of: ",") else { return }
          let base64String = String(withoutScheme[withoutScheme.index(after: commaIndex)...])
          guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else { return }
          source = CGImageSourceCreateWithData(data as CFData, opts)
        case let .inlineData(data):
          source = CGImageSourceCreateWithData(data as CFData, opts)
        case .serverAttachment:
          source = nil
      }

      guard let source else { return }
      guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
      let origW = props[kCGImagePropertyPixelWidth] as? Int ?? 0
      let origH = props[kCGImagePropertyPixelHeight] as? Int ?? 0
      let thumbOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
        source, 0, thumbOptions as CFDictionary
      ) else { return }

      #if os(macOS)
        let displayImage = NSImage(
          cgImage: cgImage,
          size: NSSize(width: cgImage.width, height: cgImage.height)
        )
      #else
        let displayImage = UIImage(cgImage: cgImage)
      #endif

      let image = CachedImage(
        displayImage: displayImage,
        originalWidth: origW,
        originalHeight: origH
      )

      DispatchQueue.main.async {
        self.storeLoadedImage(imageId: messageImage.id, image: image)
        NotificationCenter.default.post(
          name: .conversationImageCacheDidUpdate,
          object: nil,
          userInfo: ["imageId": messageImage.id]
        )
      }
    }
  }

  private func startAttachmentLoadIfNeeded(reference: ServerAttachmentImageReference, imageId: String) {
    guard let endpointId = reference.endpointId else { return }

    let preparation = prepareAttachmentLoad(
      endpointId: endpointId,
      imageId: imageId
    )

    guard preparation.shouldStart else { return }
    guard let sessionStore = preparation.sessionStore else {
      abandonAttachmentLoad(endpointId: endpointId, imageId: imageId)
      return
    }

    Task {
      defer {
        finishAttachmentLoad(imageId: imageId)
      }

      guard let data = try? await sessionStore.clients.conversation.downloadImageAttachment(
        sessionId: reference.sessionId,
        attachmentId: reference.attachmentId
      ) else { return }

      let maxPixelSize = Self.maxPixelSize
      let loaded = await Task.detached(priority: .utility) { () -> CachedImage? in
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let origW = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let origH = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let thumbOptions: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
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

        return CachedImage(
          displayImage: displayImage,
          originalWidth: origW,
          originalHeight: origH
        )
      }.value

      guard let loaded else { return }

      storeLoadedAttachmentImage(
        endpointId: endpointId,
        imageId: imageId,
        image: loaded,
        sessionStore: sessionStore
      )

      await MainActor.run {
        NotificationCenter.default.post(
          name: .conversationImageCacheDidUpdate,
          object: nil,
          userInfo: ["imageId": imageId]
        )
      }
    }
  }

  private func prepareAttachmentLoad(
    endpointId: UUID,
    imageId: String
  ) -> AttachmentLoadPreparation {
    guard beginLoadIfNeeded(imageId: imageId) else {
      return AttachmentLoadPreparation(shouldStart: false, sessionStore: nil)
    }
    lock.lock()
    defer { lock.unlock() }
    return AttachmentLoadPreparation(
      shouldStart: true,
      sessionStore: sessionStoresByEndpointId[endpointId]?.store
    )
  }

  private func beginLoadIfNeeded(imageId: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    if cache[imageId] != nil || inFlightLoads.contains(imageId) {
      return false
    }
    inFlightLoads.insert(imageId)
    return true
  }

  private func abandonAttachmentLoad(endpointId: UUID, imageId: String) {
    lock.lock()
    defer { lock.unlock() }
    inFlightLoads.remove(imageId)
    sessionStoresByEndpointId.removeValue(forKey: endpointId)
  }

  private func finishAttachmentLoad(imageId: String) {
    lock.lock()
    defer { lock.unlock() }
    inFlightLoads.remove(imageId)
  }

  private func storeLoadedAttachmentImage(
    endpointId: UUID,
    imageId: String,
    image: CachedImage,
    sessionStore: SessionStore
  ) {
    lock.lock()
    defer { lock.unlock() }
    cache[imageId] = image
    sessionStoresByEndpointId[endpointId] = WeakSessionStoreBox(sessionStore)
  }

  private func storeLoadedImage(imageId: String, image: CachedImage) {
    lock.lock()
    defer { lock.unlock() }
    cache[imageId] = image
  }

}

private final class WeakSessionStoreBox {
  weak var store: SessionStore?

  init(_ store: SessionStore) {
    self.store = store
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
    VStack(alignment: .trailing, spacing: Spacing.sm) {
      Button {
        withAnimation(Motion.standard) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 11, weight: .semibold))
          Text(images.count == 1 ? "1 image" : "\(images.count) images")
            .font(.system(size: TypeScale.caption, weight: .medium))
          Text("•")
            .foregroundStyle(Color.textQuaternary)
          Text(totalSize)
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
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
          } else {
            SingleImagePlaceholderView(imageData: images[0]) {
              selectedIndex = 0
            }
          }
        } else {
          FlowLayout(spacing: Spacing.md) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
              if let img = ImageCache.shared.image(for: image) {
                ImageThumbnail(
                  platformImage: img,
                  imageData: image,
                  index: index
                ) {
                  selectedIndex = index
                }
              } else {
                ImageThumbnailPlaceholder(imageData: image, index: index) {
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

private func imageSizeLabel(_ bytes: Int) -> String {
  if bytes < 1_024 {
    return "\(bytes) B"
  } else if bytes < 1_024 * 1_024 {
    return String(format: "%.1f KB", Double(bytes) / 1_024)
  } else {
    return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
  }
}

private func imageDimensionsLabel(width: Int?, height: Int?) -> String? {
  guard let width, let height, width > 0, height > 0 else { return nil }
  return "\(width) \u{00D7} \(height)"
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
    imageSizeLabel(imageData.byteCount)
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
      VStack(alignment: .trailing, spacing: Spacing.sm_) {
        swiftUIImage
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: 400, maxHeight: 300)
          .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
              .strokeBorder(Color.white.opacity(isHovering ? 0.25 : 0.1), lineWidth: 1)
          )
          .themeShadow(Shadow.md)
          .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.white)
              .padding(Spacing.sm_)
              .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
              .padding(Spacing.sm)
              .opacity(isHovering ? 1 : 0)
          }

        HStack(spacing: Spacing.sm) {
          Text(imageDimensions)
          Text("•")
          Text(imageSize)
        }
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
      }
      .scaleEffect(isHovering ? 1.01 : 1.0)
      .animation(Motion.hover, value: isHovering)
    }
    .buttonStyle(.plain)
    #if os(macOS)
      .onHover { isHovering = $0 }
    #endif
  }
}

struct SingleImagePlaceholderView: View {
  let imageData: MessageImage
  let onTap: () -> Void

  @State private var isHovering = false

  private var imageDimensions: String {
    imageDimensionsLabel(width: imageData.pixelWidth, height: imageData.pixelHeight) ?? "Loading image"
  }

  private var imageSize: String {
    imageSizeLabel(imageData.byteCount)
  }

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .trailing, spacing: Spacing.sm_) {
        AttachmentImagePlaceholder(aspectRatio: placeholderAspectRatio(for: imageData))
          .frame(maxWidth: 400, maxHeight: 300)
          .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
              .strokeBorder(Color.white.opacity(isHovering ? 0.25 : 0.1), lineWidth: 1)
          )
          .themeShadow(Shadow.md)

        HStack(spacing: Spacing.sm) {
          Text(imageDimensions)
          Text("•")
          Text(imageSize)
        }
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
      }
      .scaleEffect(isHovering ? 1.01 : 1.0)
      .animation(Motion.hover, value: isHovering)
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
          .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
              .strokeBorder(Color.white.opacity(isHovering ? 0.3 : 0.12), lineWidth: 1)
          )
          .themeShadow(Shadow.md)

        Text("\(index + 1)")
          .font(.system(size: TypeScale.meta, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .frame(width: 22, height: 22)
          .background(Color.accent.opacity(0.9), in: Circle())
          .padding(Spacing.sm)

        if isHovering {
          VStack {
            Spacer()
            HStack {
              Spacer()
              Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(Spacing.xs)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .padding(Spacing.sm_)
            }
          }
        }
      }
      .scaleEffect(isHovering ? 1.03 : 1.0)
      .animation(Motion.hover, value: isHovering)
    }
    .buttonStyle(.plain)
    #if os(macOS)
      .onHover { isHovering = $0 }
    #endif
  }
}

struct ImageThumbnailPlaceholder: View {
  let imageData: MessageImage
  let index: Int
  let onTap: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onTap) {
      ZStack(alignment: .topTrailing) {
        AttachmentImagePlaceholder(aspectRatio: placeholderAspectRatio(for: imageData))
          .frame(width: 200, height: 150)
          .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
              .strokeBorder(Color.white.opacity(isHovering ? 0.3 : 0.12), lineWidth: 1)
          )
          .themeShadow(Shadow.md)

        Text("\(index + 1)")
          .font(.system(size: TypeScale.meta, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .frame(width: 22, height: 22)
          .background(Color.accent.opacity(0.9), in: Circle())
          .padding(Spacing.sm)
      }
      .scaleEffect(isHovering ? 1.03 : 1.0)
      .animation(Motion.hover, value: isHovering)
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
    if let entry = cachedEntry {
      return "\(entry.originalWidth) \u{00D7} \(entry.originalHeight)"
    }
    return imageDimensionsLabel(width: currentImage.pixelWidth, height: currentImage.pixelHeight) ?? "Loading image"
  }

  private var imageSize: String {
    imageSizeLabel(currentImage.byteCount)
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
            .padding(.horizontal, Spacing.md)
            .padding(.top, 50)
            .padding(.bottom, images.count > 1 ? 80 : Spacing.md)
            .id(currentIndex)
        } else {
          AttachmentImagePlaceholder(aspectRatio: placeholderAspectRatio(for: currentImage))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Spacing.md)
            .padding(.top, 50)
            .padding(.bottom, images.count > 1 ? 80 : Spacing.md)
        }

        VStack(spacing: 0) {
          HStack {
            if images.count > 1 {
              Text("\(currentIndex + 1) of \(images.count)")
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm_)
                .background(.black.opacity(0.5), in: Capsule())
            }

            Spacer()

            HStack(spacing: Spacing.sm) {
              Text(imageDimensions)
              Text("•")
              Text(imageSize)
            }
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
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
          .padding(Spacing.md)

          Spacer()

          if images.count > 1 {
            HStack(spacing: Spacing.lg) {
              Button {
                withAnimation(Motion.fade) {
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

              HStack(spacing: Spacing.sm) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                  if let thumb = ImageCache.shared.image(for: image) {
                    Button {
                      withAnimation(Motion.fade) {
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
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous))
                        .overlay(
                          RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
                            .strokeBorder(index == currentIndex ? Color.accent : Color.clear, lineWidth: 2)
                        )
                        .opacity(index == currentIndex ? 1.0 : 0.5)
                    }
                    .buttonStyle(.plain)
                  } else {
                    Button {
                      withAnimation(Motion.fade) {
                        currentIndex = index
                      }
                    } label: {
                      AttachmentImagePlaceholder(aspectRatio: placeholderAspectRatio(for: image))
                        .frame(width: 56, height: 42)
                        .overlay(
                          RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
                            .strokeBorder(index == currentIndex ? Color.accent : Color.clear, lineWidth: 2)
                        )
                        .opacity(index == currentIndex ? 1.0 : 0.5)
                    }
                    .buttonStyle(.plain)
                  }
                }
              }
              .padding(.horizontal, Spacing.lg_)
              .padding(.vertical, Spacing.sm)
              .background(.black.opacity(0.5), in: Capsule())

              Button {
                withAnimation(Motion.fade) {
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
            .padding(.bottom, Spacing.lg)
          }
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 800, idealWidth: 1_000, minHeight: 600, idealHeight: 750)
    #endif
  }
}

private struct AttachmentImagePlaceholder: View {
  let aspectRatio: CGFloat

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              Color.backgroundTertiary.opacity(0.95),
              Color.backgroundSecondary.opacity(0.88),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

      VStack(spacing: Spacing.xs) {
        Image(systemName: "photo.badge.arrow.down")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
        Text("Loading image")
          .font(.system(size: TypeScale.meta, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
      }
    }
    .aspectRatio(max(aspectRatio, 0.6), contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
  }
}

private func placeholderAspectRatio(for image: MessageImage) -> CGFloat {
  guard let width = image.pixelWidth,
        let height = image.pixelHeight,
        width > 0,
        height > 0
  else {
    return 4.0 / 3.0
  }
  return CGFloat(width) / CGFloat(height)
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
