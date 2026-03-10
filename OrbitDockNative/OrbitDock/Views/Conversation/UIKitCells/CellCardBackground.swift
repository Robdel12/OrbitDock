//
//  CellCardBackground.swift
//  OrbitDock
//
//  Lightweight helper that manages a CALayer card background for iOS
//  UICollectionViewCells, matching macOS CardTableRowView behavior.
//  Card-eligible cells own an instance and forward layout/configure/reset calls.
//

#if os(iOS)

  import UIKit

  final class CellCardBackground {
    private let cardLayer = CALayer()
    private var position: CardPosition = .none
    private var topInset: CGFloat = 0
    private var bottomInset: CGFloat = 0

    private let hInset = ConversationLayout.cardHorizontalInset
    private let cornerRadius = ConversationLayout.cardCornerRadius

    func install(in view: UIView) {
      cardLayer.backgroundColor = UIColor.white.withAlphaComponent(0.04).cgColor
      cardLayer.isHidden = true
      view.layer.insertSublayer(cardLayer, at: 0)
    }

    func configure(position: CardPosition, topInset: CGFloat, bottomInset: CGFloat) {
      self.position = position
      self.topInset = topInset
      self.bottomInset = bottomInset

      let visible = position != .none
      cardLayer.isHidden = !visible
      guard visible else { return }
      updateCorners()
    }

    func layoutInBounds(_ bounds: CGRect) {
      guard !cardLayer.isHidden else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      cardLayer.frame = CGRect(
        x: hInset,
        y: topInset,
        width: bounds.width - hInset * 2,
        height: bounds.height - topInset - bottomInset
      )
      CATransaction.commit()
    }

    func reset() {
      position = .none
      topInset = 0
      bottomInset = 0
      cardLayer.isHidden = true
    }

    private func updateCorners() {
      switch position {
        case .solo:
          cardLayer.cornerRadius = cornerRadius
          cardLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                     .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .top:
          cardLayer.cornerRadius = cornerRadius
          cardLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .bottom:
          cardLayer.cornerRadius = cornerRadius
          cardLayer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .middle:
          cardLayer.cornerRadius = 0
          cardLayer.maskedCorners = []
        case .none:
          cardLayer.cornerRadius = 0
          cardLayer.maskedCorners = []
      }
    }
  }

#endif
