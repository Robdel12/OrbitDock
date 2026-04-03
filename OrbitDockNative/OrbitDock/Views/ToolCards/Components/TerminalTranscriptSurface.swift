import Foundation
import SwiftUI

/// Static, non-interactive terminal transcript surface backed by Ghostty.
///
/// Designed for expanded tool cards with the same renderer stack as the live terminal.
struct TerminalTranscriptSurface: View {
  let output: String
  var title: String?
  var maxHeight: CGFloat?
  var minRows: Int = 6

  @State private var session = TerminalSessionController(terminalId: "tool-transcript-initial")
  @State private var renderedSignature = ""
  @State private var availableWidth: CGFloat = 0

  private let rowHeight: CGFloat = 17
  private let cellWidth: CGFloat = 8
  private let titleBarHeight: CGFloat = 24
  private let minimumCols = 64
  private let maximumScrollableCols = 640
  private let horizontalInsets: CGFloat = 16

  private struct RenderState {
    let visibleHeight: CGFloat
    let renderRows: Int
  }

  private var normalizedOutput: String {
    let normalizedLF = output
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    // Terminals expect CRLF for deterministic line starts.
    // Keep exact trailing newline semantics so the cursor lands correctly.
    return normalizedLF.replacingOccurrences(of: "\n", with: "\r\n")
  }

  var body: some View {
    let transcript = normalizedOutput
    let viewportWidth = max(availableWidth, 1)
    let viewportCols = estimatedCols(forWidth: viewportWidth)
    let contentCols = estimatedContentCols(for: transcript, minimum: viewportCols)
    let contentWidth = resolvedContentWidth(for: viewportWidth, cols: contentCols)
    let layoutState = renderState(for: transcript, cols: contentCols)

    ScrollView(.horizontal, showsIndicators: true) {
      TerminalContainerView(
        session: session,
        shouldAutoFocusOnFirstAttachment: false,
        captureScrollWithoutFocus: false,
        titleOverride: title
      )
      .frame(width: contentWidth, height: layoutState.visibleHeight, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: layoutState.visibleHeight, alignment: .topLeading)
    .background(widthProbe)
    .onAppear {
      renderIfNeeded(cols: contentCols, rows: layoutState.renderRows, transcript: transcript)
    }
    .onChange(of: output) { _, _ in
      let nextRenderState = renderState(for: transcript, cols: contentCols)
      renderIfNeeded(cols: contentCols, rows: nextRenderState.renderRows, transcript: transcript)
    }
    .onChange(of: contentCols) { _, nextCols in
      let nextRenderState = renderState(for: transcript, cols: nextCols)
      renderIfNeeded(cols: nextCols, rows: nextRenderState.renderRows, transcript: transcript)
    }
    .accessibilityHidden(true)
  }

  private var minimumSurfaceHeight: CGFloat {
    titleBarHeight + rowHeight * CGFloat(max(1, minRows))
  }

  private func resolvedContentWidth(for viewportWidth: CGFloat, cols: Int) -> CGFloat {
    max(viewportWidth, CGFloat(cols) * cellWidth + horizontalInsets)
  }

  private var widthProbe: some View {
    GeometryReader { proxy in
      Color.clear
        .onAppear {
          updateAvailableWidth(proxy.size.width)
        }
        .onChange(of: proxy.size.width) { _, nextWidth in
          updateAvailableWidth(nextWidth)
        }
    }
  }

  private func estimatedCols(forWidth width: CGFloat) -> Int {
    max(minimumCols, Int((width / cellWidth).rounded(.down)))
  }

  private func estimatedRows(for text: String, cols: Int) -> Int {
    let clean = ANSIColorParser.stripANSI(text)
    let baseRows = clean
      .components(separatedBy: "\n")
      .reduce(0) { partial, line in
        let lineLength = max(1, line.count)
        let wraps = max(1, Int(ceil(Double(lineLength) / Double(max(1, cols)))))
        return partial + wraps
      }
    return max(minRows, baseRows + 2)
  }

  private func estimatedContentCols(for text: String, minimum: Int) -> Int {
    let clean = ANSIColorParser.stripANSI(text)
    let longestLine = clean
      .components(separatedBy: "\n")
      .map(\.count)
      .max() ?? minimum

    return min(maximumScrollableCols, max(minimum, longestLine + 2))
  }

  private func renderState(for transcript: String, cols: Int) -> RenderState {
    let estimatedContentRows = estimatedRows(for: transcript, cols: cols)
    let fullContainerHeight = fullHeight(forRows: estimatedContentRows)
    let visibleHeight = resolvedVisibleContainerHeight(fullHeight: fullContainerHeight)
    return RenderState(
      visibleHeight: visibleHeight,
      renderRows: resolvedRenderRows(containerHeight: visibleHeight)
    )
  }

  private func fullHeight(forRows rows: Int) -> CGFloat {
    CGFloat(rows) * rowHeight + titleBarHeight
  }

  private func resolvedVisibleContainerHeight(fullHeight: CGFloat) -> CGFloat {
    let minimum = minimumSurfaceHeight
    guard let maxHeight else {
      return max(minimum, fullHeight)
    }

    let clamped = max(minimum, min(maxHeight + titleBarHeight, fullHeight))
    return clamped
  }

  private func resolvedRenderRows(containerHeight: CGFloat) -> Int {
    let contentHeight = max(0, containerHeight - titleBarHeight)
    let visibleRows = Int((contentHeight / rowHeight).rounded(.down))
    return max(minRows, visibleRows)
  }

  private func renderIfNeeded(cols: Int, rows: Int, transcript: String) {
    let signature = "\(cols):\(rows):\(transcript)"
    guard renderedSignature != signature else { return }
    renderedSignature = signature

    let nextSession = TerminalSessionController(
      terminalId: "tool-transcript-\(UUID().uuidString)",
      cols: UInt16(max(1, min(cols, Int(UInt16.max)))),
      rows: UInt16(max(1, min(rows, Int(UInt16.max))))
    )
    nextSession.sendToServer = { _ in }
    if !transcript.isEmpty {
      nextSession.feedOutput(Data(transcript.utf8))
    }
    session = nextSession
  }

  private func updateAvailableWidth(_ nextWidth: CGFloat) {
    let sanitized = max(1, nextWidth)
    guard abs(sanitized - availableWidth) > 0.5 else { return }
    availableWidth = sanitized
  }
}
