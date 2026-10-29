import Testing
@testable import AppCore

@Suite("Reconnect button visibility")
struct ReconnectButtonVisibilityTests {
  /// Button on, Hearthstone frontmost with a window, detector attached; the rest is up to each test.
  func show(button: Bool = true, window: Bool = true, frontmost: Bool = true,
            detector: MatchDetectorState = .attached, inMatch: Bool = false, editing: Bool = false,
            feedback: Bool = false) -> Bool {
    ReconnectButtonVisibilityPolicy.shouldShow(buttonEnabled: button, hasGameWindow: window,
      gameFrontmost: frontmost, detector: detector, inMatch: inMatch, isEditingLayout: editing,
      isShowingFeedback: feedback)
  }
  /// The tracker after `signals`, from a fresh start.
  func state(_ signals: [MatchDetectorSignal]) -> MatchDetectorState {
    var tracker = MatchDetectorTracker()
    for signal in signals { tracker.handle(signal) }
    return tracker.state
  }

  @Test("hidden with no match, shown during a match, hidden again after it ends")
  func matchLifecycle() {
    #expect(!show())
    #expect(show(inMatch: true))
    #expect(!show(inMatch: false))
  }
  @Test("layout mode shows it outside a match; it hides again when the session ends")
  func layoutOutsideMatch() {
    #expect(show(editing: true))
    #expect(!show(editing: false))
  }
  @Test("a detector that won't attach falls back to showing whenever Hearthstone is frontmost")
  func detectorFallback() {
    #expect(show(detector: .unavailable))
    #expect(!show(frontmost: false, detector: .unavailable))
    #expect(!show(window: false, detector: .unavailable))
  }
  @Test("while the detector is still connecting the button stays hidden; layout mode and a result still show it")
  func connectingHides() {
    #expect(!show(detector: .connecting))
    #expect(!show(detector: .connecting, inMatch: true))
    #expect(show(detector: .connecting, editing: true))
    #expect(show(detector: .connecting, feedback: true))
  }

  @Test("launch and login: hidden while connecting, hidden in the menu, shown in a match, hidden after it")
  func launchSequence() {
    var tracker = MatchDetectorTracker()
    #expect(tracker.state == .connecting)
    // Reader started, helper waiting for Hearthstone, first attach failing while the game loads.
    for signal: MatchDetectorSignal in [.starting, .waiting, .waiting] {
      tracker.handle(signal)
      #expect(tracker.state == .connecting)
      #expect(!show(detector: tracker.state))
    }
    tracker.handle(.attached)
    #expect(tracker.state == .attached)
    #expect(!show(detector: tracker.state, inMatch: false))
    #expect(show(detector: tracker.state, inMatch: true))
    #expect(!show(detector: tracker.state, inMatch: false))
  }
  @Test("lobby access never approved, declined, or the attach gave up: fallback shows")
  func neverApproved() {
    #expect(state([.starting, .waiting, .gaveUp]) == .unavailable)
    #expect(show(detector: state([.starting, .waiting, .gaveUp])))
    // Still unavailable after the helper's later checks repeat it.
    #expect(state([.starting, .gaveUp, .gaveUp]) == .unavailable)
    // Access granted later (the quiet helper checks again): back to the match rule.
    #expect(state([.starting, .gaveUp, .attached]) == .attached)
  }
  @Test("a helper that keeps failing without attaching counts as unavailable")
  func persistentHelperFailure() {
    let limit = MatchDetectorTracker.helperFailuresBeforeGivingUp
    #expect(limit == 3)
    let belowLimit = [MatchDetectorSignal](repeating: .helperFailed, count: limit - 1)
    #expect(state([.starting] + belowLimit) == .connecting)
    // The relaunched helper reporting it waits doesn't hide a fallback already given.
    #expect(state([.starting] + belowLimit + [.helperFailed]) == .unavailable)
    #expect(state([.starting] + belowLimit + [.helperFailed, .waiting]) == .unavailable)
    #expect(show(detector: state([.starting] + belowLimit + [.helperFailed])))
    // Attaching in between resets the count; so does a fresh start for a new game or a retry.
    #expect(state([.starting] + belowLimit + [.attached, .helperFailed]) == .connecting)
    #expect(state([.starting] + belowLimit + [.starting, .helperFailed]) == .connecting)
    #expect(state([.starting] + belowLimit + [.helperFailed, .starting]) == .connecting)
  }
  @Test("connecting with no progress for the timeout counts as unavailable; attached or given up stays put")
  func connectingTimeout() {
    #expect(MatchDetectorTracker.connectingTimeout == 60)
    #expect(state([.starting, .waiting, .timedOut]) == .unavailable)
    #expect(show(detector: state([.starting, .waiting, .timedOut])))
    #expect(state([.starting, .attached, .timedOut]) == .attached)
    #expect(state([.starting, .gaveUp, .timedOut]) == .unavailable)
    // Attaching later still wins; a fresh start goes back to connecting.
    #expect(state([.starting, .timedOut, .attached]) == .attached)
    #expect(state([.starting, .timedOut, .starting]) == .connecting)
  }
  @Test("helper restart mid-session hides the button while it reconnects, unless a result is showing")
  func helperRestartMidSession() {
    let restarting = state([.starting, .attached, .helperFailed])
    #expect(restarting == .connecting)
    #expect(!show(detector: restarting))
    #expect(show(detector: restarting, feedback: true))
    // A new Hearthstone process restarts the helper the same way.
    #expect(state([.starting, .attached, .starting, .waiting]) == .connecting)
    #expect(state([.starting, .attached, .helperFailed, .waiting, .attached]) == .attached)
  }
  @Test("button setting off hides it in a match, in layout mode, with feedback and without a detector")
  func settingOff() {
    #expect(!show(button: false, inMatch: true))
    #expect(!show(button: false, editing: true))
    #expect(!show(button: false, feedback: true))
    #expect(!show(button: false, detector: .unavailable))
    #expect(!show(button: false, detector: .connecting))
  }
  @Test("no game window or a background game hides it, even in a match or layout mode")
  func gameWindowAndFocus() {
    #expect(!show(window: false, inMatch: true, editing: true))
    #expect(!show(frontmost: false, inMatch: true, editing: true))
  }
  @Test("a reconnect result already on screen stays up when the match signal drops")
  func feedbackHold() {
    #expect(show(feedback: true))
    for phase: ReconnectButtonPhase in [.reconnecting, .succeeded, .noGameFound, .failed] {
      #expect(ReconnectButtonVisibilityPolicy.isReconnectFeedback(phase))
    }
    for phase: ReconnectButtonPhase in [.ready, .unavailable, .cooldown(seconds: 3)] {
      #expect(!ReconnectButtonVisibilityPolicy.isReconnectFeedback(phase))
    }
  }

