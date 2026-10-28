import Testing
@testable import AppCore

@Suite("Reconnect button visibility")
struct ReconnectButtonVisibilityTests {
  /// Button on, Hearthstone frontmost with a window, detector attached; the rest is up to each test.
  func show(button: Bool = true, window: Bool = true, frontmost: Bool = true, detector: Bool = true,
            inMatch: Bool = false, editing: Bool = false, feedback: Bool = false) -> Bool {
    ReconnectButtonVisibilityPolicy.shouldShow(buttonEnabled: button, hasGameWindow: window,
      gameFrontmost: frontmost, detectorAvailable: detector, inMatch: inMatch, isEditingLayout: editing,
      isShowingFeedback: feedback)
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
  @Test("without a match detector it falls back to showing whenever Hearthstone is frontmost")
  func detectorFallback() {
    #expect(show(detector: false))
    #expect(show(detector: false, inMatch: false))
    #expect(!show(frontmost: false, detector: false))
    #expect(!show(window: false, detector: false))
  }
  @Test("button setting off hides it in a match, in layout mode, with feedback and without a detector")
  func settingOff() {
    #expect(!show(button: false, inMatch: true))
    #expect(!show(button: false, editing: true))
    #expect(!show(button: false, feedback: true))
    #expect(!show(button: false, detector: false))
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
