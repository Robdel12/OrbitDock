import SwiftUI

/// Full terminal view with chrome (traffic lights, title bar) and the
/// Core Text-based terminal renderer.
struct TerminalContainerView: View {
  let session: TerminalSessionController
  var shouldAutoFocusOnFirstAttachment: Bool = true
  var captureScrollWithoutFocus: Bool = true
  var titleOverride: String?

  var body: some View {
    VStack(spacing: 0) {
      // Terminal title bar with traffic lights.
      terminalTitleBar

      // The actual terminal renderer.
      TerminalView(
        session: session,
        shouldAutoFocusOnFirstAttachment: shouldAutoFocusOnFirstAttachment,
        captureScrollWithoutFocus: captureScrollWithoutFocus
      )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.backgroundCode)
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
  }

  private var terminalTitleBar: some View {
    HStack(spacing: 0) {
      #if os(macOS)
        HStack(spacing: Spacing.xs) {
          Circle().fill(Color(red: 1.0, green: 0.38, blue: 0.35)).frame(width: 6, height: 6)
          Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.2)).frame(width: 6, height: 6)
          Circle().fill(Color(red: 0.3, green: 0.8, blue: 0.35)).frame(width: 6, height: 6)
        }
      #endif

      Spacer()

      Text(titleOverride ?? session.title)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)

      Spacer()

      #if os(macOS)
        // Balance spacer for traffic light dots.
        HStack(spacing: Spacing.xs) {
          Circle().fill(Color.clear).frame(width: 6, height: 6)
          Circle().fill(Color.clear).frame(width: 6, height: 6)
          Circle().fill(Color.clear).frame(width: 6, height: 6)
        }
      #endif
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundCode.opacity(0.8))
  }
}
