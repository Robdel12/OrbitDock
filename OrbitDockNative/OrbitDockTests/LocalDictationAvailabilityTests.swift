@testable import OrbitDock
import Testing

struct LocalDictationAvailabilityTests {
  @Test func resolvesAvailableWhenAppleSpeechIsSupported() {
    let availability = LocalDictationAvailabilityResolver.resolve(appleSpeechSupported: true)
    #expect(availability == .available)
  }

  @Test func resolvesUnavailableWhenAppleSpeechIsNotSupported() {
    let availability = LocalDictationAvailabilityResolver.resolve(appleSpeechSupported: false)
    #expect(availability == .unavailable)
  }
}
