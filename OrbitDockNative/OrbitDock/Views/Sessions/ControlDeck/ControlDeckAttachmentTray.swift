import SwiftUI

struct ControlDeckAttachmentTray: View {
  let attachments: [ControlDeckAttachmentItem]
  let onRemove: (String) -> Void

  @State private var previewItem: ControlDeckAttachmentItem?
  private static let thumbnailMaxDimension: CGFloat = 72
  private static let previewMaxDimension: CGFloat = 2_048

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        ForEach(attachments) { item in
          chipView(item)
            .onTapGesture {
              if case .image = item.kind {
                previewItem = item
              }
            }
        }
      }
    }
    .scrollIndicators(.hidden)
    .platformImagePreview(item: $previewItem) { item in
      imagePreview(item)
    }
  }

  // MARK: - Image Preview

  @ViewBuilder
  private func imagePreview(_ item: ControlDeckAttachmentItem) -> some View {
    if case let .image(img) = item.kind {
      ZoomableImagePreview(
        image: platformImage(from: previewData(for: img), maxDimension: Self.previewMaxDimension),
        title: img.displayName
      ) {
        previewItem = nil
      }
      .frame(minWidth: 480, idealWidth: 720, minHeight: 420, idealHeight: 560)
    }
  }

  private func chipView(_ item: ControlDeckAttachmentItem) -> some View {
    HStack(spacing: Spacing.xs) {
      chipIcon(item)
      chipLabel(item)

      Button { onRemove(item.id) } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(Color.textTertiary)
          .frame(width: 14, height: 14)
          .background(Color.textQuaternary.opacity(OpacityTier.medium), in: Circle())
      }
      .buttonStyle(.plain)
    }
    .padding(.leading, Spacing.sm_)
    .padding(.trailing, Spacing.xs)
    .padding(.vertical, Spacing.xs)
    .background(chipTint(item).opacity(OpacityTier.light), in: Capsule())
    .overlay(Capsule().strokeBorder(chipTint(item).opacity(OpacityTier.medium), lineWidth: 0.5))
  }

  @ViewBuilder
  private func chipIcon(_ item: ControlDeckAttachmentItem) -> some View {
    switch item.kind {
      case let .image(img):
        if let thumbnailImage = platformImage(from: thumbnailData(for: img), maxDimension: Self.thumbnailMaxDimension) {
          thumbnailImage
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
          Image(systemName: "photo")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(chipTint(item))
        }
      case let .mention(mention):
        Image(systemName: fileIcon(mention.name))
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(chipTint(item))
    }
  }

  @MainActor
  private func platformImage(from data: Data?, maxDimension: CGFloat) -> Image? {
    guard let data else { return nil }
    let decoded = ImageDecoding.downsampledImage(fromData: data, maxDimension: maxDimension)
      ?? PlatformImage.decoded(from: data)
    return decoded.map(Image.init(platformImage:))
  }

  private func thumbnailData(for image: ControlDeckImageDraft) -> Data? {
    image.thumbnailData ?? image.uploadData
  }

  private func previewData(for image: ControlDeckImageDraft) -> Data? {
    image.uploadData.isEmpty ? image.thumbnailData : image.uploadData
  }

  private func chipLabel(_ item: ControlDeckAttachmentItem) -> some View {
    let name: String = switch item.kind {
      case let .image(img): img.displayName
      case let .mention(m): m.name
    }
    return Text(name)
      .font(.system(size: TypeScale.caption, weight: .medium))
      .foregroundStyle(Color.textPrimary)
      .lineLimit(1)
  }

  private func chipTint(_ item: ControlDeckAttachmentItem) -> Color {
    switch item.kind {
      case .image: .providerClaude
      case .mention: .providerCodex
    }
  }

  private func fileIcon(_ name: String) -> String {
    let ext = name.split(separator: ".").last?.lowercased() ?? ""
    switch ext {
      case "swift": return "swift"
      case "rs": return "terminal"
      case "md": return "doc.plaintext"
      case "json", "yaml", "yml", "toml": return "curlybraces"
      default: return "doc.text"
    }
  }
}
