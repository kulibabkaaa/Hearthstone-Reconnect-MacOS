import Foundation
import Testing
@testable import AppCore

@Suite("Reconnect button core")
struct ReconnectButtonCoreTests {
  let t0: TimeInterval = 1_000
  /// Proxy ready, last reconnect long ago, 5 s cooldown (same as `ProxyConstants.cooldownSeconds`).
  func model(ready: Bool = true, last: TimeInterval = 0) -> ReconnectButtonModel {
    ReconnectButtonModel(proxyReady: ready, lastReconnectAt: last, cooldownSeconds: 5)
  }

  // MARK: Phase priority

  @Test("a fresh ready model is ready; unready proxy is unavailable")
  func basicPhases() {
    #expect(model().phase(now: t0) == .ready)
    #expect(model(ready: false).phase(now: t0) == .unavailable)
  }
  @Test("reconnecting beats a live transient, unavailable and cooldown")
  func reconnectingWins() {
    var m = model(ready: false, last: t0)
    m.apply(.failed, now: t0)
    m.apply(.proxyAvailability(ready: false), now: t0)
    m.apply(.started, now: t0 + 0.5)
    #expect(m.phase(now: t0 + 0.5) == .reconnecting)
    #expect(m.nextChange(after: t0 + 0.5) == nil)
  }
  @Test("Reconnected beats unavailable; unavailable beats cooldown; expired transient falls through")
  func transientThenUnavailableThenCooldown() {
    var m = model()
    m.apply(.succeeded, now: t0)
    m.apply(.proxyAvailability(ready: false), now: t0)
    #expect(m.phase(now: t0 + 1.9) == .succeeded)
    #expect(m.phase(now: t0 + 2) == .unavailable)   // expiry is exclusive, cooldown still running underneath
    m.apply(.proxyAvailability(ready: true), now: t0 + 2)
    #expect(m.phase(now: t0 + 2) == .cooldown(seconds: 3))
  }
  @Test("a clickable transient gives way to unavailable or cooldown, so its click is never refused",
        arguments: [ReconnectButtonEvent.noGameFound, .failed])
  func clickableTransientNeedsAClickThatWorks(_ event: ReconnectButtonEvent) {
    let shown: ReconnectButtonPhase = event == .failed ? .failed : .noGameFound
    // Readiness drops while the transient shows.
    var m = model()
    m.apply(event, now: t0)
    #expect(m.phase(now: t0 + 0.5) == shown)
    m.apply(.proxyAvailability(ready: false), now: t0 + 0.5)
    #expect(m.phase(now: t0 + 0.5) == .unavailable)
    m.apply(.proxyAvailability(ready: true), now: t0 + 1)
    #expect(m.phase(now: t0 + 1) == shown)            // back while it lasts
    // The attempt ends while the proxy is already down (the extension went away mid-attempt).
    var down = model(ready: false)
    down.apply(.started, now: t0)
    down.apply(event, now: t0 + 1)
    #expect(down.phase(now: t0 + 1) == .unavailable)
    // A late closed flow starts the cooldown under the transient.
    var late = model()
    late.apply(event, now: t0)
    late.apply(.cooldownStarted, now: t0 + 0.5)
    #expect(late.phase(now: t0 + 0.5) == .cooldown(seconds: 5))
  }
  @Test("cooldownStarted stamps the cooldown and leaves running and the transient alone")
  func cooldownStarted() {
    var running = model()
    running.apply(.started, now: t0)
    running.apply(.cooldownStarted, now: t0 + 1)
    #expect(running.isRunning)
    #expect(running.lastReconnectAt == t0 + 1)
    #expect(running.phase(now: t0 + 1) == .reconnecting)
    var shown = model()
    shown.apply(.succeeded, now: t0)
    shown.apply(.cooldownStarted, now: t0 + 1)
    #expect(shown.phase(now: t0 + 1.5) == .succeeded)
    #expect(shown.phase(now: t0 + 2) == .cooldown(seconds: 4))
  }

