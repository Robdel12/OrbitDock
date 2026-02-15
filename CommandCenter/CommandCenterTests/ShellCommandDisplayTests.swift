@testable import CommandCenter
import Testing

struct ShellCommandDisplayTests {
  @Test func stripsPosixWrapperPrefix() {
    let command = "/bin/zsh -lc git add . && git status"
    #expect(command.strippingShellWrapperPrefix() == "git add . && git status")
  }

  @Test func stripsEnvShellWrapperPrefix() {
    let command = "/usr/bin/env bash -lc git status"
    #expect(command.strippingShellWrapperPrefix() == "git status")
  }

  @Test func stripsPowerShellWrapperPrefix() {
    let command = "pwsh -Command Get-ChildItem"
    #expect(command.strippingShellWrapperPrefix() == "Get-ChildItem")
  }

  @Test func stripsCommandPromptWrapperPrefix() {
    let command = "cmd /c dir"
    #expect(command.strippingShellWrapperPrefix() == "dir")
  }

  @Test func keepsRegularCommandsUnchanged() {
    #expect("git status".strippingShellWrapperPrefix() == "git status")
    #expect("bash scripts/build.sh".strippingShellWrapperPrefix() == "bash scripts/build.sh")
  }
}
