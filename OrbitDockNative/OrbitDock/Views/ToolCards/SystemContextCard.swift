import SwiftUI

struct SystemContextCard: View {
  let context: ParsedSystemContext

  @State private var isExpanded = false
  @State private var isHovering = false

  private var lineCount: Int {
    context.body.components(separatedBy: "\n").count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(Motion.snappy) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: context.icon)
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Text(context.label)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          if !isExpanded {
            Text("\u{00B7}")
              .foregroundStyle(Color.textQuaternary)
            Text("\(lineCount) lines")
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(isHovering ? 0.8 : 0.5))
        )
      }
      .buttonStyle(.plain)
      .onHover { isHovering = $0 }

      if isExpanded {
        ScrollView {
          MarkdownRepresentable(content: context.body, style: .thinking)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
        .padding(Spacing.md)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.3))
        )
        .padding(.top, Spacing.xs)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
}

struct SystemCaveatView: View {
  let caveat: ParsedSystemCaveat

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "info.circle")
        .font(.system(size: TypeScale.micro, weight: .medium))

      Text("System notice")
        .font(.system(size: TypeScale.meta, weight: .medium))
    }
    .foregroundStyle(Color.textQuaternary)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
  }
}
