@testable import OrbitDock
import Testing

struct DictationTextFormatterTests {
  @Test func normalizeTranscriptionCollapsesWhitespace() {
    let input = "  hello   world \n\n from\twhisper  "
    let normalized = DictationTextFormatter.normalizeTranscription(input)
    #expect(normalized == "hello world from whisper")
  }

  @Test func mergeAppendsToExistingMessageWithSingleSpace() {
    let merged = DictationTextFormatter.merge(existing: "Ship this fix", dictated: "please   today")
    #expect(merged == "Ship this fix please today")
  }

  @Test func mergeReturnsExistingWhenDictationIsEmpty() {
    let merged = DictationTextFormatter.merge(existing: "Already set", dictated: " \n\t ")
    #expect(merged == "Already set")
  }

  @Test func mergeUsesDictationWhenComposerIsEmpty() {
    let merged = DictationTextFormatter.merge(existing: "  ", dictated: "new message")
    #expect(merged == "new message")
  }
}
