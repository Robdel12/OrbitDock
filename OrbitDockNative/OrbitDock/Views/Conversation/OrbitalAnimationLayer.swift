//
//  OrbitalAnimationLayer.swift
//  OrbitDock
//
//  Binary Star docking animation for live indicator cells.
//  Two tiny luminous dots orbit each other in a tight circle —
//  like two vessels in a docking approach. Subtle, fun, on-brand.
//
//  All animations are CABasicAnimation / CAKeyframeAnimation which run
//  on Core Animation's render server — zero main-thread CPU cost.
//
//  Cross-platform: uses only QuartzCore types.
//

import QuartzCore

final class OrbitalAnimationLayer: CALayer {

  // MARK: - State

  enum OrbitalState {
    case orbiting
    case holding
    case parked
    case hidden
  }

  private(set) var currentState: OrbitalState = .hidden

  // MARK: - Sublayers

  private let container = CALayer()
  private let dotA = CALayer()
  private let dotB = CALayer()
  private let glowLayer = CALayer()

  // MARK: - Geometry

  private let dotSize: CGFloat = 2.5
  private let orbitRadius: CGFloat = 4
  private let glowSize: CGFloat = 12

  // MARK: - Animation Keys

  private enum AnimKey {
    static let orbitA = "orbital.orbitA"
    static let orbitB = "orbital.orbitB"
    static let pulse = "orbital.pulse"
    static let breathe = "orbital.breathe"
    static let breatheGlow = "orbital.breatheGlow"
  }

  // MARK: - Init

  override init() {
    super.init()
    buildSublayers()
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    buildSublayers()
  }

  // MARK: - Build Layer Hierarchy

  private func buildSublayers() {
    glowLayer.bounds = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
    glowLayer.cornerRadius = glowSize / 2
    glowLayer.opacity = 0
    container.addSublayer(glowLayer)

    dotA.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
    dotA.cornerRadius = dotSize / 2
    dotA.shadowOffset = .zero
    dotA.shadowRadius = 2
    dotA.shadowOpacity = 0.5
    container.addSublayer(dotA)

    dotB.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
    dotB.cornerRadius = dotSize / 2
    dotB.shadowOffset = .zero
    dotB.shadowRadius = 2
    dotB.shadowOpacity = 0.5
    container.addSublayer(dotB)

    container.opacity = 0
    addSublayer(container)
  }

  // MARK: - Public API

  func configure(state: OrbitalState, color: CGColor, secondaryColor: CGColor? = nil) {
    let previousState = currentState
    currentState = state

    removeAllOrbitalAnimations()

    CATransaction.begin()
    CATransaction.setAnimationDuration(previousState == .hidden ? 0.0 : 0.3)

    applyColors(primary: color, secondary: secondaryColor ?? color)

    switch state {
      case .orbiting:
        showOrbiting()
      case .holding:
        showHolding()
      case .parked:
        showParked()
      case .hidden:
        hideAll()
    }

    CATransaction.commit()
  }

  func removeAllOrbitalAnimations() {
    container.removeAllAnimations()
    dotA.removeAllAnimations()
    dotB.removeAllAnimations()
    glowLayer.removeAllAnimations()
  }

  // MARK: - Layout

  override func layoutSublayers() {
    super.layoutSublayers()
    guard bounds.width > 0 else { return }

    container.frame = bounds

    let orbitCenter = CGPoint(x: bounds.midX, y: bounds.midY)
    glowLayer.position = orbitCenter

    if currentState == .orbiting {
      startOrbitAnimations(center: orbitCenter, period: 2.0)
    } else if currentState == .holding {
      positionPairAt(orbitCenter, offset: orbitRadius * 0.5)
      startOrbitAnimations(center: orbitCenter, period: 3.0)
    } else if currentState == .parked {
      positionPairAt(orbitCenter, offset: 1.5)
    }
  }

  // MARK: - Color

  private func applyColors(primary: CGColor, secondary: CGColor) {
    dotA.backgroundColor = primary
    dotA.shadowColor = primary
    dotB.backgroundColor = secondary
    dotB.shadowColor = secondary
    glowLayer.backgroundColor = primary.copy(alpha: 0.1)
  }

  // MARK: - Orbiting State (Working)

