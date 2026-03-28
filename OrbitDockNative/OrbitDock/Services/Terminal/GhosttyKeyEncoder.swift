import Foundation
import GhosttyVT

#if os(macOS)
import AppKit
#endif

/// Wraps libghostty-vt's key encoder to convert keyboard events into VT escape sequences.
final class GhosttyKeyEncoderWrapper {
  private var encoder: GhosttyKeyEncoder!
  private var event: GhosttyKeyEvent!

  init() {
    var enc: GhosttyKeyEncoder?
    let encResult = ghostty_key_encoder_new(nil, &enc)
    guard encResult == GHOSTTY_SUCCESS, let enc else {
      fatalError("Failed to create ghostty key encoder: \(encResult)")
    }
    self.encoder = enc

    var evt: GhosttyKeyEvent?
    let evtResult = ghostty_key_event_new(nil, &evt)
    guard evtResult == GHOSTTY_SUCCESS, let evt else {
      fatalError("Failed to create ghostty key event: \(evtResult)")
    }
    self.event = evt

    // Default: treat Option as Alt on macOS.
    var optAsAlt = GHOSTTY_OPTION_AS_ALT_TRUE
    ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optAsAlt)
  }

  deinit {
    ghostty_key_event_free(event)
    ghostty_key_encoder_free(encoder)
  }

  /// Sync encoder options from a terminal's current state (cursor key mode, Kitty flags, etc.)
  func syncFromTerminal(_ terminal: GhosttyTerminal) {
    ghostty_key_encoder_setopt_from_terminal(encoder, terminal)

    // Re-apply option-as-alt after syncing (terminal sync resets it).
    var optAsAlt = GHOSTTY_OPTION_AS_ALT_TRUE
    ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optAsAlt)
  }

  /// Encode a key event into VT escape sequence bytes.
  /// Returns nil if the event produces no output (e.g. bare modifier press).
  func encode(
    key: GhosttyKey,
    action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS,
    mods: GhosttyMods = 0,
    text: String? = nil
  ) -> Data? {
    ghostty_key_event_set_key(event, key)
    ghostty_key_event_set_action(event, action)
    ghostty_key_event_set_mods(event, mods)

    // The text pointer must remain valid through ghostty_key_encoder_encode,
    // so the encode call must happen inside withCString's scope.
    var buf = [CChar](repeating: 0, count: 128)
    var written: Int = 0

    if let text, !text.isEmpty {
      let ok: Bool = text.withCString { cStr in
        ghostty_key_event_set_utf8(event, cStr, strlen(cStr))
        return ghostty_key_encoder_encode(encoder, event, &buf, buf.count, &written) == GHOSTTY_SUCCESS
      }
      guard ok, written > 0 else { return nil }
    } else {
      ghostty_key_event_set_utf8(event, nil, 0)
      let result = ghostty_key_encoder_encode(encoder, event, &buf, buf.count, &written)
      guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
    }

    return Data(bytes: buf, count: written)
  }

  #if os(macOS)
  /// Encode an NSEvent key event into VT escape sequence bytes.
  func encode(nsEvent: NSEvent) -> Data? {
    let ghosttyKey = mapNSEventKeyCode(nsEvent.keyCode)
    let mods = mapNSEventModifiers(nsEvent.modifierFlags)
    let action: GhosttyKeyAction = nsEvent.type == .keyUp ? GHOSTTY_KEY_ACTION_RELEASE : GHOSTTY_KEY_ACTION_PRESS

    let text: String?
    if nsEvent.type == .keyDown, let chars = nsEvent.characters, !chars.isEmpty {
      text = chars
    } else {
      text = nil
    }

    return encode(key: ghosttyKey, action: action, mods: mods, text: text)
  }
  #endif
}

// MARK: - macOS Key Mapping

