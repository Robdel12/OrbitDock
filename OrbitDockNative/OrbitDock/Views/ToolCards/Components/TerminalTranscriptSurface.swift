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
  var maxScrollbackRows: Int = 10_000
  var showsTitleBar: Bool = true
  var captureScrollWithoutFocus: Bool = true

  @State private var session: TerminalSessionController?
  @State private var renderedFingerprint: RenderFingerprint?
  @State private var availableWidth: CGFloat = 0

  private let rowHeight: CGFloat = 17
  private let cellWidth: CGFloat = 8
  private let titleBarChromeHeight: CGFloat = 24
  private let minimumCols = 64
  private let maximumScrollableCols = 640
  private let horizontalInsets: CGFloat = 16

  private struct RenderState {
    let visibleHeight: CGFloat
    let renderRows: Int
  }

  private struct RenderFingerprint: Equatable {
    let cols: Int
    let rows: Int
    let byteCount: Int
    let hash: UInt64
  }

  private var normalizedOutput: String {
    String(decoding: normalizedTerminalBytes(for: output), as: UTF8.self)
  }

  var body: some View {
    let transcript = normalizedOutput
    let cleanTranscript = ANSIColorParser.stripANSI(transcript)
    let viewportWidth = max(availableWidth, 1)
    let viewportCols = estimatedCols(forWidth: viewportWidth)
    let contentCols = estimatedContentCols(forCleanText: cleanTranscript, minimum: viewportCols)
    let contentWidth = resolvedContentWidth(for: viewportWidth, cols: contentCols)
    let layoutState = renderState(forCleanText: cleanTranscript, cols: contentCols)

    ScrollView(.horizontal, showsIndicators: true) {
      Group {
        if let session {
          TerminalContainerView(
            session: session,
            shouldAutoFocusOnFirstAttachment: false,
            captureScrollWithoutFocus: captureScrollWithoutFocus,
            cursorBlinkEnabled: false,
            allowsInput: false,
            titleOverride: title,
            showsTitleBar: showsTitleBar
          )
        } else {
          Color.clear
        }
      }
      .frame(width: contentWidth, height: layoutState.visibleHeight, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: layoutState.visibleHeight, alignment: .topLeading)
    .background(widthProbe)
    .onAppear {
      renderTranscript(transcript, cleanTranscript: cleanTranscript, cols: contentCols)
    }
    .onChange(of: output) { _, _ in
      renderTranscript(transcript, cleanTranscript: cleanTranscript, cols: contentCols)
    }
    .onChange(of: contentCols) { _, nextCols in
      renderTranscript(transcript, cleanTranscript: cleanTranscript, cols: nextCols)
    }
    .accessibilityHidden(true)
  }

  private var minimumSurfaceHeight: CGFloat {
    titleBarHeight + rowHeight * CGFloat(max(1, minRows))
  }

  private var titleBarHeight: CGFloat {
    showsTitleBar ? titleBarChromeHeight : 0
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

  private func estimatedRows(forCleanText text: String, cols: Int) -> Int {
    let baseRows = text
      .components(separatedBy: "\n")
      .reduce(0) { partial, line in
        let lineLength = max(1, line.count)
        let wraps = max(1, Int(ceil(Double(lineLength) / Double(max(1, cols)))))
        return partial + wraps
      }
    return max(minRows, baseRows + 2)
  }

  private func estimatedContentCols(forCleanText text: String, minimum: Int) -> Int {
    let longestLine = text
      .components(separatedBy: "\n")
      .map(\.count)
      .max() ?? minimum

    return min(maximumScrollableCols, max(minimum, longestLine + 2))
  }

  private func renderState(forCleanText text: String, cols: Int) -> RenderState {
    let estimatedContentRows = estimatedRows(forCleanText: text, cols: cols)
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
    let fingerprint = renderFingerprint(cols: cols, rows: rows, transcript: transcript)
    guard renderedFingerprint != fingerprint else { return }
    renderedFingerprint = fingerprint

    session = makeSession(cols: cols, rows: rows, transcript: transcript)
  }

  private func renderTranscript(_ transcript: String, cleanTranscript: String, cols: Int) {
    let renderRows = renderState(forCleanText: cleanTranscript, cols: cols).renderRows
    renderIfNeeded(cols: cols, rows: renderRows, transcript: transcript)
  }

  private func makeSession(cols: Int, rows: Int, transcript: String) -> TerminalSessionController {
    let nextSession = TerminalSessionController(
      terminalId: "tool-transcript-\(UUID().uuidString)",
      cols: UInt16(max(1, min(cols, Int(UInt16.max)))),
      rows: UInt16(max(1, min(rows, Int(UInt16.max)))),
      maxScrollback: max(0, maxScrollbackRows)
    )
    nextSession.sendToServer = { _ in }
    if !transcript.isEmpty {
      nextSession.feedOutput(Data(transcript.utf8))
    }
    return nextSession
  }

  private func renderFingerprint(cols: Int, rows: Int, transcript: String) -> RenderFingerprint {
    var hash: UInt64 = 1_469_598_103_934_665_603
    var byteCount = 0
    for byte in transcript.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
      byteCount += 1
    }
    return RenderFingerprint(cols: cols, rows: rows, byteCount: byteCount, hash: hash)
  }

  private func updateAvailableWidth(_ nextWidth: CGFloat) {
    let sanitized = max(1, nextWidth)
    guard abs(sanitized - availableWidth) > 0.5 else { return }
    availableWidth = sanitized
  }

  private func normalizedTerminalBytes(for text: String) -> [UInt8] {
    var normalized: [UInt8] = []
    normalized.reserveCapacity(text.utf8.count)
    var lastByteWasCarriageReturn = false

    for byte in text.utf8 {
      if byte == 10 {
        if lastByteWasCarriageReturn {
          normalized.append(byte)
        } else {
          normalized.append(13)
          normalized.append(10)
        }
        lastByteWasCarriageReturn = false
      } else {
        normalized.append(byte)
        lastByteWasCarriageReturn = byte == 13
      }
    }

    return normalized
  }
}
