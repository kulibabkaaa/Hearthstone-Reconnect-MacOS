import Testing
@testable import AppCore

/// Line shapes copied from real Hearthstone logs (Nov 2026); addresses and IDs are made up.
private enum Lines {
  static let game = "203.0.113.10:1119"
  static let otherGame = "198.51.100.20:1119"
  static let battleNet = "34.90.1.2:1119"
  static let newBattleNet = "34.90.7.8:1119"

  static func goto(_ time: String, _ address: String = game, reconnecting: Bool = false) -> String {
    "I \(time) Network.GotoGameServe() - address= \(address), game=1, client=2, spectateKey=x reconnecting=\(reconnecting ? "True" : "False")"
  }
  static func awake(_ time: String, from mode: String) -> String {
    "I \(time) Gameplay.Awake() - CurrentMode=GAMEPLAY, PrevMode=\(mode)"
  }
  static func started(_ time: String) -> String {
    "I \(time) SERVER_GAME_STARTED event - Loading Gameplay Scene"
  }
  static func leave(_ time: String) -> String {
    "I \(time) [GameNetLogger] Network.DisconnectFromGameServer() - Reason: EndGameScreen "
  }
  static func cleanDisconnect(_ time: String) -> String {
    "I \(time) [GameNetLogger] Network.OnGameServerDisconnectEvent() - Disconnected from game server with BNet error: ERROR_OK socket error: Success"
  }
  static func drop(_ time: String) -> String {
    "I \(time) Network.OnGameServerDisconnectEvent() - Disconnected from game server with BNet error: ERROR_RPC_CONNECTION_UNREACHABLE socket error: NetworkDown, Message: "
  }
  static func scene(_ time: String, from previous: String, to current: String) -> String {
    "D \(time) LoadingScreen.OnSceneLoaded() - prevMode=\(previous) currMode=\(current)"
  }
}

/// Drives a core one poll per second, like the app's monitor.
private struct Session {
  var core = MatchPresenceCore()
  var now: Double = 1_000

  mutating func poll(_ connections: [String]?, logs: [String] = [], seconds: Double = 1) -> MatchPresence {
    now += seconds
    core.ingest(logs.compactMap(MatchLogParser.parse), now: now)
    return core.evaluate(openConnections: connections, now: now)
  }
  /// Polls with the same connections for `seconds`; returns the presence after each poll.
  mutating func hold(_ connections: [String]?, for seconds: Int) -> [MatchPresence] {
    (0..<seconds).map { _ in poll(connections) }
  }
}

@Suite("Match presence: log lines")
struct MatchLogParserTests {
  @Test("the game server's address and the time of day come from the GotoGameServe line")
  func gotoLine() {
    let line = MatchLogParser.parse(Lines.goto("17:52:26.2315590"))
    #expect(line == MatchLogLine(time: 17 * 3600 + 52 * 60 + 26.2315590,
                                 event: .joined(address: Lines.game, fromMode: nil)))
    let prefixed = MatchLogParser.parse("I 00:48:02.7947330 [GameNetLogger] " + Lines.goto("x").dropFirst(4))
    #expect(prefixed?.event == .joined(address: Lines.game, fromMode: nil))
  }
  @Test("scene lines: Battlegrounds entry, reloads, menus")
  func sceneLines() {
    #expect(MatchLogParser.parse(Lines.awake("12:27:50.5893740", from: "BACON"))?.event
            == .joined(address: nil, fromMode: "BACON"))
    #expect(MatchLogParser.parse(Lines.scene("12:27:52.1702790", from: "BACON", to: "GAMEPLAY"))?.event
            == .joined(address: nil, fromMode: "BACON"))
    #expect(MatchLogParser.parse(Lines.scene("12:26:48.7417480", from: "HUB", to: "BACON"))?.event == .left)
    #expect(MatchLogParser.parse(Lines.started("12:27:50.4723830"))?.event == .joined(address: nil, fromMode: nil))
    // The line TrackerRecovery appends, padded to 87 bytes.
    #expect(MatchLogParser.parse("D 17:49:05.7684200 LoadingScreen.OnSceneLoaded() - prevMode=BACON    currMode=GAMEPLAY")?
      .event == .joined(address: nil, fromMode: "BACON"))
    #expect(MatchLogParser.parse("D 12:26:48.0000000 LoadingScreen.OnScenePreUnload() - prevMode=HUB nextMode=BACON") == nil)
  }
  @Test("a clean leave, a drop, and the ERROR_OK line that follows a clean leave")
  func disconnectLines() {
    #expect(MatchLogParser.parse(Lines.leave("12:30:52.2423410"))?.event == .left)
    #expect(MatchLogParser.parse(Lines.drop("17:49:03.8321510"))?.event == .dropped)
    #expect(MatchLogParser.parse(Lines.cleanDisconnect("00:49:58.7277890")) == nil)
  }
  @Test("unrelated lines, stack traces and lines without a time stamp are ignored")
  func noise() {
    #expect(MatchLogParser.parse("W 12:27:51.3032560 CardBackManager SetDeckCardBack(): cardBack is null!") == nil)
    #expect(MatchLogParser.parse("UnityEngine.Debug:CallOverridenDebugHandler(Exception, Object)") == nil)
    #expect(MatchLogParser.parse("Network.DisconnectFromGameServer() - Reason: EndGameScreen") == nil)
    #expect(MatchLogParser.parse("I 25:00:00.0 Network.DisconnectFromGameServer()") == nil)
  }
}

