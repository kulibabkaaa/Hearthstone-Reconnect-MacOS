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

/// Plays the app's part: applies effects exactly the way `AppDelegate.applyReconnectEffects` does.
private struct AppSim {
  var flow = ReconnectAttemptFlow()
  var model: ReconnectButtonModel
  var lastReconnectAt: TimeInterval = 0
  var proxyReady = true
  var statuses: [ReconnectStatusMessage] = []
  var recorded = 0
  var finishEvents = 0
  var extensionRefreshes = 0

  init() { model = ReconnectButtonModel(proxyReady: true, lastReconnectAt: 0, cooldownSeconds: 5) }

  mutating func apply(_ effects: ReconnectAttemptEffects, now: TimeInterval) {
    if effects.recordsFlowClosed { lastReconnectAt = now; recorded += 1 }
    if let event = effects.buttonEvent {
      if [.succeeded, .noGameFound, .failed].contains(event) { finishEvents += 1 }
      model.apply(event, now: now)
    }
    if let status = effects.status { statuses.append(status) }
    if effects.refreshesExtensionState { extensionRefreshes += 1 }
  }
  mutating func setProxyReady(_ ready: Bool, now: TimeInterval) {
    proxyReady = ready
    model.apply(.proxyAvailability(ready: ready), now: now)
  }
  /// Click, hotkey or menu. Returns the token when an attempt started.
  mutating func press(now: TimeInterval) -> ReconnectAttemptToken? {
    let remaining = max(0, lastReconnectAt + 5 - now)
    switch flow.request(proxyReady: proxyReady, cooldownRemaining: remaining) {
    case .refused(let effects): apply(effects, now: now); return nil
    case .started(let token, let effects): apply(effects, now: now); return token
    }
  }
}

@Suite("Reconnect attempt flow")
struct ReconnectAttemptFlowTests {
  let t0: TimeInterval = 1_000