  // MARK: Events

  @Test("started clears the transient and does not touch the cooldown clock")
  func startedClearsTransient() {
    var m = model()
    m.apply(.failed, now: t0)
    m.apply(.started, now: t0 + 1)
    #expect(m.lastReconnectAt == 0)
    m.apply(.noGameFound, now: t0 + 1.5)    // finishing again shows only the new transient
    #expect(m.phase(now: t0 + 1.6) == .noGameFound)
    #expect(m.phase(now: t0 + 3.6) == .ready)
  }
  @Test("succeeded stamps lastReconnectAt and starts the cooldown")
  func succeededStartsCooldown() {
    var m = model()
    m.apply(.started, now: t0)
    m.apply(.succeeded, now: t0 + 0.3)
    #expect(m.lastReconnectAt == t0 + 0.3)
    #expect(m.isRunning == false)
    #expect(m.phase(now: t0 + 0.3) == .succeeded)
    #expect(m.phase(now: t0 + 2.3) == .cooldown(seconds: 3))
  }
  @Test("noGameFound and failed show a transient but start no cooldown")
  func noCooldownOnMiss() {
    for event in [ReconnectButtonEvent.noGameFound, .failed] {
      var m = model()
      m.apply(.started, now: t0)
      m.apply(event, now: t0 + 1)
      #expect(m.lastReconnectAt == 0)
      #expect(m.isRunning == false)
      #expect(m.phase(now: t0 + 1) == (event == .failed ? .failed : .noGameFound))
      #expect(m.phase(now: t0 + 3) == .ready)
    }
  }
  @Test("proxyAvailability toggles only the readiness")
  func proxyAvailability() {
    var m = model()
    m.apply(.proxyAvailability(ready: false), now: t0)
    #expect(m.phase(now: t0) == .unavailable)
    #expect(m.nextChange(after: t0) == nil)
    m.apply(.proxyAvailability(ready: true), now: t0)
    #expect(m.phase(now: t0) == .ready)
  }

  // MARK: Cooldown seconds

  @Test("cooldown seconds round up, stay >= 1, and exactly 0 left is ready")
  func cooldownRounding() {
    let m = model(last: t0)
    #expect(m.phase(now: t0) == .cooldown(seconds: 5))
    #expect(m.phase(now: t0 + 0.8) == .cooldown(seconds: 5))     // 4.2 s left
    #expect(m.phase(now: t0 + 1) == .cooldown(seconds: 4))       // exactly 4 left
    #expect(m.phase(now: t0 + 4.99) == .cooldown(seconds: 1))    // 0.01 s left
    #expect(m.phase(now: t0 + 5) == .ready)
    #expect(m.phase(now: t0 + 60) == .ready)
    #expect(m.phase(now: t0 - 100) == .cooldown(seconds: 5 + 100))  // clock went backwards: no crash
  }
  @Test("agrees with the ReconnectCooldown.remaining formula for the same inputs")
  func agreesWithProxyCooldown() {
    for (last, now) in [(0.0, 10.0), (100, 100), (100, 103.5), (100, 104.999), (100, 105), (100, 105.001), (100, 99)] {
      let remaining = max(0, last + 5 - now)     // ReconnectCooldown.remaining (AppCoreTests can't import ProxyCore)
      let expected: ReconnectButtonPhase = remaining > 0 ? .cooldown(seconds: max(1, Int(remaining.rounded(.up)))) : .ready
      #expect(model(last: last).phase(now: now) == expected)
    }
  }

  // MARK: Sequence and nextChange

