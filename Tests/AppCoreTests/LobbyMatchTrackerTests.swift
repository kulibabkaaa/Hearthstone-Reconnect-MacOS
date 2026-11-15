import Testing

@testable import AppCore

/// One poll: seconds, the game id read then, and whether the session log's newest connection line is a clean leave.
private typealias Poll = (time: Double, gameUUID: String?, left: Bool)

private func run(_ polls: [Poll], tracker: inout LobbyMatchTracker) -> [LobbyMatchTracker.Report] {
  polls.map { tracker.observe(gameUUID: $0.gameUUID, leftGameServer: $0.left, now: $0.time) }
}

private func run(_ polls: [Poll]) -> [LobbyMatchTracker.Report] {
  var tracker = LobbyMatchTracker()
  return run(polls, tracker: &tracker)
}

@Suite("Lobby match tracker")
struct LobbyMatchTrackerTests {
  @Test("the same game id back after 1 s is the same match: no end, no new start")
  func sameIDBack() {
    #expect(run([(0, "a", false), (1, nil, false), (2, "a", false), (3, "a", false)])
      == [.started("a"), .holding("a"), .ongoing("a"), .ongoing("a")])
  }

  @Test("a gap just under the hold is still held")
  func gapUnderHold() {
    #expect(run([(0, "a", false), (1, nil, false), (2, nil, false), (3.9, "a", false)])
      == [.started("a"), .holding("a"), .holding("a"), .ongoing("a")])
  }

  @Test("a different game id ends the first match and starts the new one at once")
  func differentID() {
    #expect(run([(0, "a", false), (1, "b", false)]) == [.started("a"), .replaced(ended: "a", started: "b")])
    #expect(run([(0, "a", false), (1, nil, false), (2, "b", false)])
      == [.started("a"), .holding("a"), .replaced(ended: "a", started: "b")])
  }

  @Test("with no clean leave logged, the hold running out ends the match 3 s after the id vanished")
  func holdExpires() {
    #expect(run([(0, "a", false), (10, nil, false), (11, nil, false), (12, nil, false), (13, nil, false),
                 (14, nil, false)])
      == [.started("a"), .holding("a"), .holding("a"), .holding("a"), .ended("a"), .noMatch])
  }

  @Test("a clean leave of the game server ends the match at once, even while its game state lingers")
  func cleanLeave() {
    #expect(run([(0, "a", false), (5, "a", true), (6, "a", true), (12, nil, true), (13, nil, true)])
      == [.started("a"), .ended("a"), .noMatch, .noMatch, .noMatch])
  }

  @Test("a clean leave during a hold ends the match without waiting for the hold")
  func cleanLeaveDuringHold() {
    #expect(run([(0, "a", false), (1, nil, false), (1.5, nil, true)])
      == [.started("a"), .holding("a"), .ended("a")])
  }

  @Test("the next match starts even while the previous match's game state still lingers")
  func nextMatchAfterEndScreen() {
    // Ended on the end screen; the player queues again: the log shows a new join, the old state is still there,
    // then the new game's id appears.
    #expect(run([(0, "a", false), (5, "a", true), (8, "a", false), (9, nil, false), (12, "b", false)])
      == [.started("a"), .ended("a"), .noMatch, .noMatch, .started("b")])
  }

  @Test("attaching during an end screen never starts that finished match, even once the next join is logged")
  func attachDuringEndScreen() {
    #expect(run([(0, "a", true), (1, "a", true), (2, "a", false), (3, nil, false)])
      == [.noMatch, .noMatch, .noMatch, .noMatch])
  }

  @Test("a new game's id seen one poll before its join line reaches the log still starts")
  func newIDBeforeJoinLine() {
    // The previous game's leave is still the newest log line when the new id first appears.
    #expect(run([(0, "b", true), (1, "b", false), (2, "b", false)]) == [.noMatch, .started("b"), .ongoing("b")])
    // Same while a match is reported: a different id under a stale leave ends the old match but isn't latched.
    #expect(run([(0, "a", false), (1, "b", true), (2, "b", false)])
      == [.started("a"), .ended("a"), .started("b")])
  }

  @Test("a finished match's id is forgotten once its state is gone: the same id later is a new match")
  func finishedIDForgotten() {
    #expect(run([(0, "a", false), (5, "a", true), (6, nil, true), (7, "a", false)])
      == [.started("a"), .ended("a"), .noMatch, .started("a")])
  }

  @Test("while Hearthstone says it is resuming a game, a vanished id is held past the usual 3 s")
  func resumingHold() {
    var tracker = LobbyMatchTracker()
    #expect(tracker.observe(gameUUID: "a", leftGameServer: false, now: 0) == .started("a"))
    #expect(tracker.observe(gameUUID: nil, leftGameServer: false, resuming: true, now: 1) == .holding("a"))
    #expect(tracker.observe(gameUUID: nil, leftGameServer: false, resuming: true, now: 20) == .holding("a"))
    #expect(tracker.observe(gameUUID: "a", leftGameServer: false, resuming: true, now: 21) == .ongoing("a"))
    // Once it no longer says so, the normal hold applies again.
    #expect(tracker.observe(gameUUID: nil, leftGameServer: false, now: 30) == .holding("a"))
    #expect(tracker.observe(gameUUID: nil, leftGameServer: false, now: 33) == .ended("a"))
  }

  @Test("Hearthstone quitting during a hold hands back the held match and starts over")
  func quitDuringHold() {
    var tracker = LobbyMatchTracker()
    _ = run([(0, "a", false), (1, nil, false)], tracker: &tracker)
    #expect(tracker.reportedGameUUID == "a")
    #expect(tracker.hearthstoneExited() == "a")
    #expect(tracker.reportedGameUUID == nil)
    #expect(tracker.observe(gameUUID: nil, leftGameServer: false, now: 2) == .noMatch)
    #expect(tracker.hearthstoneExited() == nil)
  }

  /// The final test on 15 Nov 2026 (main 63d38fe): polls once a second, game id gaps and GameNetLogger lines as
  /// recorded. Joined 22:15:58.28; id read from 22:16:05; Hearthstone rebuilt its state (id missing ~1 s) at 22:16:10,
  /// 22:17:07 and 22:17:12; reconnects (new GotoGameServe) at 22:17:06, :12, :34, :40; clean leave
  /// (DisconnectFromGameServer, end screen) at 22:17:53.45; game state gone from 22:18:01.
  @Test("replaying the final test: one start, no end/start blips, one end right after leaving the server")
  func finalTestReplay() {
    func seconds(_ h: Double, _ m: Double, _ s: Double) -> Double { h * 3600 + m * 60 + s }
    let gaps: [ClosedRange<Double>] = [seconds(22, 16, 10)...seconds(22, 16, 10.9),
                                       seconds(22, 17, 7)...seconds(22, 17, 7.9),
                                       seconds(22, 17, 12)...seconds(22, 17, 12.9)]
    let leftAt = seconds(22, 17, 53.45)
    var polls: [Poll] = []
    var time = seconds(22, 16, 0)
    while time <= seconds(22, 18, 10) {
      let present = time >= seconds(22, 16, 5) && time < seconds(22, 18, 1) && !gaps.contains { $0.contains(time) }
      polls.append((time, present ? "9c8df426" : nil, time >= leftAt))
      time += 1
    }
    let reports = run(polls)
    let changes = zip(polls, reports).filter {
      switch $0.1 {
      case .started, .ended, .replaced: true
      default: false
      }
    }
    #expect(changes.map(\.1) == [.started("9c8df426"), .ended("9c8df426")])
    #expect(changes.first?.0.time == seconds(22, 16, 5))
    let endTime = changes.last?.0.time ?? 0
    #expect(endTime == seconds(22, 17, 54))
    #expect(endTime - leftAt <= 5)
  }
}