  @Test("reader mode: lobby info on runs the full reader; off runs match detection only for the button while the game runs")
  func readerModes() {
    typealias P = ReconnectButtonVisibilityPolicy
    for button in [true, false] {
      for running in [true, false] {
        #expect(P.readerMode(lobbyEnabled: true, buttonEnabled: button, hearthstoneRunning: running) == .lobby)
      }
    }
    #expect(P.readerMode(lobbyEnabled: false, buttonEnabled: true, hearthstoneRunning: true) == .matchDetectionOnly)
    #expect(P.readerMode(lobbyEnabled: false, buttonEnabled: true, hearthstoneRunning: false) == .off)
    #expect(P.readerMode(lobbyEnabled: false, buttonEnabled: false, hearthstoneRunning: true) == .off)
    #expect(P.readerMode(lobbyEnabled: false, buttonEnabled: false, hearthstoneRunning: false) == .off)
  }

  @Test("Solo and Duos count as a match; an unknown mode doesn't yet")
  func matchModes() {
    #expect(ReconnectButtonVisibilityPolicy.countsDuos)
    #expect(ReconnectButtonVisibilityPolicy.countsAsMatch(.publish))
    #expect(ReconnectButtonVisibilityPolicy.countsAsMatch(.unsupported))
    #expect(!ReconnectButtonVisibilityPolicy.countsAsMatch(.unsupported, countsDuos: false))
    #expect(!ReconnectButtonVisibilityPolicy.countsAsMatch(.waitForMode))
    #expect(LobbyReconnectPolicy.liveCaptureDisposition(mode: "duos") == .unsupported)
  }
}

@Suite("Reconnect telemetry")
struct ReconnectTelemetryTests {
  @Test("the success signal carries only the source, under reconnect.source")
  func successParameters() {
    #expect(ReconnectTelemetry.sourceParameter == "reconnect.source")
    let expected: [ReconnectSource: String] = [
      .shortcut: "shortcut", .overlayButton: "overlayButton", .mainWindow: "mainWindow", .menu: "menu",
    ]
    #expect(Set(ReconnectSource.allCases) == Set(expected.keys))
    for (source, value) in expected {
      #expect(ReconnectTelemetry.successParameters(source: source) == ["reconnect.source": value])
    }
  }
}