@Suite("Match presence: decisions")
struct MatchPresenceCoreTests {
  @Test("menus: one connection on the game port is never a match, even for ten minutes")
  func menuIdle() {
    var session = Session()
    #expect(session.core.detectorState == .connecting)
    #expect(session.hold([Lines.battleNet, "17.1.2.3:443"], for: 600).allSatisfy { $0 == .notInMatch })
    #expect(session.core.detectorState == .attached)
  }

  @Test("an unlogged match (seen live 15 Nov): two connections count after two polls")
  func unloggedMatch() {
    var session = Session()
    _ = session.hold([Lines.battleNet], for: 5)
    #expect(session.poll([Lines.battleNet, Lines.game]) == .notInMatch)
    #expect(session.poll([Lines.battleNet, Lines.game]) == .inMatch)
  }

  @Test("a logged game server that is open counts at once")
  func loggedServerOpens() {
    var session = Session()
    _ = session.hold([Lines.battleNet], for: 3)
    #expect(session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("12:27:44.8050710")]) == .inMatch)
  }

  @Test("Battle.net briefly overlapping itself while it reconnects isn't a match")
  func battleNetOverlap() {
    var session = Session()
    _ = session.hold([Lines.battleNet], for: 3)
    #expect(session.poll([Lines.battleNet, Lines.newBattleNet]) == .notInMatch)
    #expect(session.hold([Lines.newBattleNet], for: 10).allSatisfy { $0 == .notInMatch })
  }

