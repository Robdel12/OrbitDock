//
//  AppleSpeechTranscriber.swift
//  OrbitDock
//

@preconcurrency import AVFoundation
import Foundation
#if canImport(Speech)
  @preconcurrency import Speech
#endif

#if canImport(Speech)
  @available(macOS 26.0, iOS 26.0, *)
  nonisolated enum AppleSpeechDictationConfiguration {
    static let inputSampleRate = 16_000.0
    static let contentHints: Set<DictationTranscriber.ContentHint> = [.shortForm]
    static let transcriptionOptions: Set<DictationTranscriber.TranscriptionOption> = [
      .punctuation,
      .etiquetteReplacements,
    ]
    static let reportingOptions: Set<DictationTranscriber.ReportingOption> = [
      .volatileResults,
      .frequentFinalization,
    ]
    static let attributeOptions: Set<DictationTranscriber.ResultAttributeOption> = []

    static func preferredInputFormat() -> AVAudioFormat {
      AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: inputSampleRate,
        channels: 1,
        interleaved: false
      )!
    }

    static func isCompatibleSpeechInputFormat(_ format: AVAudioFormat) -> Bool {
      format.channelCount == 1 && format.commonFormat == .pcmFormatInt16
    }

    static func makeDictationTranscriber(locale: Locale) -> DictationTranscriber {
      DictationTranscriber(
        locale: locale,
        contentHints: contentHints,
        transcriptionOptions: transcriptionOptions,
        reportingOptions: reportingOptions,
        attributeOptions: attributeOptions
      )
    }
  }

  @available(macOS 26.0, iOS 26.0, *)
  actor AppleSpeechTranscriber: LocalDictationTranscribing {
    typealias TranscriptUpdateHandler = @Sendable @MainActor (String) -> Void

    private struct StreamingSession {
      let analyzer: SpeechAnalyzer
      let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
      let analysisTask: Task<Void, Error>
      let resultsTask: Task<String, Error>
      let sourceFormat: AVAudioFormat
      let targetFormat: AVAudioFormat
      let converter: AVAudioConverter
    }

    nonisolated let isSupported = true

    private var streamingSession: StreamingSession?

    func prepareForTranscription() async throws {
      try await requestSpeechRecognitionAuthorization()
      try await prepareSpeechAssets(locale: Locale.autoupdatingCurrent)
    }

    func startTranscriptionSession(
      onTranscriptUpdate: @escaping TranscriptUpdateHandler
    ) async throws {
      await cancelTranscriptionSession()
      try await requestSpeechRecognitionAuthorization()
      let locale = Locale.autoupdatingCurrent
      try await prepareSpeechAssets(locale: locale)

      let transcriber = AppleSpeechDictationConfiguration.makeDictationTranscriber(locale: locale)
      let analyzer = SpeechAnalyzer(
        modules: [transcriber],
        options: .init(priority: .userInitiated, modelRetention: .lingering)
      )
      let sourceFormat = try makeSourceFormat()
      let targetFormat = try await compatibleInputFormat(for: transcriber)

      guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw DictationError.audioCaptureFailure(
          message: "Unable to convert dictation audio into Apple Speech's input format."
        )
      }

      try await analyzer.prepareToAnalyze(in: targetFormat)

      var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
      let inputSequence = AsyncStream<AnalyzerInput> { continuation in
        inputContinuation = continuation
      }

      guard let inputContinuation else {
        throw DictationError.transcriptionFailed(
          message: "Apple Speech couldn't create its streaming input."
        )
      }

      let resultsTask = Task<String, Error> {
        var latestTranscript = ""
        var transcriptSegments: [DictationTranscriptAssembler.Segment] = []
        for try await result in transcriber.results {
          transcriptSegments = DictationTranscriptAssembler.updating(
            transcriptSegments,
            with: .init(
              range: result.range,
              text: String(result.text.characters)
            )
          )
          latestTranscript = DictationTranscriptAssembler.render(transcriptSegments)
          await onTranscriptUpdate(latestTranscript)
        }
        return latestTranscript
      }

      let analysisTask = Task<Void, Error> {
        try await analyzer.start(inputSequence: inputSequence)
      }

      streamingSession = StreamingSession(
        analyzer: analyzer,
        inputContinuation: inputContinuation,
        analysisTask: analysisTask,
        resultsTask: resultsTask,
        sourceFormat: sourceFormat,
        targetFormat: targetFormat,
        converter: converter
      )
    }

    func appendAudioSamples(_ samples: [Float]) async throws {
      guard !samples.isEmpty else { return }
      guard let session = streamingSession else {
        throw DictationError.transcriptionFailed(
          message: "Dictation session is not active."
        )
      }

      let buffer = try makeInputBuffer(
        samples: samples,
        sourceFormat: session.sourceFormat,
        targetFormat: session.targetFormat,
        converter: session.converter
      )
      session.inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    func finishTranscriptionSession() async throws -> String {
      guard let session = streamingSession else { return "" }

      do {
        session.inputContinuation.finish()
        try await session.analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try await session.analysisTask.value
        let transcript = try await session.resultsTask.value
        streamingSession = nil
        return DictationTextFormatter.normalizeTranscription(transcript)
      } catch let error as DictationError {
        streamingSession = nil
        session.resultsTask.cancel()
        await session.analyzer.cancelAndFinishNow()
        throw error
      } catch {
        streamingSession = nil
        session.resultsTask.cancel()
        await session.analyzer.cancelAndFinishNow()
        throw DictationError.transcriptionFailed(message: error.localizedDescription)
      }
    }

    func cancelTranscriptionSession() async {
      guard let session = streamingSession else { return }
      streamingSession = nil
      session.inputContinuation.finish()
      session.resultsTask.cancel()
      session.analysisTask.cancel()
      await session.analyzer.cancelAndFinishNow()
    }

    func releaseResources() async {
      await cancelTranscriptionSession()
      await SpeechModels.endRetention()
    }

    private func requestSpeechRecognitionAuthorization() async throws {
      switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
          return
        case .notDetermined:
          let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { resolvedStatus in
              continuation.resume(returning: resolvedStatus)
            }
          }
          try validateSpeechRecognitionAuthorizationStatus(status)
        case .denied:
          throw DictationError.speechRecognitionPermissionDenied
        case .restricted:
          throw DictationError.speechRecognitionRestricted
        @unknown default:
          throw DictationError.transcriptionFailed(
            message: "Speech recognition authorization is in an unknown state."
          )
      }
    }

    private func validateSpeechRecognitionAuthorizationStatus(
      _ status: SFSpeechRecognizerAuthorizationStatus
    ) throws {
      switch status {
        case .authorized:
          return
        case .denied:
          throw DictationError.speechRecognitionPermissionDenied
        case .restricted:
          throw DictationError.speechRecognitionRestricted
        case .notDetermined:
          throw DictationError.transcriptionFailed(
            message: "Speech recognition authorization did not complete."
          )
        @unknown default:
          throw DictationError.transcriptionFailed(
            message: "Speech recognition authorization is in an unknown state."
          )
      }
    }

    private func prepareSpeechAssets(locale: Locale) async throws {
      let transcriber = AppleSpeechDictationConfiguration.makeDictationTranscriber(locale: locale)

      let availability = await AssetInventory.status(forModules: [transcriber])
      if availability == .unsupported {
        throw DictationError.dictationUnavailable(
          message: "Apple Speech is unavailable for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) on this device."
        )
      }

      do {
        if availability != .installed,
           let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        {
          try await installationRequest.downloadAndInstall()
        }
      } catch {
        throw DictationError.transcriptionFailed(
          message: "Apple Speech couldn't prepare its local assets. Connect to the internet once and try dictation again."
        )
      }
    }

    private func makeInputBuffer(
      samples: [Float],
      sourceFormat: AVAudioFormat,
      targetFormat: AVAudioFormat,
      converter: AVAudioConverter
    ) throws -> AVAudioPCMBuffer {
      let sourceBuffer = try makeSourceBuffer(samples: samples, format: sourceFormat)
      let conversionRatio = targetFormat.sampleRate / sourceBuffer.format.sampleRate
      let estimatedFrameCapacity = max(
        AVAudioFrameCount((Double(sourceBuffer.frameLength) * conversionRatio).rounded(.up)),
        1
      )

      guard let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: estimatedFrameCapacity
      ) else {
        throw DictationError.audioCaptureFailure(
          message: "Unable to allocate the Apple Speech audio buffer."
        )
      }

      var conversionError: NSError?
      var providedInput = false
      let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
        if providedInput {
          outStatus.pointee = .noDataNow
          return nil
        }

        providedInput = true
        outStatus.pointee = .haveData
        return sourceBuffer
      }

      if let conversionError {
        throw DictationError.audioCaptureFailure(
          message: "Apple Speech couldn't convert recorded audio. \(conversionError.localizedDescription)"
        )
      }

      guard status == .haveData || status == .endOfStream, convertedBuffer.frameLength > 0 else {
        throw DictationError.audioCaptureFailure(
          message: "Apple Speech couldn't convert recorded audio into a playable buffer."
        )
      }

      return convertedBuffer
    }

    private func makeSourceFormat() throws -> AVAudioFormat {
      guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AppleSpeechDictationConfiguration.inputSampleRate,
        channels: 1,
        interleaved: false
      ) else {
        throw DictationError.audioCaptureFailure(
          message: "Unable to create the Apple Speech input format."
        )
      }
      return format
    }

    private func makeSourceBuffer(
      samples: [Float],
      format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
      guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      ) else {
        throw DictationError.audioCaptureFailure(
          message: "Unable to allocate the Apple Speech audio buffer."
        )
      }

      buffer.frameLength = AVAudioFrameCount(samples.count)

      guard let channelData = buffer.floatChannelData?[0] else {
        throw DictationError.audioCaptureFailure(
          message: "Unable to access the Apple Speech audio channel buffer."
        )
      }

      for (index, sample) in samples.enumerated() {
        channelData[index] = sample
      }

      return buffer
    }

    private func compatibleInputFormat(for transcriber: DictationTranscriber) async throws -> AVAudioFormat {
      let preferredFormat = AppleSpeechDictationConfiguration.preferredInputFormat()

      if let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber],
        considering: preferredFormat
      ), AppleSpeechDictationConfiguration.isCompatibleSpeechInputFormat(bestFormat) {
        return bestFormat
      }

      let compatibleFormats = await transcriber.availableCompatibleAudioFormats

      if let exactMatch = compatibleFormats.first(where: {
        AppleSpeechDictationConfiguration.isCompatibleSpeechInputFormat($0)
          && abs($0.sampleRate - AppleSpeechDictationConfiguration.inputSampleRate) < 0.5
      }) {
        return exactMatch
      }

      if let fallbackMatch = compatibleFormats.first(
        where: AppleSpeechDictationConfiguration.isCompatibleSpeechInputFormat
      ) {
        return fallbackMatch
      }

      if AppleSpeechDictationConfiguration.isCompatibleSpeechInputFormat(preferredFormat) {
        return preferredFormat
      }

      throw DictationError.audioCaptureFailure(
        message: "Apple Speech requires mono 16-bit PCM input, but no compatible format was available."
      )
    }
  }
#endif
