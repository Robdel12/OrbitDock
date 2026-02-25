//
//  WhisperDictationController.swift
//  OrbitDock
//

import Foundation

@MainActor
@Observable
final class WhisperDictationController {
  enum State: Equatable {
    case idle
    case requestingPermission
    case recording
    case transcribing
  }

  var state: State = .idle
  var liveTranscript = ""
  var errorMessage: String?
  var isMicrophonePermissionDenied = false

  private let transcriber: any LocalWhisperTranscribing
  private let audioCapture: DictationAudioCapture

  private var capturedSamples: [Float] = []
  private var partialTranscriptionInFlight = false
  private var lastPartialSampleCount = 0
  private var activeStartToken: UUID?
  private var pendingResourceReleaseTask: Task<Void, Never>?

  // Trigger partial updates every second of additional audio.
  private let partialSampleStride = 16_000
  private let minimumSamplesForPartial = 8_000
  private let resourceReleaseDelay: Duration = .seconds(30)

  init(
    transcriber: (any LocalWhisperTranscribing)? = nil,
    audioCapture: DictationAudioCapture? = nil
  ) {
    self.transcriber = transcriber ?? WhisperTranscriberFactory.make()
    self.audioCapture = audioCapture ?? DictationAudioCapture()
  }

  var isRecording: Bool {
    state == .recording
  }

  var isBusy: Bool {
    state == .requestingPermission || state == .transcribing
  }

  var isSupported: Bool {
    transcriber.isSupported
  }

  func clearError() {
    errorMessage = nil
    isMicrophonePermissionDenied = false
  }

  func start() async {
    guard state == .idle else { return }
    guard transcriber.isSupported else {
      errorMessage = WhisperDictationError.whisperPackageMissing.localizedDescription
      return
    }
    cancelPendingResourceRelease()

    let startToken = UUID()
    activeStartToken = startToken
    resetCaptureState()
    liveTranscript = ""
    errorMessage = nil
    isMicrophonePermissionDenied = false
    state = .requestingPermission

    do {
      try await audioCapture.startStreaming { [weak self] samples in
        guard !samples.isEmpty else { return }
        Task { @MainActor [weak self] in
          self?.handleIncomingSamples(samples)
        }
      }

      guard activeStartToken == startToken else {
        audioCapture.stopStreaming()
        state = .idle
        return
      }
      state = .recording
    } catch {
      guard activeStartToken == startToken else {
        state = .idle
        return
      }
      activeStartToken = nil
      state = .idle
      if let dictationError = error as? WhisperDictationError,
         dictationError == .microphonePermissionDenied
      {
        isMicrophonePermissionDenied = true
      }
      errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  func stop() async -> String? {
    guard state == .recording || state == .requestingPermission else { return nil }

    activeStartToken = nil
    audioCapture.stopStreaming()
    let snapshot = capturedSamples
    resetCaptureState()

    guard !snapshot.isEmpty else {
      state = .idle
      liveTranscript = ""
      scheduleDelayedResourceRelease()
      return nil
    }

    state = .transcribing
    do {
      let transcript = try await transcriber.transcribe(samples: snapshot)
      state = .idle
      liveTranscript = ""
      scheduleDelayedResourceRelease()
      return DictationTextFormatter.normalizeTranscription(transcript)
    } catch {
      state = .idle
      liveTranscript = ""
      isMicrophonePermissionDenied = false
      errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      await releaseResourcesNow()
      return nil
    }
  }

  func cancel() async {
    activeStartToken = nil
    audioCapture.stopStreaming()
    resetCaptureState()
    liveTranscript = ""
    isMicrophonePermissionDenied = false
    state = .idle
    await releaseResourcesNow()
  }

  private func handleIncomingSamples(_ samples: [Float]) {
    guard state == .recording else { return }
    capturedSamples.append(contentsOf: samples)
    maybeQueuePartialTranscription()
  }

  private func maybeQueuePartialTranscription() {
    guard !partialTranscriptionInFlight else { return }

    let sampleCount = capturedSamples.count
    guard sampleCount >= minimumSamplesForPartial else { return }
    guard sampleCount - lastPartialSampleCount >= partialSampleStride else { return }

    let snapshot = capturedSamples
    partialTranscriptionInFlight = true

    Task { @MainActor [weak self] in
      await self?.runPartialTranscription(snapshot: snapshot, sampleCount: sampleCount)
    }
  }

  private func runPartialTranscription(snapshot: [Float], sampleCount: Int) async {
    defer { partialTranscriptionInFlight = false }

    do {
      let transcript = try await transcriber.transcribe(samples: snapshot)
      guard state == .recording else { return }
      liveTranscript = DictationTextFormatter.normalizeTranscription(transcript)
      lastPartialSampleCount = sampleCount
    } catch {
      // Keep recording even if a partial update fails.
    }
  }

  private func resetCaptureState() {
    capturedSamples.removeAll(keepingCapacity: false)
    partialTranscriptionInFlight = false
    lastPartialSampleCount = 0
  }

  private func scheduleDelayedResourceRelease() {
    cancelPendingResourceRelease()
    let delay = resourceReleaseDelay
    pendingResourceReleaseTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }

      guard let self, self.state == .idle else { return }
      await self.transcriber.releaseResources()
      self.pendingResourceReleaseTask = nil
    }
  }

  private func cancelPendingResourceRelease() {
    pendingResourceReleaseTask?.cancel()
    pendingResourceReleaseTask = nil
  }

  private func releaseResourcesNow() async {
    cancelPendingResourceRelease()
    await transcriber.releaseResources()
  }
}
