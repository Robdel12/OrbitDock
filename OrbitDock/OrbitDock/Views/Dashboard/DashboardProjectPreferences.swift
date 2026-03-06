import Foundation

enum DashboardProjectPreferences {
  private static let projectGroupOrderKey = "dashboard.projectGroupOrder.v1"
  private static let hiddenProjectGroupsKey = "dashboard.hiddenProjectGroups.v1"
  private static let useCustomProjectOrderKey = "dashboard.useCustomProjectOrder.v1"
  private static let sessionOrderByGroupKey = "dashboard.sessionOrderByGroup.v1"

  static func loadProjectGroupOrder(defaults: UserDefaults = .standard) -> [String] {
    defaults.stringArray(forKey: projectGroupOrderKey) ?? []
  }

  static func saveProjectGroupOrder(_ groupOrder: [String], defaults: UserDefaults = .standard) {
    if groupOrder.isEmpty {
      defaults.removeObject(forKey: projectGroupOrderKey)
      return
    }
    defaults.set(groupOrder, forKey: projectGroupOrderKey)
  }

  static func loadHiddenProjectGroups(defaults: UserDefaults = .standard) -> Set<String> {
    Set(defaults.stringArray(forKey: hiddenProjectGroupsKey) ?? [])
  }

  static func saveHiddenProjectGroups(_ hiddenGroupKeys: Set<String>, defaults: UserDefaults = .standard) {
    if hiddenGroupKeys.isEmpty {
      defaults.removeObject(forKey: hiddenProjectGroupsKey)
      return
    }
    defaults.set(hiddenGroupKeys.sorted(), forKey: hiddenProjectGroupsKey)
  }

  static func loadUseCustomProjectOrder(defaults: UserDefaults = .standard) -> Bool {
    if defaults.object(forKey: useCustomProjectOrderKey) == nil {
      let existingOrder = loadProjectGroupOrder(defaults: defaults)
      return !existingOrder.isEmpty
    }
    return defaults.bool(forKey: useCustomProjectOrderKey)
  }

  static func saveUseCustomProjectOrder(_ useCustomProjectOrder: Bool, defaults: UserDefaults = .standard) {
    defaults.set(useCustomProjectOrder, forKey: useCustomProjectOrderKey)
  }

  static func loadSessionOrderByGroup(defaults: UserDefaults = .standard) -> [String: [String]] {
    defaults.dictionary(forKey: sessionOrderByGroupKey) as? [String: [String]] ?? [:]
  }

  static func saveSessionOrderByGroup(_ orderByGroup: [String: [String]], defaults: UserDefaults = .standard) {
    if orderByGroup.isEmpty {
      defaults.removeObject(forKey: sessionOrderByGroupKey)
      return
    }
    defaults.set(orderByGroup, forKey: sessionOrderByGroupKey)
  }
}
