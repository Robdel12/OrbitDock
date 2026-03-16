//
//  AppFileLogger.swift
//  OrbitDock
//
//  Tees app stdout/stderr to ~/.orbitdock/logs/app.log
//  so runtime diagnostics are available outside Xcode.
//  In DEBUG builds with a debugger attached, output goes to both
//  the file AND the Xcode console. In release/standalone, output
//  goes only to the file.
//

import Darwin
import Foundation

final class AppFileLogger: @unchecked Sendable {
  static let shared = AppFileLogger()

  private var redirected = false

  private init() {}

  func start() {
    guard !redirected else { return }

    let logDir = PlatformPaths.orbitDockLogsDirectory
    let logPath = logDir.appendingPathComponent("app.log").path

    do {
      try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    } catch {
      return
    }

    #if DEBUG
      let debugDefaultTruncate = true
    #else
      let debugDefaultTruncate = false
    #endif
    let shouldTruncate = ProcessInfo.processInfo
      .environment["ORBITDOCK_TRUNCATE_APP_LOG_ON_START"] == "1" || debugDefaultTruncate
    let flags = O_WRONLY | O_CREAT | (shouldTruncate ? O_TRUNC : O_APPEND)
    let logFd = open(logPath, flags, S_IRUSR | S_IWUSR)
    guard logFd >= 0 else { return }

    #if DEBUG
      let debuggerAttached: Bool = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return (info.kp_proc.p_flag & P_TRACED) != 0
      }()

      if debuggerAttached {
        // Tee: save originals, redirect to file, then spawn background threads
        // that copy file output back to original fds.
        let origStdout = dup(STDOUT_FILENO)
        let origStderr = dup(STDERR_FILENO)

        // Create pipes for stdout and stderr
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        pipe(&stdoutPipe)
        pipe(&stderrPipe)

        // Replace stdout/stderr with pipe write ends
        dup2(stdoutPipe[1], STDOUT_FILENO)
        dup2(stderrPipe[1], STDERR_FILENO)
        close(stdoutPipe[1])
        close(stderrPipe[1])

        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)

        // Background threads read from pipes and write to both file and original fds
        startTeeThread(readFd: stdoutPipe[0], fileFd: logFd, origFd: origStdout)
        startTeeThread(readFd: stderrPipe[0], fileFd: logFd, origFd: origStderr)
      } else {
        // No debugger — just redirect to file
        dup2(logFd, STDOUT_FILENO)
        dup2(logFd, STDERR_FILENO)
        close(logFd)
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
      }
    #else
      // Release — redirect to file only
      dup2(logFd, STDOUT_FILENO)
      dup2(logFd, STDERR_FILENO)
      close(logFd)
      setvbuf(stdout, nil, _IOLBF, 0)
      setvbuf(stderr, nil, _IOLBF, 0)
    #endif

    redirected = true
    print("=== OrbitDock app logger started pid=\(ProcessInfo.processInfo.processIdentifier) ===")
  }

  #if DEBUG
    /// Reads from `readFd` and writes each chunk to both `fileFd` and `origFd`.
    private func startTeeThread(readFd: Int32, fileFd: Int32, origFd: Int32) {
      let thread = Thread {
        let bufSize = 4_096
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buf.deallocate() }
        while true {
          let n = read(readFd, buf, bufSize)
          if n <= 0 { break }
          write(fileFd, buf, n)
          write(origFd, buf, n)
        }
      }
      thread.qualityOfService = .utility
      thread.start()
    }
  #endif
}
