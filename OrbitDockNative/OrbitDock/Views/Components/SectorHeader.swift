import SwiftUI

/// Mission-sector-style section header for project groups and tier sections.
///
/// Layout: `[TITLE] [─── connecting line ───] [count] [chevron]`
///
/// The thin connecting line between title and count creates a technical readout
/// feel — like a mission manifest entry.
struct SectorHeader: View {
  let title: String
  let color: Color
  let count: Int
  var isCollapsed: Bool?
  var onToggle: (() -> Void)?

  var body: some View {
    let showChevron = isCollapsed != nil

    Button {
      onToggle?()
    } label: {
      HStack(spacing: Spacing.sm_) {
        Text(title.uppercased())
          .font(.system(size: TypeScale.micro, weight: .bold))
          .foregroundStyle(color.opacity(0.8))
          .tracking(1.2)
          .lineLimit(1)

        // Connecting line — fills remaining space
        Rectangle()
          .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
          .frame(height: 1)

        // Count badge
        Text("\(count)")
          .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)

        if showChevron {
          Image(systemName: isCollapsed == true ? "chevron.right" : "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .frame(width: 10)
        }
      }
      .padding(.vertical, Spacing.sm)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(onToggle == nil)
  }
}

#Preview {
  VStack(alignment: .leading, spacing: Spacing.lg) {
    SectorHeader(title: "OrbitDock", color: .statusWorking, count: 10)

    SectorHeader(
      title: "Incoming",
      color: .statusPermission,
      count: 2,
      isCollapsed: false
    ) {}

    SectorHeader(
      title: "BunHelp",
      color: .accent,
      count: 3,
      isCollapsed: true
    ) {}
  }
  .padding(24)
  .background(Color.backgroundPrimary)
  .preferredColorScheme(.dark)
}
