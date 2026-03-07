//
//  DictationTranscriber.swift
//  OrbitDock
//

import Foundation

protocol LocalDictationTranscribing: Sendable {
  var isSupported: Bool { get }
  func prepareForTranscription() async throws
  func startTranscriptionSession(
    onTranscriptUpdate: @escaping @Sendable @MainActor (String) -> Void
  ) async throws
  func appendAudioSamples(_ samples: [Float]) async throws
  func finishTranscriptionSession() async throws -> String
  func cancelTranscriptionSession() async
  func releaseResources() async
}

enum DictationError: LocalizedError, Equatable {
  case dictationUnavailable(message: String)
  case microphonePermissionDenied
  case speechRecognitionPermissionDenied
  case speechRecognitionRestricted
  case audioCaptureFailure(message: String)
  case transcriptionFailed(message: String)
  case emptyAudio

  var errorDescription: String? {
    switch self {
      case let .dictationUnavailable(message):
        message
      case .microphonePermissionDenied:
        """
        Microphone access was denied.
        On macOS, if OrbitDock is missing from Privacy > Microphone, run:
        tccutil reset Microphone com.stubborn-mule-software.OrbitDock
        Then relaunch OrbitDock and try dictation again.
        """
      case .speechRecognitionPermissionDenied:
        """
        Speech recognition access was denied.
        Open OrbitDock in System Settings and allow Speech Recognition, then try again.
        """
      case .speechRecognitionRestricted:
        "Speech recognition is restricted on this device."
      case let .audioCaptureFailure(message):
        "Audio capture failed: \(message)"
      case let .transcriptionFailed(message):
        "Dictation failed: \(message)"
      case .emptyAudio:
        "No speech was captured."
    }
  }
}

enum LocalDictationTranscriberFactory {
  static func make() -> any LocalDictationTranscribing {
    switch LocalDictationAvailabilityResolver.current {
      case .available:
        #if canImport(Speech)
          if #available(macOS 26.0, iOS 26.0, *) {
            return AppleSpeechTranscriber()
          }
        #endif
        return UnsupportedLocalDictationTranscriber(
          message: "Apple Speech is unavailable in this build."
        )
      case .unavailable:
        return UnsupportedLocalDictationTranscriber(
          message: "Local dictation requires iOS 26 or macOS 26."
        )
    }
  }
}

struct UnsupportedLocalDictationTranscriber: LocalDictationTranscribing {
  let message: String
  let isSupported = false

  func prepareForTranscription() async throws {
    throw DictationError.dictationUnavailable(message: message)
  }

  func startTranscriptionSession(
    onTranscriptUpdate: @escaping @Sendable @MainActor (String) -> Void
  ) async throws {
    _ = onTranscriptUpdate
    throw DictationError.dictationUnavailable(message: message)
  }

  func appendAudioSamples(_ samples: [Float]) async throws {
    _ = samples
    throw DictationError.dictationUnavailable(message: message)
  }

  func finishTranscriptionSession() async throws -> String {
    throw DictationError.dictationUnavailable(message: message)
  }

  func cancelTranscriptionSession() async {}

  func releaseResources() async {}
}