  @Test("a logged match end hides it at the next poll")
  func loggedEnd() {
    var session = Session()
    _ = session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("12:27:44.80"), Lines.awake("12:27:50.58", from: "BACON")])
    #expect(session.core.presence == .inMatch)
    #expect(session.poll([Lines.battleNet], logs: [Lines.leave("12:30:52.24"), Lines.cleanDisconnect("12:30:52.24")]) == .notInMatch)
  }

  @Test("a logged end while the game connection still lingers ends it too")
  func lingeringConnection() {
    var session = Session()
    _ = session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("12:27:44.80")])
    #expect(session.poll([Lines.battleNet, Lines.game], logs: [Lines.leave("12:30:52.24")]) == .notInMatch)
    #expect(session.hold([Lines.battleNet, Lines.game], for: 5).allSatisfy { $0 == .notInMatch })
  }

  @Test("an unlogged end hides it after the grace period, within 10 s")
  func unloggedEnd() {
    var session = Session()
    _ = session.hold([Lines.battleNet, Lines.game], for: 2)
    #expect(session.core.presence == .inMatch)
    let after = session.hold([Lines.battleNet], for: 10)
    let firstHidden = after.firstIndex(of: .notInMatch).map { $0 + 1 }
    #expect(firstHidden == Int(MatchPresenceCore.leaveGrace))
    #expect(after.suffix(from: firstHidden ?? 0).allSatisfy { $0 == .notInMatch })
  }

  @Test("a reconnect mid-match never hides it: a closed game connection is held while Hearthstone reconnects")
  func reconnectHold() {
    var session = Session()
    _ = session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("17:48:16.55")])
    // The app asked for a reconnect: the game connection is gone for a while (a slow network).
    session.core.noteReconnect(at: session.now)
    #expect(session.hold([Lines.battleNet], for: 15).allSatisfy { $0 == .inMatch })
    #expect(session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("17:49:03.85", reconnecting: true)]) == .inMatch)
    // A drop Hearthstone logged on its own holds it the same way.
    #expect(session.poll([Lines.battleNet], logs: [Lines.drop("17:50:00.00")]) == .inMatch)
    #expect(session.hold([Lines.battleNet], for: 15).allSatisfy { $0 == .inMatch })
    #expect(session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("17:50:16.00", reconnecting: true)]) == .inMatch)
  }

  @Test("an unlogged match after a logged one (the 15 Nov case) still counts")
  func unloggedMatchAfterLoggedEnd() {
    var session = Session()
    _ = session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("12:27:44.80")])
    #expect(session.poll([Lines.battleNet], logs: [Lines.leave("12:30:52.24")]) == .notInMatch)
    _ = session.hold([Lines.battleNet], for: 30)
    // The next match goes to another server and logs nothing.
    _ = session.poll([Lines.battleNet, Lines.otherGame])
    #expect(session.poll([Lines.battleNet, Lines.otherGame]) == .inMatch)
    // It ends unlogged: the grace period, not the old leave, hides it.
    let after = session.hold([Lines.battleNet], for: 10)
    #expect(after.prefix(Int(MatchPresenceCore.leaveGrace) - 1).allSatisfy { $0 == .inMatch })
    #expect(after.last == .notInMatch)
  }

  @Test("a new match on the same server address as the last one counts once the old connection closed")
  func sameServerAgain() {
    var session = Session()
    _ = session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("12:27:44.80")])
    _ = session.poll([Lines.battleNet, Lines.game], logs: [Lines.leave("12:30:52.24")])
    _ = session.hold([Lines.battleNet], for: 20)
    #expect(session.poll([Lines.battleNet, Lines.game]) == .inMatch)
  }

  @Test("app started in menus after a logged match: two old connections don't count until a new one opens")
  func staleAtLaunch() {
    var session = Session()
    let backlog = [Lines.goto("12:27:44.80"), Lines.awake("12:27:50.58", from: "BACON"), Lines.leave("12:30:52.24")]
    #expect(session.poll([Lines.battleNet, Lines.newBattleNet], logs: backlog) == .notInMatch)
    #expect(session.hold([Lines.battleNet, Lines.newBattleNet], for: 30).allSatisfy { $0 == .notInMatch })
    _ = session.poll([Lines.battleNet, Lines.newBattleNet, Lines.otherGame])
    #expect(session.poll([Lines.battleNet, Lines.newBattleNet, Lines.otherGame]) == .inMatch)
  }

  @Test("a menu scene in LoadingScreen.log counts as a clean leave")
  func menuScene() {
    var session = Session()
    _ = session.poll([Lines.battleNet, Lines.game], logs: [Lines.scene("12:27:52.17", from: "BACON", to: "GAMEPLAY")])
    _ = session.poll([Lines.battleNet, Lines.game])
    #expect(session.core.presence == .inMatch)
    #expect(session.poll([Lines.battleNet], logs: [Lines.scene("12:31:00.00", from: "GAMEPLAY", to: "BACON")]) == .notInMatch)
  }

  @Test("Battlegrounds, Duos and games of unknown mode count; Constructed and other modes don't")
  func modes() {
    for (mode, expected) in [("BACON", MatchPresence.inMatch), ("TOURNAMENT", .notInMatch), ("DRAFT", .notInMatch),
                             ("LETTUCE_PLAY", .notInMatch), ("LOGIN", .inMatch)] {
      var session = Session()
      #expect(session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("10:00:00.0"), Lines.awake("10:00:05.0", from: mode)])
              == expected, "entered from \(mode)")
    }
    // A reload keeps the kind; a reconnect inside a Constructed game stays hidden.
    var session = Session()
    _ = session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("10:00:00.0"), Lines.awake("10:00:05.0", from: "TOURNAMENT")])
    #expect(session.poll([Lines.battleNet, Lines.game], logs: [Lines.awake("10:01:00.0", from: "GAMEPLAY")]) == .notInMatch)
    // After it ends unlogged, the next (unlogged) game isn't judged by the old mode.
    _ = session.hold([Lines.battleNet], for: 10)
    _ = session.poll([Lines.battleNet, Lines.otherGame])
    #expect(session.poll([Lines.battleNet, Lines.otherGame]) == .inMatch)
  }

  @Test("the same event read again from the other log, or flushed late, doesn't undo a newer one")
  func outOfOrderLines() {
    var session = Session()
    _ = session.poll([Lines.battleNet, Lines.game], logs: [Lines.goto("12:27:44.80")])
    _ = session.poll([Lines.battleNet], logs: [Lines.leave("12:30:52.24")])
    _ = session.hold([Lines.battleNet], for: 20)
    _ = session.poll([Lines.battleNet, Lines.otherGame], logs: [Lines.goto("12:40:00.00", Lines.otherGame)])
    // Hearthstone.log flushes its copy of the old leave late: the match goes on.
    #expect(session.poll([Lines.battleNet, Lines.otherGame], logs: [Lines.leave("12:30:52.24")]) == .inMatch)
    #expect(session.core.phase == .joined)
  }

  @Test("time stamps across midnight keep their order")
  func midnight() {
    #expect(MatchPresenceCore.isEarlier(23 * 3600 + 59 * 60, than: 30))
    #expect(!MatchPresenceCore.isEarlier(30, than: 23 * 3600 + 59 * 60))
    #expect(MatchPresenceCore.isEarlier(10, than: 20))
  }

  @Test("unreadable connections: unknown after three polls, back to normal when they read again")
  func unreadable() {
    var session = Session()
    #expect(session.poll(nil) == .notInMatch && session.core.detectorState == .connecting)
    _ = session.poll(nil)
    #expect(session.poll(nil) == .unknown && session.core.detectorState == .unavailable)
    #expect(session.poll([Lines.battleNet]) == .notInMatch && session.core.detectorState == .attached)
    // A single unreadable poll mid-match keeps the match.
    _ = session.hold([Lines.battleNet, Lines.game], for: 2)
    #expect(session.poll(nil) == .inMatch)
  }

  @Test("only public addresses on the game port (or a logged server's port) count")
  func addressFilter() {
    var session = Session()
    #expect(session.hold([Lines.battleNet, "127.0.0.1:1119", "192.168.1.5:1119", "10.0.0.2:1119"], for: 5)
      .allSatisfy { $0 == .notInMatch })
    #expect(session.hold([Lines.battleNet, "203.0.113.10:443"], for: 5).allSatisfy { $0 == .notInMatch })
    #expect(session.poll([Lines.battleNet, "203.0.113.10:3724"], logs: [Lines.goto("10:00:00.0", "203.0.113.10:3724")]) == .inMatch)
  }
}

