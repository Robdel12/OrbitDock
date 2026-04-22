import SwiftUI

/// Ghostty-backed terminal view with chrome (traffic lights, title bar).
struct TerminalContainerView: View {
  let session: TerminalSessionController
  var shouldAutoFocusOnFirstAttachment: Bool = true
  var captureScrollWithoutFocus: Bool = true
  var cursorBlinkEnabled: Bool = true
  var allowsInput: Bool = true
  var titleOverride: String?
  var showsTitleBar: Bool = true

  var body: some View {
    VStack(spacing: 0) {
      if showsTitleBar {
        terminalTitleBar
      }

      TerminalView(
        session: session,
        shouldAutoFocusOnFirstAttachment: shouldAutoFocusOnFirstAttachment,
        captureScrollWithoutFocus: captureScrollWithoutFocus,
        cursorBlinkEnabled: cursorBlinkEnabled,
        allowsInput: allowsInput
      )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.backgroundCode)
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
  }

  private var terminalTitleBar: some View {
    HStack(spacing: 0) {
      #if os(macOS)
        trafficLights
      #endif

      Spacer()

      Text(titleText)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)

      Spacer()

      #if os(macOS)
        trafficLightSpacer
      #endif
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundCode.opacity(0.8))
  }

  private var titleText: String {
    titleOverride ?? session.title
  }

  #if os(macOS)
    private var trafficLights: some View {
      HStack(spacing: Spacing.xs) {
        Circle().fill(Color(red: 1.0, green: 0.38, blue: 0.35)).frame(width: 6, height: 6)
        Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.2)).frame(width: 6, height: 6)
        Circle().fill(Color(red: 0.3, green: 0.8, blue: 0.35)).frame(width: 6, height: 6)
      }
    }

    private var trafficLightSpacer: some View {
      HStack(spacing: Spacing.xs) {
        Circle().fill(Color.clear).frame(width: 6, height: 6)
        Circle().fill(Color.clear).frame(width: 6, height: 6)
        Circle().fill(Color.clear).frame(width: 6, height: 6)
      }
    }
  #endif
}
