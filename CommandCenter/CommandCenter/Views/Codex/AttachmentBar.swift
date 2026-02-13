//
//  AttachmentBar.swift
//  OrbitDock
//
//  Horizontal strip showing attached images and file mentions
//  above the input row, with remove buttons.
//

import SwiftUI

struct AttachedImage: Identifiable, Equatable {
  let id: String
  let thumbnail: NSImage
  let serverInput: ServerImageInput

  static func == (lhs: AttachedImage, rhs: AttachedImage) -> Bool {
    lhs.id == rhs.id
  }
}

struct AttachedMention: Identifiable, Equatable {
  let id: String    // relative path
  let name: String  // filename
  let path: String  // absolute path
}

struct AttachmentBar: View {
  @Binding var images: [AttachedImage]
  @Binding var mentions: [AttachedMention]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(images) { image in
          imageChip(image)
            .transition(.scale.combined(with: .opacity))
        }
        ForEach(mentions) { mention in
          mentionChip(mention)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .padding(.horizontal, 16)
      .animation(.spring(response: 0.35, dampingFraction: 0.8), value: images.count)
      .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mentions.count)
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private func imageChip(_ image: AttachedImage) -> some View {
    ZStack(alignment: .topTrailing) {
      Image(nsImage: image.thumbnail)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))

      removeButton {
        images.removeAll { $0.id == image.id }
      }
    }
  }

  @ViewBuilder
  private func mentionChip(_ mention: AttachedMention) -> some View {
    HStack(spacing: 4) {
      Image(systemName: fileIcon(for: mention.name))
        .font(.caption2)
        .foregroundStyle(Color.accent)

      Text(mention.name)
        .font(.caption)
        .lineLimit(1)

      Button {
        mentions.removeAll { $0.id == mention.id }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.accent.opacity(0.12))
    .clipShape(Capsule())
    .help(mention.path)
  }

  @ViewBuilder
  private func removeButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.8))
        .background(Circle().fill(.black.opacity(0.5)))
    }
    .buttonStyle(.plain)
    .offset(x: 4, y: -4)
  }

  private func fileIcon(for name: String) -> String {
    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "rs": return "gearshape.2"
    case "js", "ts", "jsx", "tsx": return "curlybraces"
    case "py": return "chevron.left.forwardslash.chevron.right"
    case "sh", "bash", "zsh": return "terminal"
    case "json", "yaml", "yml", "toml": return "doc.text"
    case "md", "txt": return "doc.plaintext"
    case "html", "css": return "globe"
    default: return "doc"
    }
  }
}
