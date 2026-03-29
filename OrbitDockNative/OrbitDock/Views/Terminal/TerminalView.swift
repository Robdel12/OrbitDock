import SwiftUI

// SwiftUI wrapper around the platform-native terminal renderer.
//
// Bridges `TerminalNSView` (macOS) or `TerminalUIView` (iOS) into SwiftUI
// and wires up the session controller for I/O and resize events.
#if os(macOS)
  struct TerminalView: NSViewRepresentable {
    let session: TerminalSessionController

    func makeNSView(context: Context) -> TerminalNSView {
      let view = TerminalNSView()
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
      context.coordinator.terminalView = view

      // Wire up: when PTY data arrives → trigger NSView redraw
      session.onOutputReceived = { [weak view] in
        view?.terminalDidUpdate()
      }

      return view
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
      nsView.sessionController = session
    }

    func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    final class Coordinator {
      weak var terminalView: TerminalNSView?
    }
  }
#else
  struct TerminalView: UIViewRepresentable {
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