  @Test("success shows Reconnected for 2 s, then the countdown, then ready")
  func successSequence() {
    var m = model()
    m.apply(.started, now: t0)
    m.apply(.succeeded, now: t0)
    #expect(m.phase(now: t0 + 1.999) == .succeeded)
    #expect(m.phase(now: t0 + 2) == .cooldown(seconds: 3))
    #expect(m.phase(now: t0 + 3) == .cooldown(seconds: 2))
    #expect(m.phase(now: t0 + 4) == .cooldown(seconds: 1))
    #expect(m.phase(now: t0 + 5) == .ready)
    #expect(ReconnectButtonModel.appearance(for: m.phase(now: t0 + 2)).title == "Wait 3s…")
  }
  @Test("nextChange is nil when idle or after expiry, and wakes for the transient and each countdown second")
  func nextChangeBasics() {
    #expect(model().nextChange(after: t0) == nil)
    var m = model()
    m.apply(.failed, now: t0)
    #expect(m.nextChange(after: t0) == t0 + 2)                 // transient expiry
    #expect(m.nextChange(after: t0 + 2) == nil)                // expired, no cooldown
    var s = model()
    s.apply(.succeeded, now: t0)
    #expect(s.nextChange(after: t0) == t0 + 1)                 // countdown tick (5 -> 4 is the first boundary, before the 2 s expiry)
    #expect(s.nextChange(after: t0 + 4.2) == t0 + 5)           // last second ends at the cooldown end
    #expect(s.nextChange(after: t0 + 5) == nil)
  }
  @Test("nextChange hits whole-second boundaries, including exact integer remainders")
  func nextChangeBoundaries() {
    let m = model(last: t0)
    #expect(m.nextChange(after: t0) == t0 + 1)                  // remaining 5.0 exactly -> shows 5 until 4.0
    #expect(m.nextChange(after: t0 + 0.8) == t0 + 1)            // remaining 4.2 -> 4.0
    #expect(m.nextChange(after: t0 + 1) == t0 + 2)              // remaining 4.0 exactly -> next is 3.0, not now
    #expect(m.nextChange(after: t0 + 4.5) == t0 + 5)            // remaining 0.5 -> ready
    #expect(m.nextChange(after: t0 + 4.999) == t0 + 5)
  }
  @Test("nextChange is nil while running or unavailable, even mid-cooldown")
  func nextChangeGuards() {
    var running = model(last: t0)
    running.apply(.started, now: t0 + 1)
    #expect(running.nextChange(after: t0 + 1) == nil)
    let unavailable = model(ready: false, last: t0)
    #expect(unavailable.nextChange(after: t0 + 1) == nil)
  }
  @Test("a custom cooldown length is honoured and a corrupt stored time does not crash")
  func customAndCorruptCooldown() {
    let m = ReconnectButtonModel(proxyReady: true, lastReconnectAt: t0, cooldownSeconds: 12)
    #expect(m.phase(now: t0 + 1.5) == .cooldown(seconds: 11))
    #expect(m.phase(now: t0 + 12) == .ready)
    #expect(m.nextChange(after: t0) == t0 + 1)
    for corrupt in [Double.infinity, 1e19] {
      let bad = ReconnectButtonModel(proxyReady: true, lastReconnectAt: corrupt, cooldownSeconds: 5)
      guard case .cooldown(let seconds) = bad.phase(now: t0) else { Issue.record("expected cooldown"); continue }
      #expect(seconds >= 1)
    }
  }
  @Test("following nextChange from a success walks every phase change with no busy loop")
  func nextChangeWalk() {
    // Realistic clock values with sub-millisecond fractions, where float rounding can bite.
    for start in [1_000.0, 783_456_789.123_456, 783_456_789.999_999_9, 1_800_000_000.000_1] {
      var m = ReconnectButtonModel(proxyReady: true, lastReconnectAt: 0, cooldownSeconds: 5)
      m.apply(.succeeded, now: start)
      var now = start
      var seen: [ReconnectButtonPhase] = [m.phase(now: now)]
      var ticks = 0
      while let next = m.nextChange(after: now) {
        #expect(next > now)
        now = next
        ticks += 1
        let phase = m.phase(now: now)
        if phase != seen.last { seen.append(phase) }
        if ticks > 12 { break }
      }
      #expect(ticks <= 8, "start \(start) took \(ticks) ticks")
      #expect(seen == [.succeeded, .cooldown(seconds: 3), .cooldown(seconds: 2), .cooldown(seconds: 1), .ready])
    }
  }