  @Test("status texts and error styling are the ones the app always showed")
  func statusTexts() {
    #expect(ReconnectStatusMessage.proxyNotReady.text == "The local proxy is still getting ready.")
    #expect(ReconnectStatusMessage.alreadyRunning.text == "Reconnect is already in progress.")
    #expect(ReconnectStatusMessage.cooldown(seconds: 3).text == "Please wait 3 seconds and try again.")
    #expect(ReconnectStatusMessage.reconnecting.text == "Reconnecting…")
    #expect(ReconnectStatusMessage.missingGame.text == "Start a Battlegrounds game and try again.")
    #expect(ReconnectStatusMessage.checkingExtension.text == "Checking the reconnect extension…")
    #expect(ReconnectStatusMessage.failed.text == "Reconnect couldn't be completed. Please try again.")
    #expect(ReconnectStatusMessage.triggered.text == "Reconnect triggered.")
    let errors: [ReconnectStatusMessage] = [.proxyNotReady, .alreadyRunning, .cooldown(seconds: 1), .missingGame, .failed]
    for message in errors { #expect(message.isError) }
    for message in [ReconnectStatusMessage.reconnecting, .checkingExtension, .triggered] { #expect(!message.isError) }
  }

  @Test("a reply is read in the app's order: uninstalling, then a disconnected extension, then the reply")
  func completionOrder() {
    #expect(ReconnectCompletion(isUninstalling: true, extensionConnected: false, didCloseFlow: true) == .uninstalling)
    #expect(ReconnectCompletion(isUninstalling: false, extensionConnected: false, didCloseFlow: true) == .extensionUnavailable)
    #expect(ReconnectCompletion(isUninstalling: false, extensionConnected: true, didCloseFlow: nil) == .failed)
    #expect(ReconnectCompletion(isUninstalling: false, extensionConnected: true, didCloseFlow: true) == .response(didCloseFlow: true))
    #expect(ReconnectCompletion(isUninstalling: false, extensionConnected: true, didCloseFlow: false) == .response(didCloseFlow: false))
  }

  @Test("refusals: proxy first, then running, then cooldown; each redraws the button and starts nothing")
  func refusals() {
    var flow = ReconnectAttemptFlow()
    #expect(flow.request(proxyReady: false, cooldownRemaining: 3) == .refused(.init(rendersButton: true, status: .proxyNotReady)))
    #expect(flow.request(proxyReady: true, cooldownRemaining: 3.2) == .refused(.init(rendersButton: true, status: .cooldown(seconds: 4))))
    #expect(!flow.isRunning)
    guard case .started = flow.request(proxyReady: true, cooldownRemaining: 0) else { Issue.record("expected start"); return }
    #expect(flow.request(proxyReady: true, cooldownRemaining: 3) == .refused(.init(rendersButton: true, status: .alreadyRunning)))
    #expect(flow.request(proxyReady: false, cooldownRemaining: 0) == .refused(.init(rendersButton: true, status: .proxyNotReady)))
  }

  @Test("starting sends started, shows Reconnecting… and updates availability")
  func start() {
    var flow = ReconnectAttemptFlow()
    guard case .started(let token, let effects) = flow.request(proxyReady: true, cooldownRemaining: 0) else {
      Issue.record("expected start"); return
    }
    #expect(effects == .init(buttonEvent: .started, status: .reconnecting, updatesAvailability: true))
    #expect(flow.activeAttempt == token)
  }

  @Test("each on-time reply produces the app's original effects")
  func onTimeReplies() {
    let cases: [(ReconnectCompletion, ReconnectAttemptEffects)] = [
      (.uninstalling, .init(buttonEvent: .failed)),
      (.extensionUnavailable, .init(buttonEvent: .failed, status: .checkingExtension, refreshesExtensionState: true, updatesAvailability: true)),
      (.failed, .init(buttonEvent: .failed, status: .failed, updatesAvailability: true)),
      (.response(didCloseFlow: true), .init(recordsFlowClosed: true, buttonEvent: .succeeded, status: .triggered, updatesAvailability: true)),
      (.response(didCloseFlow: false), .init(buttonEvent: .noGameFound, status: .missingGame, updatesAvailability: true)),
    ]
    for (completion, expected) in cases {
      var flow = ReconnectAttemptFlow()
      guard case .started(let token, _) = flow.request(proxyReady: true, cooldownRemaining: 0) else { continue }
      #expect(flow.complete(token, completion) == expected)
      #expect(!flow.isRunning)
      #expect(flow.complete(token, completion) == .none, "a second reply for the same attempt does nothing")
      #expect(flow.timeOut(token, isUninstalling: false) == .none, "the timeout after a reply does nothing")
    }
  }

  @Test("no game endpoint ends the attempt with No game found")
  func endpointNotFound() {
    var flow = ReconnectAttemptFlow()
    guard case .started(let token, _) = flow.request(proxyReady: true, cooldownRemaining: 0) else { return }
    #expect(flow.endpointNotFound(token) == .init(buttonEvent: .noGameFound, status: .missingGame, updatesAvailability: true))
    #expect(!flow.isRunning)
    #expect(flow.endpointNotFound(token) == .none)
    #expect(flow.timeOut(token, isUninstalling: false) == .none)
  }

  @Test("the timeout ends a silent attempt with Try again and the usual failure text")
  func timeout() {
    #expect(ReconnectAttemptFlow.timeout == 12)
    #expect(ReconnectAttemptOutcome.timedOut.buttonEvent == .failed)
    var flow = ReconnectAttemptFlow()
    guard case .started(let token, _) = flow.request(proxyReady: true, cooldownRemaining: 0) else { return }
    #expect(flow.timeOut(token, isUninstalling: false) == .init(buttonEvent: .failed, status: .failed, updatesAvailability: true))
    #expect(!flow.isRunning)
    #expect(flow.timeOut(token, isUninstalling: false) == .none)
  }

  @Test("a timeout while uninstalling ends the attempt but leaves the uninstall status alone")
  func timeoutWhileUninstalling() {
    var flow = ReconnectAttemptFlow()
    guard case .started(let token, _) = flow.request(proxyReady: true, cooldownRemaining: 0) else { return }
    #expect(flow.timeOut(token, isUninstalling: true) == .init(buttonEvent: .failed))
    #expect(!flow.isRunning)
  }

  @Test("a late reply after the timeout changes nothing visible; only a really closed flow is recorded",
        arguments: [ReconnectCompletion.uninstalling, .extensionUnavailable, .failed,
                    .response(didCloseFlow: false), .response(didCloseFlow: true)])
  func lateReply(_ completion: ReconnectCompletion) {
    var flow = ReconnectAttemptFlow()
    guard case .started(let token, _) = flow.request(proxyReady: true, cooldownRemaining: 0) else { return }
    _ = flow.timeOut(token, isUninstalling: false)
    let effects = flow.complete(token, completion)
    if completion == .response(didCloseFlow: true) {
      #expect(effects == .init(recordsFlowClosed: true, buttonEvent: .cooldownStarted, updatesAvailability: true))
    } else {
      #expect(effects.isNone)
    }
    #expect(effects.status == nil)
    #expect(!flow.isRunning)
    #expect(flow.complete(token, completion).isNone, "a repeated late reply is recorded at most once")
  }

  @Test("an old attempt's reply or timeout can't end the newer attempt")
  func staleTokenCannotEndNewAttempt() {
    var flow = ReconnectAttemptFlow()
    guard case .started(let first, _) = flow.request(proxyReady: true, cooldownRemaining: 0) else { return }
    _ = flow.timeOut(first, isUninstalling: false)
    guard case .started(let second, _) = flow.request(proxyReady: true, cooldownRemaining: 0) else {
      Issue.record("retry after a timeout must start"); return
    }
    #expect(first != second)
    #expect(flow.complete(first, .response(didCloseFlow: false)).isNone)
    #expect(flow.timeOut(first, isUninstalling: false).isNone)
    #expect(flow.endpointNotFound(first).isNone)
    #expect(flow.activeAttempt == second)
    #expect(flow.complete(second, .failed).buttonEvent == .failed)
  }

  // MARK: The app's whole loop (flow + button model), as AppDelegate wires it

  @Test("timeout then late success: button shows Try again, then the cooldown, never Reconnected; one finish")
  func timeoutThenLateSuccess() {
    var app = AppSim()
    guard let token = app.press(now: t0) else { Issue.record("expected start"); return }
    #expect(app.model.phase(now: t0 + 9.9) == .reconnecting)
    app.apply(app.flow.timeOut(token, isUninstalling: false), now: t0 + 10)
    #expect(app.model.phase(now: t0 + 10) == .failed)
    #expect(app.statuses == [.reconnecting, .failed])
    app.apply(app.flow.complete(token, .response(didCloseFlow: true)), now: t0 + 11)
    #expect(app.finishEvents == 1)
    #expect(app.recorded == 1)
    #expect(app.lastReconnectAt == t0 + 11)
    #expect(app.statuses == [.reconnecting, .failed])                // no "Reconnect triggered."
    #expect(app.model.phase(now: t0 + 11) == .cooldown(seconds: 5))  // honest: a click now would be refused
    #expect(app.model.phase(now: t0 + 16) == .ready)
  }

  @Test("reply then a stray timeout: exactly one finish, the reply's result stays")
  func replyThenTimeout() {
    var app = AppSim()
    guard let token = app.press(now: t0) else { return }
    app.apply(app.flow.complete(token, .response(didCloseFlow: false)), now: t0 + 1)
    app.apply(app.flow.timeOut(token, isUninstalling: false), now: t0 + 10)
    #expect(app.finishEvents == 1)
    #expect(app.statuses == [.reconnecting, .missingGame])
  }

  @Test("retry after a timeout runs a new attempt, and the old attempt's late reply can't end it")
  func retryAfterTimeout() {
    var app = AppSim()
    guard let first = app.press(now: t0) else { return }
    app.apply(app.flow.timeOut(first, isUninstalling: false), now: t0 + 10)
    guard let second = app.press(now: t0 + 10.5) else { Issue.record("Try again must start an attempt"); return }
    app.apply(app.flow.complete(first, .response(didCloseFlow: false)), now: t0 + 11)
    #expect(app.model.phase(now: t0 + 11) == .reconnecting)
    #expect(app.flow.activeAttempt == second)
    app.apply(app.flow.complete(second, .response(didCloseFlow: true)), now: t0 + 12)
    #expect(app.model.phase(now: t0 + 12) == .succeeded)
    #expect(app.finishEvents == 2)
  }

  @Test("whenever the button looks clickable, a click starts an attempt (no silent clicks)")
  func clickableAlwaysStarts() {
    // Every ending (on time, or after a timeout with the reply arriving late), with readiness dropping
    // before, during or after.
    let completions: [ReconnectCompletion?] = [nil, .extensionUnavailable, .failed, .response(didCloseFlow: false),
                                               .response(didCloseFlow: true)]
    for completion in completions {
      for timesOut in [false, true] {
        for dropAt in [nil, 0.5, 1.5, 2.5] as [Double?] {
          var app = AppSim()
          guard let token = app.press(now: t0) else { continue }
          if dropAt == 0.5 { app.setProxyReady(false, now: t0 + 0.5) }
          if timesOut { app.apply(app.flow.timeOut(token, isUninstalling: false), now: t0 + 0.75) }
          if let completion {
            app.apply(app.flow.complete(token, completion), now: t0 + 1)
          } else {
            app.apply(app.flow.endpointNotFound(token), now: t0 + 1)
          }
          #expect(app.finishEvents == 1)
          if dropAt == 1.5 { app.setProxyReady(false, now: t0 + 1.5) }
          for step in stride(from: 1.0, through: 9.0, by: 0.25) {
            let now = t0 + step
            if dropAt == 2.5, step == 2.5 { app.setProxyReady(false, now: now) }
            let phase = app.model.phase(now: now)
            guard ReconnectButtonModel.appearance(for: phase).isClickable else { continue }
            var probe = app
            #expect(probe.press(now: now) != nil,
                    "\(String(describing: completion)) timeout \(timesOut) drop \(String(describing: dropAt)) at +\(step): \(phase)")
          }
        }
      }
    }
  }
}
