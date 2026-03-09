@testable import OrbitDock
import Testing

struct ComposerImageAttachmentPolicyTests {
  @Test func usedRawBytesIgnoresNegativeValues() {
    let total = ComposerImageAttachmentPolicy.usedRawBytes([120_000, -1, 80_000])
    #expect(total == 200_000)
  }

  @Test func validateAdditionAllowsImageWithinBudget() {
    let result = ComposerImageAttachmentPolicy.validateAddition(
      existingCount: 1,
      usedRawBytes: ComposerImageAttachmentPolicy.maxTotalRawBytes - 512_000,
      candidateRawBytes: 256_000
    )

    #expect(result == .allowed)
  }

  @Test func validateAdditionRejectsWhenImageCountIsFull() {
    let result = ComposerImageAttachmentPolicy.validateAddition(
      existingCount: ComposerImageAttachmentPolicy.maxImageCount,
      usedRawBytes: 200_000,
      candidateRawBytes: 10_000
    )

    #expect(result == .tooMany(maxCount: ComposerImageAttachmentPolicy.maxImageCount))
  }

  @Test func validateAdditionRejectsWhenRawByteBudgetWouldOverflow() {
    let remainingBytes = 256_000
    let result = ComposerImageAttachmentPolicy.validateAddition(
      existingCount: 2,
      usedRawBytes: ComposerImageAttachmentPolicy.maxTotalRawBytes - remainingBytes,
      candidateRawBytes: remainingBytes + 1
    )

    #expect(
      result == .tooLarge(
        maxBytes: ComposerImageAttachmentPolicy.maxTotalRawBytes
      )
    )
  }

  @Test func remainingBytesClampsToZeroWhenBudgetIsExceeded() {
    let remaining = ComposerImageAttachmentPolicy.remainingBytes(
      usedRawBytes: ComposerImageAttachmentPolicy.maxTotalRawBytes + 1
    )

    #expect(remaining == 0)
  }

  @Test func estimatedTransportBytesAccountsForBase64Expansion() {
    let encoded = ComposerImageAttachmentPolicy.estimatedTransportBytes(forRawBytes: 6)
    #expect(encoded == 8)
  }
}
