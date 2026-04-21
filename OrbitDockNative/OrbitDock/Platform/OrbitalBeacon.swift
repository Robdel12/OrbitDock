import SwiftUI

#if os(macOS)
  import AppKit

  final class OrbitalHostView: NSView {
    let orbital = OrbitalAnimationLayer()

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      orbital.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
      layer?.addSublayer(orbital)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError()
    }

    override func layout() {
      super.layout()
      orbital.frame = bounds
    }
  }

  struct OrbitalBeacon: NSViewRepresentable {
    let state: OrbitalAnimationLayer.OrbitalState
    let color: Color

    func makeNSView(context: Context) -> OrbitalHostView {
      OrbitalHostView()
    }

    func updateNSView(_ nsView: OrbitalHostView, context: Context) {
      let cgColor = NSColor(color).cgColor
      let secondaryColor = NSColor(Color.composerSteer).cgColor
      nsView.orbital.configure(
        state: state,
        color: cgColor,
        secondaryColor: state == .orbiting ? secondaryColor : nil
      )
    }
  }
#else
  import UIKit

  final class OrbitalHostView: UIView {
    let orbital = OrbitalAnimationLayer()

    override init(frame: CGRect) {
      super.init(frame: frame)
      orbital.contentsScale = UIScreen.main.scale
      layer.addSublayer(orbital)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      orbital.frame = bounds
    }
  }

  struct OrbitalBeacon: UIViewRepresentable {
    let state: OrbitalAnimationLayer.OrbitalState
    let color: Color

    func makeUIView(context: Context) -> OrbitalHostView {
      OrbitalHostView()
    }

    func updateUIView(_ uiView: OrbitalHostView, context: Context) {
      let cgColor = UIColor(color).cgColor
      let secondaryColor = UIColor(Color.composerSteer).cgColor
      uiView.orbital.configure(
        state: state,
        color: cgColor,
        secondaryColor: state == .orbiting ? secondaryColor : nil
      )
    }
  }
#endif