#if os(macOS)
/// Map macOS keyCode to GhosttyKey.
private func mapNSEventKeyCode(_ keyCode: UInt16) -> GhosttyKey {
  switch keyCode {
  case 0: return GHOSTTY_KEY_A
  case 1: return GHOSTTY_KEY_S
  case 2: return GHOSTTY_KEY_D
  case 3: return GHOSTTY_KEY_F
  case 4: return GHOSTTY_KEY_H
  case 5: return GHOSTTY_KEY_G
  case 6: return GHOSTTY_KEY_Z
  case 7: return GHOSTTY_KEY_X
  case 8: return GHOSTTY_KEY_C
  case 9: return GHOSTTY_KEY_V
  case 11: return GHOSTTY_KEY_B
  case 12: return GHOSTTY_KEY_Q
  case 13: return GHOSTTY_KEY_W
  case 14: return GHOSTTY_KEY_E
  case 15: return GHOSTTY_KEY_R
  case 16: return GHOSTTY_KEY_Y
  case 17: return GHOSTTY_KEY_T
  case 18: return GHOSTTY_KEY_DIGIT_1
  case 19: return GHOSTTY_KEY_DIGIT_2
  case 20: return GHOSTTY_KEY_DIGIT_3
  case 21: return GHOSTTY_KEY_DIGIT_4
  case 22: return GHOSTTY_KEY_DIGIT_6
  case 23: return GHOSTTY_KEY_DIGIT_5
  case 24: return GHOSTTY_KEY_EQUAL
  case 25: return GHOSTTY_KEY_DIGIT_9
  case 26: return GHOSTTY_KEY_DIGIT_7
  case 27: return GHOSTTY_KEY_MINUS
  case 28: return GHOSTTY_KEY_DIGIT_8
  case 29: return GHOSTTY_KEY_DIGIT_0
  case 30: return GHOSTTY_KEY_BRACKET_RIGHT
  case 31: return GHOSTTY_KEY_O
  case 32: return GHOSTTY_KEY_U
  case 33: return GHOSTTY_KEY_BRACKET_LEFT
  case 34: return GHOSTTY_KEY_I
  case 35: return GHOSTTY_KEY_P
  case 36: return GHOSTTY_KEY_ENTER
  case 37: return GHOSTTY_KEY_L
  case 38: return GHOSTTY_KEY_J
  case 39: return GHOSTTY_KEY_QUOTE
  case 40: return GHOSTTY_KEY_K
  case 41: return GHOSTTY_KEY_SEMICOLON
  case 42: return GHOSTTY_KEY_BACKSLASH
  case 43: return GHOSTTY_KEY_COMMA
  case 44: return GHOSTTY_KEY_SLASH
  case 45: return GHOSTTY_KEY_N
  case 46: return GHOSTTY_KEY_M
  case 47: return GHOSTTY_KEY_PERIOD
  case 48: return GHOSTTY_KEY_TAB
  case 49: return GHOSTTY_KEY_SPACE
  case 50: return GHOSTTY_KEY_BACKQUOTE
  case 51: return GHOSTTY_KEY_BACKSPACE
  case 53: return GHOSTTY_KEY_ESCAPE
  case 76: return GHOSTTY_KEY_ENTER
  case 96: return GHOSTTY_KEY_F5
  case 97: return GHOSTTY_KEY_F6
  case 98: return GHOSTTY_KEY_F7
  case 99: return GHOSTTY_KEY_F3
  case 100: return GHOSTTY_KEY_F8
  case 101: return GHOSTTY_KEY_F9
  case 109: return GHOSTTY_KEY_F10
  case 103: return GHOSTTY_KEY_F11
  case 111: return GHOSTTY_KEY_F12
  case 105: return GHOSTTY_KEY_F13
  case 107: return GHOSTTY_KEY_F14
  case 113: return GHOSTTY_KEY_F15
  case 120: return GHOSTTY_KEY_F2
  case 122: return GHOSTTY_KEY_F1
  case 118: return GHOSTTY_KEY_F4
  case 114: return GHOSTTY_KEY_INSERT
  case 115: return GHOSTTY_KEY_HOME
  case 116: return GHOSTTY_KEY_PAGE_UP
  case 117: return GHOSTTY_KEY_DELETE
  case 119: return GHOSTTY_KEY_END
  case 121: return GHOSTTY_KEY_PAGE_DOWN
  case 123: return GHOSTTY_KEY_ARROW_LEFT
  case 124: return GHOSTTY_KEY_ARROW_RIGHT
  case 125: return GHOSTTY_KEY_ARROW_DOWN
  case 126: return GHOSTTY_KEY_ARROW_UP
  default: return GHOSTTY_KEY_UNIDENTIFIED
  }
}

/// Map NSEvent modifier flags to GhosttyMods bitmask.
private func mapNSEventModifiers(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
  var mods: GhosttyMods = 0
  if flags.contains(.shift) { mods |= UInt16(GHOSTTY_MODS_SHIFT) }
  if flags.contains(.control) { mods |= UInt16(GHOSTTY_MODS_CTRL) }
  if flags.contains(.option) { mods |= UInt16(GHOSTTY_MODS_ALT) }
  if flags.contains(.command) { mods |= UInt16(GHOSTTY_MODS_SUPER) }
  if flags.contains(.capsLock) { mods |= UInt16(GHOSTTY_MODS_CAPS_LOCK) }
  return mods
}
#endif
