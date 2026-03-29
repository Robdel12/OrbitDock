#if os(iOS)
  import GhosttyVT
  import UIKit

  /// Keyboard accessory bar for the terminal with special keys that don't
  /// exist on the iOS software keyboard: Esc, Tab, Ctrl, Alt, pipe, tilde,
  /// and arrow keys.
  ///
  /// Ctrl and Alt are toggle modifiers — tap to engage, and the next
  /// key press (from the software keyboard) includes that modifier.
  final class TerminalAccessoryBar: UIView {
    private weak var terminalView: TerminalUIView?

    private var ctrlButton: AccessoryKeyButton!
    private var altButton: AccessoryKeyButton!

    private var ctrlActive = false
    private var altActive = false

    // MARK: - Init

    init(terminalView: TerminalUIView) {
      self.terminalView = terminalView
      // inputAccessoryView requires an explicit frame height — intrinsicContentSize
      // alone is not enough on all iOS versions.
      super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
      autoresizingMask = .flexibleWidth
      setupBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
      CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    // MARK: - Setup

    private func setupBar() {
      // Match terminal background
      backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.075, alpha: 1.0)

      // Top border
      let border = UIView()
      border.backgroundColor = UIColor.white.withAlphaComponent(0.08)
      border.translatesAutoresizingMaskIntoConstraints = false
      addSubview(border)
      NSLayoutConstraint.activate([
        border.topAnchor.constraint(equalTo: topAnchor),
        border.leadingAnchor.constraint(equalTo: leadingAnchor),
        border.trailingAnchor.constraint(equalTo: trailingAnchor),
        border.heightAnchor.constraint(equalToConstant: 0.5),
      ])

      let scrollView = UIScrollView()
      scrollView.showsHorizontalScrollIndicator = false
      scrollView.alwaysBounceHorizontal = true
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(scrollView)
      NSLayoutConstraint.activate([
        scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])

      let stack = UIStackView()
      stack.axis = .horizontal
      stack.spacing = 6
      stack.alignment = .center
      stack.translatesAutoresizingMaskIntoConstraints = false
      scrollView.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
        stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 8),
        stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -8),
        stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
      ])

      // Build keys
      let escButton = makeKey("Esc") { [weak self] in self?.sendKey(GHOSTTY_KEY_ESCAPE) }
      let tabButton = makeKey("Tab") { [weak self] in self?.sendKey(GHOSTTY_KEY_TAB, text: "\t") }

      ctrlButton = makeKey("Ctrl") { [weak self] in self?.toggleCtrl() }
      altButton = makeKey("Alt") { [weak self] in self?.toggleAlt() }

      let pipeButton = makeKey("|") { [weak self] in self?.sendCharacter("|") }
      let tildeButton = makeKey("~") { [weak self] in self?.sendCharacter("~") }
      let dashButton = makeKey("-") { [weak self] in self?.sendCharacter("-") }
      let slashButton = makeKey("/") { [weak self] in self?.sendCharacter("/") }

      let leftButton = makeArrowKey("chevron.left") { [weak self] in self?.sendKey(GHOSTTY_KEY_ARROW_LEFT) }
      let rightButton = makeArrowKey("chevron.right") { [weak self] in self?.sendKey(GHOSTTY_KEY_ARROW_RIGHT) }
      let upButton = makeArrowKey("chevron.up") { [weak self] in self?.sendKey(GHOSTTY_KEY_ARROW_UP) }
      let downButton = makeArrowKey("chevron.down") { [weak self] in self?.sendKey(GHOSTTY_KEY_ARROW_DOWN) }

      let keys: [UIView] = [
        escButton, tabButton,
        makeSeparator(),
        ctrlButton, altButton,
        makeSeparator(),
        pipeButton, tildeButton, dashButton, slashButton,
        makeSeparator(),
        leftButton, downButton, upButton, rightButton,
      ]

      for key in keys {
        stack.addArrangedSubview(key)
      }
    }

    // MARK: - Key Factories

    private func makeKey(_ title: String, action: @escaping () -> Void) -> AccessoryKeyButton {
      let button = AccessoryKeyButton(action: action)
      button.setTitle(title, for: .normal)
      button.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
      button.setTitleColor(UIColor.white.withAlphaComponent(0.75), for: .normal)
      button.setTitleColor(UIColor.white, for: .highlighted)
      button.backgroundColor = UIColor.white.withAlphaComponent(0.06)
      button.layer.cornerRadius = 6
      button.layer.cornerCurve = .continuous
      button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.heightAnchor.constraint(equalToConstant: 34).isActive = true
      return button
    }

    private func makeArrowKey(_ systemImage: String, action: @escaping () -> Void) -> AccessoryKeyButton {
      let button = AccessoryKeyButton(action: action)
      let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
      button.setImage(UIImage(systemName: systemImage, withConfiguration: config), for: .normal)
      button.tintColor = UIColor.white.withAlphaComponent(0.75)
      button.backgroundColor = UIColor.white.withAlphaComponent(0.06)
      button.layer.cornerRadius = 6
      button.layer.cornerCurve = .continuous
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 38),
        button.heightAnchor.constraint(equalToConstant: 34),
      ])
      return button
    }

    private func makeSeparator() -> UIView {
      let sep = UIView()
      sep.backgroundColor = UIColor.white.withAlphaComponent(0.08)
      sep.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        sep.widthAnchor.constraint(equalToConstant: 0.5),
        sep.heightAnchor.constraint(equalToConstant: 20),
      ])
      return sep
    }

    // MARK: - Actions

    private func sendKey(_ key: GhosttyKey, text: String? = nil) {
      terminalView?.sendSpecialKey(key, text: text)
    }

    private func sendCharacter(_ char: String) {
      terminalView?.insertText(char)
    }

    private func toggleCtrl() {
      ctrlActive.toggle()
      updateModifierState()
      updateToggleAppearance(ctrlButton, active: ctrlActive)
    }

    private func toggleAlt() {
      altActive.toggle()
      updateModifierState()
      updateToggleAppearance(altButton, active: altActive)
    }

    private func updateModifierState() {
      var mods: GhosttyMods = 0
      if ctrlActive { mods |= UInt16(GHOSTTY_MODS_CTRL) }
      if altActive { mods |= UInt16(GHOSTTY_MODS_ALT) }
      terminalView?.pendingModifiers = mods
    }

    private func updateToggleAppearance(_ button: AccessoryKeyButton, active: Bool) {
      // Terminal green accent when active
      let activeColor = UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1.0)
      UIView.animate(withDuration: 0.15) {
        button.backgroundColor = active
          ? activeColor.withAlphaComponent(0.2)
          : UIColor.white.withAlphaComponent(0.06)
        button.setTitleColor(
          active ? activeColor : UIColor.white.withAlphaComponent(0.75),
          for: .normal
        )
        button.layer.borderWidth = active ? 1 : 0
        button.layer.borderColor = active ? activeColor.withAlphaComponent(0.4).cgColor : nil
      }
    }

    /// Called by TerminalUIView after consuming modifiers to reset toggle state.
    func clearModifiers() {
      guard ctrlActive || altActive else { return }
      ctrlActive = false
      altActive = false
      updateToggleAppearance(ctrlButton, active: false)
      updateToggleAppearance(altButton, active: false)
    }
  }

  // MARK: - AccessoryKeyButton

  /// Simple button subclass that holds an action closure and provides
  /// haptic feedback on touch.
  final class AccessoryKeyButton: UIButton {
    private let onTap: () -> Void
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    init(action: @escaping () -> Void) {
      self.onTap = action
      super.init(frame: .zero)
      addTarget(self, action: #selector(handleTap), for: .touchUpInside)
      feedbackGenerator.prepare()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    @objc private func handleTap() {
      feedbackGenerator.impactOccurred()
      onTap()
    }

    override var isHighlighted: Bool {
      didSet {
        alpha = isHighlighted ? 0.6 : 1.0
      }
    }
  }
#endif
