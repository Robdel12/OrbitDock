//
//  WhisperTranscriber.swift
//  OrbitDock
//

import Foundation
#if canImport(whisper)
  import whisper
#elseif canImport(Whisper)
  import Whisper
#endif

protocol LocalWhisperTranscribing: Sendable {
  var isSupported: Bool { get }
  func transcribe(samples: [Float]) async throws -> String
}

enum WhisperDictationError: LocalizedError, Equatable {
  case whisperPackageMissing
  case modelMissing(path: String)
  case microphonePermissionDenied
  case audioCaptureFailure(message: String)
  case transcriptionFailed(message: String)
  case emptyAudio

  var errorDescription: String? {
    switch self {
      case .whisperPackageMissing:
        "Whisper is not linked in this build."
      case let .modelMissing(path):
        """
        Whisper model file not found at:
        \(path)
        Bundle \(WhisperModelLocator.defaultModelFileName) in app resources (WhisperModels/) \
        or place it in Application Support/OrbitDock/Models. \
        For local overrides, set \(WhisperModelLocator.environmentPathKey).
        """
      case .microphonePermissionDenied:
        """
        Microphone access was denied.
        On macOS, if OrbitDock is missing from Privacy > Microphone, run:
        tccutil reset Microphone com.stubborn-mule-software.OrbitDock
        Then relaunch OrbitDock and try dictation again.
        """
      case let .audioCaptureFailure(message):
        "Audio capture failed: \(message)"
      case let .transcriptionFailed(message):
        "Whisper transcription failed: \(message)"
      case .emptyAudio:
        "No speech was captured."
    }
  }
}

enum WhisperTranscriberFactory {
  static func make(locator: WhisperModelLocator = WhisperModelLocator()) -> any LocalWhisperTranscribing {
    #if canImport(whisper) || canImport(Whisper)
      WhisperCppTranscriber(locator: locator)
    #else
      UnsupportedWhisperTranscriber()
    #endif
  }
}

struct UnsupportedWhisperTranscriber: LocalWhisperTranscribing {
  let isSupported = false

  func transcribe(samples: [Float]) async throws -> String {
    throw WhisperDictationError.whisperPackageMissing
  }
}

#if canImport(whisper) || canImport(Whisper)
  actor WhisperCppTranscriber: LocalWhisperTranscribing {
    nonisolated let isSupported = true

    private let locator: WhisperModelLocator
    private var context: OpaquePointer?
    private var loadedModelPath: String?

    init(locator: WhisperModelLocator) {
      self.locator = locator
    }

    deinit {
      if let context {
        whisper_free(context)
      }
    }

    func transcribe(samples: [Float]) async throws -> String {
      guard !samples.isEmpty else {
        throw WhisperDictationError.emptyAudio
      }

      do {
        let ctx = try loadContextIfNeeded()
        let transcript = try runTranscription(context: ctx, samples: samples)
        return DictationTextFormatter.normalizeTranscription(transcript)
      } catch let error as WhisperDictationError {
        throw error
      } catch {
        throw WhisperDictationError.transcriptionFailed(message: error.localizedDescription)
      }
    }

    private func loadContextIfNeeded() throws -> OpaquePointer {
      let modelPath = try locator.resolveModelPath()
      if let context, loadedModelPath == modelPath {
        return context
      }

      if let context {
        whisper_free(context)
        self.context = nil
        loadedModelPath = nil
      }

      var params = whisper_context_default_params()
      params.use_gpu = true

      let newContext = modelPath.withCString { modelPathPointer in
        whisper_init_from_file_with_params(modelPathPointer, params)
      }

      guard let newContext else {
        throw WhisperDictationError.transcriptionFailed(
          message: "Failed to initialize Whisper context."
        )
      }

      context = newContext
      loadedModelPath = modelPath
      return newContext
    }

    private func runTranscription(context: OpaquePointer, samples: [Float]) throws -> String {
      var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
      params.translate = false
      params.print_realtime = false
      params.print_progress = false
      params.print_timestamps = false
      params.print_special = false

      let sampleCount = Int32(clamping: samples.count)
      let status = samples.withUnsafeBufferPointer { buffer in
        whisper_full(context, params, buffer.baseAddress, sampleCount)
      }

      guard status == 0 else {
        throw WhisperDictationError.transcriptionFailed(
          message: "whisper_full returned \(status)."
        )
      }

      let segmentCount = Int(whisper_full_n_segments(context))
      guard segmentCount > 0 else { return "" }

      var segments: [String] = []
      segments.reserveCapacity(segmentCount)

      for segmentIndex in 0..<segmentCount {
        guard let segmentTextPointer = whisper_full_get_segment_text(context, Int32(segmentIndex)) else {
          continue
        }
        segments.append(String(cString: segmentTextPointer))
      }

      return segments.joined(separator: " ")
    }
  }
#endif
