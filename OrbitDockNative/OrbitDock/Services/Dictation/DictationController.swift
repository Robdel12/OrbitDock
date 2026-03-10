//
//  DictationController.swift
//  OrbitDock
//

import Foundation

@MainActor
@Observable
final class LocalDictationController {
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

  private let transcriber: any LocalDictationTranscribing
  private let audioCapture: DictationAudioCapture

  private var activeStartToken: UUID?
  private var pendingResourceReleaseTask: Task<Void, Never>?
  private let resourceReleaseDelay: Duration = .seconds(30)

  init(
    transcriber: (any LocalDictationTranscribing)? = nil,
    audioCapture: DictationAudioCapture? = nil
  ) {
    self.transcriber = transcriber ?? LocalDictationTranscriberFactory.make()
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
      errorMessage = DictationError.dictationUnavailable(
        message: "Local dictation is unavailable on this device."
      ).localizedDescription
      return
    }

    cancelPendingResourceRelease()

    let startToken = UUID()
    activeStartToken = startToken
    liveTranscript = ""
    errorMessage = nil
    isMicrophonePermissionDenied = false
    state = .requestingPermission

    do {
      try await transcriber.prepareForTranscription()
      try await transcriber.startTranscriptionSession { [weak self] transcript in
        guard let self else { return }
        guard self.state == .recording || self.state == .transcribing else { return }
        self.liveTranscript = DictationTextFormatter.normalizeTranscription(transcript)
      }

      let transcriber = self.transcriber
      try await audioCapture.startStreaming { [weak self] samples in
        guard !samples.isEmpty else { return }
        Task { [weak self] in
          do {
            try await transcriber.appendAudioSamples(samples)
          } catch {
            await self?.handleStreamingError(error)
          }
        }
      }

      guard activeStartToken == startToken else {
        audioCapture.stopStreaming()
        await transcriber.cancelTranscriptionSession()
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
      if let dictationError = error as? DictationError,
         dictationError == .microphonePermissionDenied
      {
        isMicrophonePermissionDenied = true
      }
      errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      await transcriber.cancelTranscriptionSession()
    }
  }

  func stop() async -> String? {
    guard state == .recording || state == .requestingPermission else { return nil }

    activeStartToken = nil
    audioCapture.stopStreaming()
    state = .transcribing

    do {
      let transcript = try await transcriber.finishTranscriptionSession()
      state = .idle
      liveTranscript = ""
      scheduleDelayedResourceRelease()

      let normalized = DictationTextFormatter.normalizeTranscription(transcript)
      return normalized.isEmpty ? nil : normalized
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
    liveTranscript = ""
    isMicrophonePermissionDenied = false
    state = .idle
    await releaseResourcesNow()
  }

  private func handleStreamingError(_ error: Error) async {
    guard state == .recording || state == .requestingPermission else { return }

    activeStartToken = nil
    audioCapture.stopStreaming()
    state = .idle
    liveTranscript = ""
    isMicrophonePermissionDenied = false
    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    await releaseResourcesNow()
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
    await transcriber.cancelTranscriptionSession()
    await transcriber.releaseResources()
  }
}
