import Testing
@testable import OrbitDock

@MainActor
struct SettingsGeneralPlanningTests {
  @Test func configuredNamingPresentationShowsEncryptedStoredKey() {
    let presentation = SettingsGeneralPlanning.openAiNamingPresentation(
      status: .configured,
      isReplacingKey: false,
      keySaved: false
    )

    #expect(presentation.statusText == "API key configured")
    #expect(presentation.statusTone == .positive)
    #expect(presentation.showsEncryptedBadge)
    #expect(presentation.showsStoredKey)
    #expect(!presentation.showsProgress)
  }

  @Test func replacingNamingPresentationUsesEditingCopy() {
    let presentation = SettingsGeneralPlanning.openAiNamingPresentation(
      status: .configured,
      isReplacingKey: true,
      keySaved: true
    )

    #expect(presentation.introCopy == "Enter a new key to replace the existing one.")
    #expect(!presentation.showsStoredKey)
    #expect(presentation.showsSavedMessage)
  }

  @Test func unavailableDictationPresentationUsesFallbackCopy() {
    let presentation = SettingsGeneralPlanning.dictationPresentation(availability: .unavailable)

    #expect(presentation.title == "Dictation unavailable")
    #expect(presentation.iconName == "xmark.circle.fill")
    #expect(!presentation.showsLiveBadge)
  }
}