@Suite("Session log: clean leave of the game server")
struct SessionLogLeftGameServerTests {
  private let join = "I 22:15:58.28 Network.GotoGameServe() - address= 1.2.3.4:1119, game=x, client=x, spectateKey=x reconnecting=False\n"
  private let drop = "I 22:17:06.64 Network.OnGameServerDisconnectEvent() - Disconnected from game server with BNet error: ERROR_RPC_CONNECTION_UNREACHABLE\n"
  private let rejoin = "I 22:17:06.66 Network.GotoGameServe() - address= 1.2.3.4:1119, game=x, client=x, spectateKey=x reconnecting=True\n"
  private let leave = "I 22:17:53.45 Network.DisconnectFromGameServer() - Reason: EndGameScreen \n"

  @Test("a join alone, or a reconnect, isn't a leave")
  func notALeave() {
    #expect(!LobbyReconnectPolicy.sessionLogSaysLeftGameServer(join))
    #expect(!LobbyReconnectPolicy.sessionLogSaysLeftGameServer(join + drop + rejoin))
    #expect(!LobbyReconnectPolicy.sessionLogSaysLeftGameServer(""))
  }

  @Test("a clean leave after the last join is a leave; a new join after it isn't")
  func cleanLeaveLines() {
    #expect(LobbyReconnectPolicy.sessionLogSaysLeftGameServer(join + drop + rejoin + leave))
    #expect(!LobbyReconnectPolicy.sessionLogSaysLeftGameServer(join + leave + join))
    #expect(LobbyReconnectPolicy.sessionLogSaysLeftGameServer(leave))
  }
}
