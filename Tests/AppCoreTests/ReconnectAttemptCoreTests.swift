import Foundation
import Testing
@testable import AppCore

@Suite("Reconnect attempt outcomes")
struct ReconnectAttemptCoreTests {
  let t0: TimeInterval = 1_000

  @Test("each outcome maps to the matching finish event")
  func mapping() {
    #expect(ReconnectAttemptOutcome.flowClosed.buttonEvent == .succeeded)
    #expect(ReconnectAttemptOutcome.noFlowClosed.buttonEvent == .noGameFound)
    #expect(ReconnectAttemptOutcome.endpointNotFound.buttonEvent == .noGameFound)
    #expect(ReconnectAttemptOutcome.requestFailed.buttonEvent == .failed)
    #expect(ReconnectAttemptOutcome.extensionUnavailable.buttonEvent == .failed)
    #expect(ReconnectAttemptOutcome.uninstalling.buttonEvent == .failed)
  }

  @Test("every outcome ends a started attempt", arguments: ReconnectAttemptOutcome.allCases)
  func everyOutcomeEndsTheAttempt(_ outcome: ReconnectAttemptOutcome) {
    var model = ReconnectButtonModel(proxyReady: true, lastReconnectAt: 0, cooldownSeconds: 5)
    model.apply(.started, now: t0)
    #expect(model.phase(now: t0) == .reconnecting)
    model.apply(outcome.buttonEvent, now: t0)
    #expect(!model.isRunning)
    #expect(model.phase(now: t0) != .reconnecting)
    // Only a closed flow starts the cooldown, stamped with the same time the app stores.
    #expect((model.lastReconnectAt == t0) == (outcome == .flowClosed))
  }

  @Test("cooldown seconds round up and cap corrupt times")
  func cooldownSeconds() {
    #expect(ReconnectCooldownDisplay.wholeSeconds(remaining: 0) == 0)
    #expect(ReconnectCooldownDisplay.wholeSeconds(remaining: -3) == 0)
    #expect(ReconnectCooldownDisplay.wholeSeconds(remaining: 0.2) == 1)
    #expect(ReconnectCooldownDisplay.wholeSeconds(remaining: 4.0) == 4)
    #expect(ReconnectCooldownDisplay.wholeSeconds(remaining: 4.01) == 5)
    #expect(ReconnectCooldownDisplay.wholeSeconds(remaining: 1e19) == 86_400)
    #expect(ReconnectCooldownDisplay.wholeSeconds(remaining: .infinity) == 86_400)
    #expect(ReconnectCooldownDisplay.wholeSeconds(remaining: .nan) == 0)
  }
}