@Suite("Reconnect button match signal")
struct ReconnectButtonMatchSignalTests {
  typealias P = ReconnectButtonVisibilityPolicy

  @Test("the monitor decides; it works without the memory reader")
  func monitorAlone() {
    for reader in [MatchDetectorState.connecting, .attached, .unavailable] {
      #expect(P.matchSignal(monitor: .attached, monitorInMatch: true, reader: reader, readerInMatch: false) == (.attached, true))
      #expect(P.matchSignal(monitor: .attached, monitorInMatch: false, reader: reader, readerInMatch: false) == (.attached, false))
    }
  }
  @Test("an attached reader can add a match, never take one away; a detached reader is ignored")
  func readerAdds() {
    #expect(P.matchSignal(monitor: .attached, monitorInMatch: false, reader: .attached, readerInMatch: true) == (.attached, true))
    #expect(P.matchSignal(monitor: .connecting, monitorInMatch: false, reader: .attached, readerInMatch: true) == (.attached, true))
    #expect(P.matchSignal(monitor: .attached, monitorInMatch: false, reader: .unavailable, readerInMatch: true) == (.attached, false))
    #expect(P.matchSignal(monitor: .connecting, monitorInMatch: true, reader: .unavailable, readerInMatch: false) == (.connecting, false))
    #expect(P.matchSignal(monitor: .unavailable, monitorInMatch: false, reader: .connecting, readerInMatch: false) == (.unavailable, false))
  }
}
