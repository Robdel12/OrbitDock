import SwiftUI

#if os(macOS)
  struct ZoomableImagePreview: View {
    let image: Image
    let title: String
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
      VStack(spacing: 0) {
        toolbar
        zoomableContent
      }
      .background(Color.black)
    }

    private var toolbar: some View {
      HStack {
        Text(title)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(.white)

        Spacer()

        HStack(spacing: Spacing.sm) {
          Button { withAnimation(.spring(response: 0.3)) { resetZoom() } } label: {
            Image(systemName: "arrow.counterclockwise")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(.white.opacity(0.7))
          }
          .buttonStyle(.plain)
          .disabled(scale == 1.0 && offset == .zero)

          Text("\(Int(scale * 100))%")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))

          Button("Done") { onDismiss() }
            .keyboardShortcut(.cancelAction)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(.black)
    }

    private var zoomableContent: some View {
      GeometryReader { geo in
        image
          .resizable()
          .aspectRatio(contentMode: .fit)
          .scaleEffect(scale)
          .offset(offset)
          .frame(width: geo.size.width, height: geo.size.height)
          .clipped()
          .contentShape(Rectangle())
          .gesture(magnification)
          .gesture(drag)
          .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.3)) {
              if scale > 1.05 {
                resetZoom()
              } else {
                scale = 2.5
                lastScale = 2.5
              }
            }
          }
      }
    }

    private var magnification: some Gesture {
      MagnifyGesture()
        .onChanged { value in
          let newScale = lastScale * value.magnification
          scale = max(0.5, min(newScale, 8.0))
        }
        .onEnded { _ in
          lastScale = scale
          if scale < 1.0 {
            withAnimation(.spring(response: 0.3)) { resetZoom() }
          }
        }
    }

    private var drag: some Gesture {
      DragGesture()
        .onChanged { value in
          guard scale > 1.0 else { return }
          offset = CGSize(
            width: lastOffset.width + value.translation.width,
            height: lastOffset.height + value.translation.height
          )
        }
        .onEnded { _ in
          lastOffset = offset
        }
    }

    private func resetZoom() {
      scale = 1.0
      lastScale = 1.0
      offset = .zero
      lastOffset = .zero
    }
  }
#endif
