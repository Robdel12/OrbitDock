//
//  TimelineUserScrollDetector.swift
//  OrbitDock
//
//  Detects user-initiated scroll gestures on the enclosing platform scroll view.
//
//  macOS: NSScrollView.willStartLiveScrollNotification / didEndLiveScrollNotification
//         fire exclusively for user-initiated scroll (trackpad, mouse wheel) — never
//         for programmatic scrollTo calls or content size changes.
//
//  iOS:   Tracks the UIScrollView pan gesture recognizer state and deceleration
//         to cover the full drag + momentum lifecycle.
//

import SwiftUI

#if os(macOS)
  import AppKit

  struct TimelineUserScrollDetector: NSViewRepresentable {
    @Binding var isUserScrolling: Bool

    func makeNSView(context: Context) -> ScrollDetectorNSView {
      ScrollDetectorNSView(isUserScrolling: $isUserScrolling)
    }

    func updateNSView(_ nsView: ScrollDetectorNSView, context: Context) {}
  }

  final class ScrollDetectorNSView: NSView {
    private let isUserScrolling: Binding<Bool>

    init(isUserScrolling: Binding<Bool>) {
      self.isUserScrolling = isUserScrolling
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      guard let scrollView = enclosingScrollView else { return }

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(liveScrollStarted),
        name: NSScrollView.willStartLiveScrollNotification,
        object: scrollView
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(liveScrollEnded),
        name: NSScrollView.didEndLiveScrollNotification,
        object: scrollView
      )
    }

    @objc private func liveScrollStarted() {
      isUserScrolling.wrappedValue = true
    }

    @objc private func liveScrollEnded() {
      isUserScrolling.wrappedValue = false
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }
  }

#else
  import UIKit

  struct TimelineUserScrollDetector: UIViewRepresentable {
    @Binding var isUserScrolling: Bool

    func makeUIView(context: Context) -> ScrollDetectorUIView {
      ScrollDetectorUIView(isUserScrolling: $isUserScrolling)
    }

    func updateUIView(_ uiView: ScrollDetectorUIView, context: Context) {}
  }

  final class ScrollDetectorUIView: UIView {
    var isUserScrolling: Binding<Bool>
    private var panObservation: NSKeyValueObservation?
    private var decelerationObservation: NSKeyValueObservation?

    init(isUserScrolling: Binding<Bool>) {
      self.isUserScrolling = isUserScrolling
      super.init(frame: .zero)
      isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      panObservation = nil
      decelerationObservation = nil
      guard window != nil else { return }
      guard let scrollView = findScrollView() else { return }

      panObservation = scrollView.panGestureRecognizer.observe(\.state) { [weak self] rec, _ in
        MainActor.assumeIsolated {
          self?.handlePanState(rec)
        }
      }
    }

    private func handlePanState(_ recognizer: UIPanGestureRecognizer) {
      switch recognizer.state {
        case .began, .changed:
          decelerationObservation = nil
          isUserScrolling.wrappedValue = true

        case .ended:
          guard let scrollView = recognizer.view as? UIScrollView else {
            isUserScrolling.wrappedValue = false
            return
          }
          // Track deceleration (momentum) — keep isUserScrolling true until it settles
          decelerationObservation = scrollView.observe(\.contentOffset) { [weak self] sv, _ in
            guard !sv.isDecelerating else { return }
            MainActor.assumeIsolated {
              self?.decelerationObservation = nil
              self?.isUserScrolling.wrappedValue = false
            }
          }

        case .cancelled, .failed:
          decelerationObservation = nil
          isUserScrolling.wrappedValue = false

        default:
          break
      }
    }

    private func findScrollView() -> UIScrollView? {
      var view: UIView? = superview
      while let v = view {
        if let sv = v as? UIScrollView { return sv }
        view = v.superview
      }
      return nil
    }
  }
#endif
