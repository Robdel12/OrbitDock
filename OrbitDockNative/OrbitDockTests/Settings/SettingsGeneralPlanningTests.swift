@testable import OrbitDock
import Testing

@MainActor
struct SettingsGeneralPlanningTests {
  @Test func availableLocalNamingPresentationShowsOnDeviceStatus() {
    let presentation = SettingsGeneralPlanning.localNamingPresentation(availability: .available)

    #expect(presentation.title == "Apple Foundation Models")
    #expect(presentation.iconName == "apple.logo")
    #expect(presentation.statusText == "On-device naming available")
    #expect(presentation.showsOnDeviceBadge)
  }

  @Test func unavailableLocalNamingPresentationUsesFallbackCopy() {
    let presentation = SettingsGeneralPlanning.localNamingPresentation(availability: .unavailable)

    #expect(presentation.title == "Foundation Models unavailable")
    #expect(presentation.iconName == "xmark.circle.fill")
    #expect(presentation.statusText == "Using saved titles and prompt fallback")
    #expect(!presentation.showsOnDeviceBadge)
  }

  @Test func unavailableDictationPresentationUsesFallbackCopy() {
    let presentation = SettingsGeneralPlanning.dictationPresentation(availability: .unavailable)

    #expect(presentation.title == "Dictation unavailable")
    #expect(presentation.iconName == "xmark.circle.fill")
    #expect(!presentation.showsLiveBadge)
  }
}
