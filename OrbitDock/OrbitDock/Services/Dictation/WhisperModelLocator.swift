//
//  WhisperModelLocator.swift
//  OrbitDock
//

import Foundation

struct WhisperModelLocator: Sendable {
  nonisolated static let environmentPathKey = "ORBITDOCK_WHISPER_MODEL_PATH"
  nonisolated static let defaultModelFileName = "ggml-base.en.bin"
  nonisolated static let bundledModelsDirectoryName = "WhisperModels"

  nonisolated func resolveModelPath() throws -> String {
    if let configuredPath = configuredModelPathCandidate() {
      guard FileManager.default.fileExists(atPath: configuredPath) else {
        throw WhisperDictationError.modelMissing(path: configuredPath)
      }
      return configuredPath
    }

    if let bundledPath = bundledModelPathCandidate() {
      guard FileManager.default.fileExists(atPath: bundledPath) else {
        throw WhisperDictationError.modelMissing(path: bundledPath)
      }
      return bundledPath
    }

    let defaultPath = try defaultModelPath()
    guard FileManager.default.fileExists(atPath: defaultPath) else {
      throw WhisperDictationError.modelMissing(path: defaultPath)
    }
    return defaultPath
  }

  nonisolated func bundledModelPathCandidate() -> String? {
    let fileName = Self.defaultModelFileName as NSString
    let fileBaseName = fileName.deletingPathExtension
    let fileExtension = fileName.pathExtension

    if let bundledDirectoryPath = Bundle.main.path(
      forResource: fileBaseName,
      ofType: fileExtension,
      inDirectory: Self.bundledModelsDirectoryName
    ) {
      return bundledDirectoryPath
    }

    return Bundle.main.path(forResource: fileBaseName, ofType: fileExtension)
  }

  nonisolated func configuredModelPathCandidate() -> String? {
    if let environmentOverride = normalizedPath(
      ProcessInfo.processInfo.environment[Self.environmentPathKey]
    ) {
      return environmentOverride
    }

    return nil
  }

  nonisolated func defaultModelPath() throws -> String {
    let appSupportURL = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )

    let modelsDirectoryURL = appSupportURL
      .appendingPathComponent("OrbitDock", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)

    try FileManager.default.createDirectory(
      at: modelsDirectoryURL,
      withIntermediateDirectories: true
    )

    return modelsDirectoryURL
      .appendingPathComponent(Self.defaultModelFileName, isDirectory: false)
      .path
  }

  private nonisolated func normalizedPath(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return NSString(string: trimmed).expandingTildeInPath
  }
}