  // MARK: Appearance

  @Test("appearance: titles, tones, clickability, spinning")
  func appearance() {
    let cases: [(ReconnectButtonPhase, String, ReconnectButtonTone, Bool, Bool)] = [
      (.ready, "Reconnect", .normal, true, false),
      (.unavailable, "Not ready", .dimmed, false, false),
      (.reconnecting, "Reconnecting…", .normal, false, true),
      (.succeeded, "Reconnected", .success, false, false),
      (.noGameFound, "No game found", .warning, true, false),
      (.failed, "Try again", .error, true, false),
      (.cooldown(seconds: 3), "Wait 3s…", .dimmed, false, false),
    ]
    for (phase, title, tone, clickable, spins) in cases {
      let a = ReconnectButtonModel.appearance(for: phase)
      #expect(a == ReconnectButtonAppearance(title: title, tone: tone, isClickable: clickable, spinsIcon: spins))
    }
  }

  // MARK: Layout

  @Test("editableBlocks covers all four combinations, lobby first")
  func editableBlocks() {
    #expect(OverlayLayoutPolicy.editableBlocks(lobbyEnabled: true, reconnectButtonEnabled: true) == [.lobby, .reconnectButton])
    #expect(OverlayLayoutPolicy.editableBlocks(lobbyEnabled: true, reconnectButtonEnabled: false) == [.lobby])
    #expect(OverlayLayoutPolicy.editableBlocks(lobbyEnabled: false, reconnectButtonEnabled: true) == [.reconnectButton])
    #expect(OverlayLayoutPolicy.editableBlocks(lobbyEnabled: false, reconnectButtonEnabled: false).isEmpty)
  }
  @Test("default origin is anchored by the top edge and clamps the scale")
  func defaultOrigin() {
    let game = CGRect(x: -1440, y: 50, width: 1000, height: 800)   // origin offset must not matter
    #expect(ReconnectButtonLayout.baseSize == CGSize(width: 160, height: 50))
    let one = ReconnectButtonLayout.defaultNormalizedOrigin(scale: 1, gameFrame: game)
    #expect(one.x == 0.735)
    #expect(abs(one.y - (1 - 0.184 - 50.0 / 800)) < 1e-9)
    // The top edge sits at 18.4% from the game's top for every scale.
    for scale in [0.75, 1, 1.5, 9, -3, .nan, .infinity] {
      let o = ReconnectButtonLayout.defaultNormalizedOrigin(scale: scale, gameFrame: game)
      let top = o.y + 50.0 * LobbyOverlayGeometry.clampScale(scale) / 800
      #expect(abs((1 - top) - 0.184) < 1e-9)
    }
    #expect(ReconnectButtonLayout.defaultNormalizedOrigin(scale: 9, gameFrame: game)
      == ReconnectButtonLayout.defaultNormalizedOrigin(scale: 1.5, gameFrame: game))
    #expect(ReconnectButtonLayout.defaultNormalizedOrigin(scale: 0.1, gameFrame: game)
      == ReconnectButtonLayout.defaultNormalizedOrigin(scale: 0.75, gameFrame: game))
  }
  @Test("a zero-height game frame gives a finite origin")
  func zeroHeightFrame() {
    let o = ReconnectButtonLayout.defaultNormalizedOrigin(scale: 1, gameFrame: CGRect(x: 0, y: 0, width: 1000, height: 0))
    #expect(o == CGPoint(x: 0.735, y: 0))
    #expect(o.y.isFinite)
  }
}
