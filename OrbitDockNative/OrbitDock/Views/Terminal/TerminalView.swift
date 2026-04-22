import SwiftUI

// SwiftUI wrapper around the platform-native terminal renderer.
//
// Bridges `TerminalNSView` (macOS) or `TerminalUIView` (iOS) into SwiftUI
// and wires up the session controller for I/O and resize events.
#if os(macOS)
  struct TerminalView: NSViewRepresentable {
    let session: TerminalSessionController
    var shouldAutoFocusOnFirstAttachment: Bool = true
    var captureScrollWithoutFocus: Bool = true
    var cursorBlinkEnabled: Bool = true
    var allowsInput: Bool = true

    func makeNSView(context: Context) -> TerminalNSView {
      let view = TerminalNSView()
      configure(view)
      installResizeHandler(on: view)
      context.coordinator.terminalView = view
      installOutputHandler(on: view)

      return view
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
      configure(nsView)
    }

    func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    final class Coordinator {
      weak var terminalView: TerminalNSView?
    }

    private func configure(_ view: TerminalNSView) {
      view.sessionController = session
      view.shouldAutoFocusOnFirstAttachment = shouldAutoFocusOnFirstAttachment
      view.captureScrollWithoutFocus = captureScrollWithoutFocus
      view.cursorBlinkEnabled = cursorBlinkEnabled
      view.allowsInput = allowsInput
    }

    private func installResizeHandler(on view: TerminalNSView) {
      view.onResize = { [weak session] cols, rows in
        guard let session else { return }
        session.handleResize(
          cols: cols,
          rows: rows,
          cellWidth: UInt32(view.cellWidth),
          cellHeight: UInt32(view.cellHeight)
        )
      }
    }

    private func installOutputHandler(on view: TerminalNSView) {
      session.onOutputReceived = { [weak view] in
        view?.terminalDidUpdate()
      }
    }
  }
#else
  struct TerminalView: UIViewRepresentable {
    let session: TerminalSessionController
    var shouldAutoFocusOnFirstAttachment: Bool = true
    var captureScrollWithoutFocus: Bool = true
    var cursorBlinkEnabled: Bool = true
    var allowsInput: Bool = true

    func makeUIView(context: Context) -> TerminalUIView {
      let view = TerminalUIView()
      configure(view)
      installResizeHandler(on: view)
      context.coordinator.terminalView = view
      installOutputHandler(on: view)
      return view
    }

    func updateUIView(_ uiView: TerminalUIView, context: Context) {
      configure(uiView)
    }

    func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    final class Coordinator {
      weak var terminalView: TerminalUIView?
    }

    private func configure(_ view: TerminalUIView) {
      view.sessionController = session
      view.shouldAutoFocusOnFirstAttachment = shouldAutoFocusOnFirstAttachment
      view.captureScrollWithoutFocus = captureScrollWithoutFocus
      view.cursorBlinkEnabled = cursorBlinkEnabled
      view.allowsInput = allowsInput
    }

    private func installResizeHandler(on view: TerminalUIView) {
      view.onResize = { [weak session] cols, rows in
        guard let session else { return }
        session.handleResize(
          cols: cols,
          rows: rows,
          cellWidth: UInt32(view.cellWidth),
          cellHeight: UInt32(view.cellHeight)
        )
      }
    }

    private func installOutputHandler(on view: TerminalUIView) {
      session.onOutputReceived = { [weak view] in
        view?.terminalDidUpdate()
      }
    }
  }
#endif
