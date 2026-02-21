//
//  ShellPathCache.swift
//  OrbitDock
//
//  Resolves a login+interactive shell PATH once per launch so GUI apps can
//  discover binaries managed by shell init scripts (e.g., NVM).
//

import Foundation
#if canImport(Darwin)
  import Darwin
#endif

final class ShellPathCache {
  static let shared = ShellPathCache()

  private let lock = NSLock()
  private var cachedPATH: String?
  private var cachedShell: String?
  private var hasAttempted = false

  private init() {}

  func captureOnce() {
    lock.lock()
    if hasAttempted {
      lock.unlock()
      return
    }
    hasAttempted = true
    lock.unlock()

    let shell = Self.resolveShell()
    let path = Self.resolvePATH(using: shell)

    lock.lock()
    cachedShell = shell
    cachedPATH = path
    lock.unlock()
  }

  var shellPath: String? {
    captureOnce()
    lock.lock()
    defer { lock.unlock() }
    return cachedShell
  }

  var pathString: String? {
    captureOnce()
    lock.lock()
    defer { lock.unlock() }
    return cachedPATH
  }

  var pathEntries: [String] {
    captureOnce()
    let path = pathString ?? ""
    return path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
  }

  private static func resolveShell() -> String {
    let env = ProcessInfo.processInfo.environment
    if let explicit = env["ORBITDOCK_SHELL_PATH"],
       FileManager.default.isExecutableFile(atPath: explicit)
    {
      return explicit
    }

    if let shell = env["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
      return shell
    }

    if let loginShell = Self.lookupLoginShell(),
       FileManager.default.isExecutableFile(atPath: loginShell)
    {
      return loginShell
    }

    if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
      return "/bin/zsh"
    }

    return "/bin/sh"
  }

  private static func resolvePATH(using shell: String) -> String? {
    let sentinel = "__ORBITDOCK_PATH__"
    let command = "printf '\(sentinel)%s\\n' \"$PATH\""

    if let output = runShellCommand(shell: shell, args: ["-ilc", command]),
       let path = extractPath(from: output, sentinel: sentinel)
    {
      return path
    }

    if let output = runShellCommand(shell: shell, args: ["-lc", command]),
       let path = extractPath(from: output, sentinel: sentinel)
    {
      return path
    }

    if let output = runShellCommand(shell: shell, args: ["-c", command]),
       let path = extractPath(from: output, sentinel: sentinel)
    {
      return path
    }

    return nil
  }

  private static func lookupLoginShell() -> String? {
    #if canImport(Darwin)
      guard let pwd = getpwuid(getuid()) else { return nil }
      guard let shell = pwd.pointee.pw_shell else { return nil }
      return String(cString: shell)
    #else
      return nil
    #endif
  }

  private static func extractPath(from output: String, sentinel: String) -> String? {
    guard let range = output.range(of: sentinel, options: .backwards) else { return nil }
    let after = output[range.upperBound...]
    let firstLine = after.split(whereSeparator: { $0.isNewline }).first
    let path = firstLine.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return path?.isEmpty == false ? path : nil
  }

  private static func runShellCommand(shell: String, args: [String]) -> String? {
    #if !os(macOS)
      // TODO(server-extract): Shell/PATH resolution should be server-owned.
      _ = shell
      _ = args
      return nil
    #else
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: shell)
      proc.arguments = args

      var env = ProcessInfo.processInfo.environment
      env["TERM"] = "dumb"
      proc.environment = env

      let out = Pipe()
      proc.standardOutput = out
      proc.standardError = Pipe()

      let group = DispatchGroup()
      group.enter()
      proc.terminationHandler = { _ in group.leave() }

      do {
        try proc.run()
      } catch {
        return nil
      }

      let timeout: DispatchTime = .now() + 2.0
      if group.wait(timeout: timeout) == .timedOut {
        proc.terminate()
        _ = group.wait(timeout: .now() + 0.5)
        return nil
      }

      let data = out.fileHandleForReading.readDataToEndOfFile()
      guard let text = String(data: data, encoding: .utf8) else { return nil }
      return text
    #endif
  }
}
