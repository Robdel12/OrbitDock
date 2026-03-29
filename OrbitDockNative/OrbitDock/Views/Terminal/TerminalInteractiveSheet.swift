#if os(iOS)
  import SwiftUI

  /// Full-screen interactive terminal sheet for iOS.
  ///
  /// Presents the ghostty terminal at full size with the software keyboard
  /// active and the special-key accessory bar. The terminal auto-focuses
  /// on appear so the user can start typing immediately.
  struct TerminalInteractiveSheet: View {
    let session: TerminalSessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      VStack(spacing: 0) {
        sheetHeader
        terminalSurface
      }
      .background(Color.backgroundCode)
      .statusBarHidden(false)
      .persistentSystemOverlays(.hidden)
    }

    // MARK: - Header

    private var sheetHeader: some View {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "terminal")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.terminal)

        Text(session.title)
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(1)

        Spacer()

        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm_)
      .background(Color.backgroundCode.opacity(0.9))
      .background(.ultraThinMaterial.opacity(0.3))
    }

    // MARK: - Terminal

    private var terminalSurface: some View {
      TerminalInteractiveView(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// UIViewRepresentable that hosts the TerminalUIView for the interactive sheet.
  /// Auto-focuses the terminal on appear so the software keyboard shows immediately.
  struct TerminalInteractiveView: UIViewRepresentable {
    let session: TerminalSessionController

    func makeUIView(context: Context) -> TerminalUIView {
      let view = TerminalUIView()
      view.sessionController = session
      view.shouldAutoFocusOnFirstAttachment = true
      view.onResize = { [weak session] cols, rows in
        guard let session else { return }
        session.handleResize(
          cols: cols,
          rows: rows,
          cellWidth: UInt32(view.cellWidth),
          cellHeight: UInt32(view.cellHeight)
        )
      }

      session.onOutputReceived = { [weak view] in
        view?.terminalDidUpdate()
      }

      context.coordinator.terminalView = view
      return view
    }

    func updateUIView(_ uiView: TerminalUIView, context: Context) {
      uiView.sessionController = session
    }

    func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    final class Coordinator {
      weak var terminalView: TerminalUIView?
    }
  }
#endif
