//
//  AppleScriptService.swift
//  OrbitDock
//
//  Generic AppleScript execution service using osascript
//

import Foundation

final class AppleScriptService {
    static let shared = AppleScriptService()

    private init() {}

    /// Execute an AppleScript and return the result
    func execute(_ script: String, completion: @escaping (Result<String?, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus != 0, let error = errorOutput, !error.isEmpty {
                    DispatchQueue.main.async {
                        completion(.failure(AppleScriptError.executionFailed(error)))
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(.success(output))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Execute an AppleScript synchronously (blocking)
    func executeSync(_ script: String) -> Result<String?, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if process.terminationStatus != 0, let error = errorOutput, !error.isEmpty {
                return .failure(AppleScriptError.executionFailed(error))
            }
            return .success(output)
        } catch {
            return .failure(error)
        }
    }
}

enum AppleScriptError: Error, LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return "AppleScript execution failed: \(message)"
        }
    }
}
