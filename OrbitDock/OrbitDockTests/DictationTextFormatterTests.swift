import CoreMedia
@testable import OrbitDock
import Testing

struct DictationTextFormatterTests {
  @Test func normalizeTranscriptionCollapsesWhitespace() {
    let input = "  hello   world \n\n from\tdictation  "
    let normalized = DictationTextFormatter.normalizeTranscription(input)
    #expect(normalized == "hello world from dictation")
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

  @Test func normalizeTranscriptionRemovesBlankAudioTokens() {
    let input = "[BLANK_AUDIO] hello <|BLANK_AUDIO|> world [NOISE]"
    let normalized = DictationTextFormatter.normalizeTranscription(input)
    #expect(normalized == "hello world")
  }

  @Test func mergeIgnoresBlankAudioOnlyPayload() {
    let merged = DictationTextFormatter.merge(existing: "Existing", dictated: "[BLANK_AUDIO]")
    #expect(merged == "Existing")
  }

  @Test func transcriptAssemblerAppendsNonOverlappingSegments() {
    let firstRange = CMTimeRange(
      start: CMTime(seconds: 0, preferredTimescale: 600),
      duration: CMTime(seconds: 1, preferredTimescale: 600)
    )
    let secondRange = CMTimeRange(
      start: CMTime(seconds: 1, preferredTimescale: 600),
      duration: CMTime(seconds: 1, preferredTimescale: 600)
    )

    let firstPass = DictationTranscriptAssembler.updating(
      [],
      with: .init(range: firstRange, text: "hello")
    )
    let secondPass = DictationTranscriptAssembler.updating(
      firstPass,
      with: .init(range: secondRange, text: "world")
    )

    #expect(DictationTranscriptAssembler.render(secondPass) == "hello world")
  }

  @Test func transcriptAssemblerReplacesOverlappingSegmentInsteadOfDuplicating() {
    let shortRange = CMTimeRange(
      start: CMTime(seconds: 0, preferredTimescale: 600),
      duration: CMTime(seconds: 1, preferredTimescale: 600)
    )
    let expandedRange = CMTimeRange(
      start: CMTime(seconds: 0, preferredTimescale: 600),
      duration: CMTime(seconds: 2, preferredTimescale: 600)
    )
    let trailingRange = CMTimeRange(
      start: CMTime(seconds: 2, preferredTimescale: 600),
      duration: CMTime(seconds: 1, preferredTimescale: 600)
    )

    let firstPass = DictationTranscriptAssembler.updating(
      [],
      with: .init(range: shortRange, text: "hello")
    )
    let secondPass = DictationTranscriptAssembler.updating(
      firstPass,
      with: .init(range: expandedRange, text: "hello world")
    )
    let thirdPass = DictationTranscriptAssembler.updating(
      secondPass,
      with: .init(range: trailingRange, text: "again")
    )

    #expect(DictationTranscriptAssembler.render(thirdPass) == "hello world again")
  }
}