  private func showOrbiting() {
    container.opacity = 1.0
    glowLayer.opacity = 0.4

    let orbitCenter = CGPoint(x: bounds.midX, y: bounds.midY)
    startOrbitAnimations(center: orbitCenter, period: 2.0)
  }

  private func startOrbitAnimations(center: CGPoint, period: CFTimeInterval) {
    dotA.removeAnimation(forKey: AnimKey.orbitA)
    dotB.removeAnimation(forKey: AnimKey.orbitB)

    let r = orbitRadius

    let path = CGMutablePath()
    path.addEllipse(in: CGRect(
      x: center.x - r, y: center.y - r,
      width: r * 2, height: r * 2
    ))

    let orbitA = CAKeyframeAnimation(keyPath: "position")
    orbitA.path = path
    orbitA.duration = period
    orbitA.repeatCount = .infinity
    orbitA.calculationMode = .paced
    orbitA.isRemovedOnCompletion = false
    orbitA.fillMode = .forwards
    dotA.add(orbitA, forKey: AnimKey.orbitA)

    let orbitB = CAKeyframeAnimation(keyPath: "position")
    orbitB.path = path
    orbitB.duration = period
    orbitB.repeatCount = .infinity
    orbitB.calculationMode = .paced
    orbitB.isRemovedOnCompletion = false
    orbitB.fillMode = .forwards
    orbitB.timeOffset = period / 2
    dotB.add(orbitB, forKey: AnimKey.orbitB)

    glowLayer.position = center
  }

  // MARK: - Holding State (Permission)

  private func showHolding() {
    container.opacity = 1.0
    glowLayer.opacity = 0.5

    let orbitCenter = CGPoint(x: bounds.midX, y: bounds.midY)
    startOrbitAnimations(center: orbitCenter, period: 3.0)

    let pulse = CABasicAnimation(keyPath: "opacity")
    pulse.fromValue = 0.6
    pulse.toValue = 1.0
    pulse.duration = 1.5
    pulse.autoreverses = true
    pulse.repeatCount = .infinity
    pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    dotA.add(pulse, forKey: AnimKey.pulse)
    dotB.add(pulse, forKey: AnimKey.pulse)

    let glowPulse = CABasicAnimation(keyPath: "opacity")
    glowPulse.fromValue = 0.3
    glowPulse.toValue = 0.6
    glowPulse.duration = 1.5
    glowPulse.autoreverses = true
    glowPulse.repeatCount = .infinity
    glowPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    glowLayer.add(glowPulse, forKey: AnimKey.pulse)
  }

  // MARK: - Parked State (Waiting/Reply)

  private func showParked() {
    container.opacity = 1.0
    glowLayer.opacity = 0.3

    let orbitCenter = CGPoint(x: bounds.midX, y: bounds.midY)
    positionPairAt(orbitCenter, offset: 1.5)

    let breatheGlow = CABasicAnimation(keyPath: "opacity")
    breatheGlow.fromValue = 0.2
    breatheGlow.toValue = 0.5
    breatheGlow.duration = 3.0
    breatheGlow.autoreverses = true
    breatheGlow.repeatCount = .infinity
    breatheGlow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    glowLayer.add(breatheGlow, forKey: AnimKey.breatheGlow)

    let breathe = CABasicAnimation(keyPath: "transform.scale")
    breathe.fromValue = 0.9
    breathe.toValue = 1.15
    breathe.duration = 3.0
    breathe.autoreverses = true
    breathe.repeatCount = .infinity
    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    dotA.add(breathe, forKey: AnimKey.breathe)
    dotB.add(breathe, forKey: AnimKey.breathe)
  }

  // MARK: - Hidden (static single dot at center)

  private func hideAll() {
    container.opacity = 1.0
    glowLayer.opacity = 0

    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    dotA.position = center
    dotA.opacity = 0.4
    dotB.position = center
    dotB.opacity = 0
  }

  // MARK: - Helpers

  private func positionPairAt(_ center: CGPoint, offset: CGFloat) {
    dotA.position = CGPoint(x: center.x - offset, y: center.y)
    dotB.position = CGPoint(x: center.x + offset, y: center.y)
    glowLayer.position = center
  }
}
