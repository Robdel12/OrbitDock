//
//  DictationAudioCapture.swift
//  OrbitDock
//

import AVFoundation
import Foundation

final class DictationAudioCapture {
  typealias SamplesHandler = @Sendable ([Float]) -> Void

  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var onSamples: SamplesHandler?

  private let whisperInputFormat: AVAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!

  func startStreaming(_ handler: @escaping SamplesHandler) async throws {
    if engine.isRunning { return }

    guard await requestMicrophonePermission() else {
      throw WhisperDictationError.microphonePermissionDenied
    }

    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [])
      try session.setPreferredSampleRate(16_000)
      try session.setPreferredIOBufferDuration(0.02)
      try session.setActive(true, options: [])
    #endif

    onSamples = handler

    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: inputFormat, to: whisperInputFormat) else {
      throw WhisperDictationError.audioCaptureFailure(
        message: "Unable to create converter from \(inputFormat) to 16k mono."
      )
    }
    self.converter = converter

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
      guard let self else { return }
      let samples = self.convertToWhisperSamples(buffer)
      guard !samples.isEmpty else { return }
      self.onSamples?(samples)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      stopStreaming()
      throw WhisperDictationError.audioCaptureFailure(message: error.localizedDescription)
    }
  }

  func stopStreaming() {
    if engine.inputNode.numberOfInputs > 0 {
      engine.inputNode.removeTap(onBus: 0)
    }
    if engine.isRunning {
      engine.stop()
    }
    converter = nil
    onSamples = nil

    #if os(iOS)
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif
  }

  private func convertToWhisperSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard let converter else { return [] }

    let ratio = whisperInputFormat.sampleRate / buffer.format.sampleRate
    let estimatedFrames = max(
      AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)),
      1
    )

    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: whisperInputFormat,
      frameCapacity: estimatedFrames
    ) else {
      return []
    }

    var error: NSError?
    var providedInput = false

    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if providedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      providedInput = true
      outStatus.pointee = .haveData
      return buffer
    }

    if status == .error || error != nil {
      return []
    }

    let frameCount = Int(outputBuffer.frameLength)
    guard frameCount > 0, let channelData = outputBuffer.floatChannelData?[0] else {
      return []
    }

    let pointer = UnsafeBufferPointer(start: channelData, count: frameCount)
    return Array(pointer)
  }

  private func requestMicrophonePermission() async -> Bool {
    #if os(iOS)
      await withCheckedContinuation { continuation in
        if #available(iOS 17.0, *) {
          AVAudioApplication.requestRecordPermission { allowed in
            continuation.resume(returning: allowed)
          }
        } else {
          AVAudioSession.sharedInstance().requestRecordPermission { allowed in
            continuation.resume(returning: allowed)
          }
        }
      }
    #elseif os(macOS)
      await withCheckedContinuation { continuation in
        if #available(macOS 14.0, *) {
          AVAudioApplication.requestRecordPermission { allowed in
            continuation.resume(returning: allowed)
          }
        } else {
          AVCaptureDevice.requestAccess(for: .audio) { allowed in
            continuation.resume(returning: allowed)
          }
        }
      }
    #else
      false
    #endif
  }
}
