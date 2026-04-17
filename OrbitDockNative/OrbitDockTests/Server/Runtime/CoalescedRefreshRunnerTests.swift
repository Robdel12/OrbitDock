import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct CoalescedRefreshRunnerTests {
  @Test func cancelledOlderRefreshCannotClearNewerRefreshWaitHandle() async {
    let runner = CoalescedRefreshRunner()
    let fixture = RunnerCancellationFixture()

    let firstWaiter = Task {
      runner.schedule {
        await fixture.runFirstRefresh()
      }
      await runner.waitForCurrentRefresh()
    }

    await fixture.waitForFirstRefreshStart()
    runner.cancel()

    let secondWaiter = Task {
      runner.schedule {
        await fixture.runSecondRefresh()
      }
      await runner.waitForCurrentRefresh()
    }

    await fixture.waitForSecondRefreshStart()
    #expect(await fixture.isSecondRefreshCompleted() == false)

    await fixture.finishFirstRefresh()
    await fixture.finishSecondRefresh()
    await firstWaiter.value
    await secondWaiter.value

    #expect(await fixture.isSecondRefreshCompleted())
  }
}

actor RunnerCancellationFixture {
  private var firstRefreshStarted = false
  private var secondRefreshStarted = false
  private var secondRefreshCompleted = false

  private var firstRefreshStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var secondRefreshStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstRefreshFinishWaiters: [CheckedContinuation<Void, Never>] = []
  private var secondRefreshFinishWaiters: [CheckedContinuation<Void, Never>] = []

  func runFirstRefresh() async {
    firstRefreshStarted = true
    resume(waiters: &firstRefreshStartWaiters)
    await withCheckedContinuation { continuation in
      firstRefreshFinishWaiters.append(continuation)
    }
  }

  func runSecondRefresh() async {
    secondRefreshStarted = true
    resume(waiters: &secondRefreshStartWaiters)
    await withCheckedContinuation { continuation in
      secondRefreshFinishWaiters.append(continuation)
    }
    secondRefreshCompleted = true
  }

  func waitForFirstRefreshStart() async {
    guard !firstRefreshStarted else { return }
    await withCheckedContinuation { continuation in
      firstRefreshStartWaiters.append(continuation)
    }
  }

  func waitForSecondRefreshStart() async {
    guard !secondRefreshStarted else { return }
    await withCheckedContinuation { continuation in
      secondRefreshStartWaiters.append(continuation)
    }
  }

  func finishFirstRefresh() {
    resume(waiters: &firstRefreshFinishWaiters)
  }

  func finishSecondRefresh() {
    resume(waiters: &secondRefreshFinishWaiters)
  }

  func isSecondRefreshCompleted() -> Bool {
    secondRefreshCompleted
  }

  private func resume(waiters: inout [CheckedContinuation<Void, Never>]) {
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }
}
