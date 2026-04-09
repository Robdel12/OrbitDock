import Foundation

struct SessionPresetStore {
  static let storageKey = "orbitdock.session.presets"

  private let defaults: UserDefaults
  private let key: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(defaults: UserDefaults = .standard, key: String = Self.storageKey) {
    self.defaults = defaults
    self.key = key
  }

  func presets() -> [SessionPreset] {
    guard let data = defaults.data(forKey: key) else { return [] }
    guard let wrapper = try? decoder.decode([SafeDecodable<SessionPreset>].self, from: data) else { return [] }
    return wrapper.compactMap(\.value)
  }

  func presets(for provider: SessionProvider) -> [SessionPreset] {
    presets().filter { $0.provider == provider }
  }

  func save(_ preset: SessionPreset) {
    var all = presets()
    if let index = all.firstIndex(where: { $0.id == preset.id }) {
      all[index] = preset
    } else {
      all.append(preset)
    }
    write(all)
  }

  func remove(id: UUID) {
    var all = presets()
    all.removeAll { $0.id == id }
    write(all)
  }

  private func write(_ presets: [SessionPreset]) {
    guard let data = try? encoder.encode(presets) else { return }
    defaults.set(data, forKey: key)
  }
}

private struct SafeDecodable<T: Decodable>: Decodable {
  let value: T?

  init(from decoder: Decoder) throws {
    value = try? T(from: decoder)
  }
}
