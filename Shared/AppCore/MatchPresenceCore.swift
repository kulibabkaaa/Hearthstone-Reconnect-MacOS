import Foundation

/// What a Hearthstone log line says about the game connection.
public enum MatchLogEvent: Equatable, Sendable {
  /// Joining or (re)loading a game: `Network.GotoGameServe() - address=`, `SERVER_GAME_STARTED`, or the gameplay
  /// scene loading. `address` is "host:port" when the line names the game server. `fromMode` is the scene the game
  /// was entered from (`BACON` for Battlegrounds), when the line says.
  case joined(address: String?, fromMode: String?)
  /// The game connection dropped and Hearthstone reconnects (`OnGameServerDisconnectEvent` with an error).
  case dropped
  /// Hearthstone left the game (`Network.DisconnectFromGameServer()`), or a menu scene loaded (`LoadingScreen.log`,
  /// with that scene as `toMode`).
  case left(toMode: String?)
}

public struct MatchLogLine: Equatable, Sendable {
  /// Seconds since local midnight, from the line's own time stamp.
  public let time: TimeInterval
  public let event: MatchLogEvent

  public init(time: TimeInterval, event: MatchLogEvent) {
    self.time = time
    self.event = event
  }
}

/// Reads the lines of `GameNetLogger.log`, `Hearthstone.log` and (when `log.config` has it) `LoadingScreen.log` that
/// say something about the game connection. Every other line is nil.
public enum MatchLogParser {
  private static let gotoMarker = "Network.GotoGameServe() - address="

  public static func parse<S: StringProtocol>(_ line: S) -> MatchLogLine? {
    // Every line of interest has one of these; most of a busy Hearthstone.log (card art warnings) has neither.
    guard line.contains("Game") || line.contains("currMode=") else { return nil }
    let text = String(line)
    guard let event = event(in: text), let time = timeOfDay(in: text) else { return nil }
    return MatchLogLine(time: time, event: event)
  }

  private static func event(in line: String) -> MatchLogEvent? {
    if let range = line.range(of: gotoMarker) {
      let value = line[range.upperBound...].drop { $0 == " " }
      let address = value.prefix { $0 != "," && $0 != " " }
      return .joined(address: address.contains(":") ? String(address) : nil, fromMode: nil)
    }
    if line.contains("Network.DisconnectFromGameServer()") { return .left(toMode: nil) }
    if line.contains("Network.OnGameServerDisconnectEvent()") {
      // ERROR_OK follows a clean DisconnectFromGameServer; anything else is a drop Hearthstone recovers from.
      return line.contains("error: ERROR_OK") ? nil : .dropped
    }
    if line.contains("SERVER_GAME_STARTED event - "), line.contains("Gameplay Scene") {
      return .joined(address: nil, fromMode: nil)
    }
    if line.contains("Gameplay.Awake()") {
      return .joined(address: nil, fromMode: value(of: "PrevMode=", in: line))
    }
    if line.contains("LoadingScreen.OnSceneLoaded()"), let current = value(of: "currMode=", in: line) {
      return current == "GAMEPLAY" ? .joined(address: nil, fromMode: value(of: "prevMode=", in: line))
        : .left(toMode: current)
    }
    return nil
  }

  private static func value(of key: String, in line: String) -> String? {
    guard let range = line.range(of: key) else { return nil }
    let value = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    return value.isEmpty ? nil : String(value)
  }

  /// "I 17:52:26.2315590 …" → seconds since midnight.
  static func timeOfDay(in line: String) -> TimeInterval? {
    let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard fields.count >= 2, fields[0].count == 1 else { return nil }
    let parts = fields[1].split(separator: ":")
    guard parts.count == 3, let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Double(parts[2]),
          (0..<24).contains(hours), (0..<60).contains(minutes), seconds >= 0, seconds < 61 else { return nil }
    return TimeInterval(hours * 3600 + minutes * 60) + seconds
  }
}

/// Whether the player is in a match, as Hearthstone's open connections and logs say. Drives the Reconnect button;
/// needs no memory reading and no `log.config`.
public enum MatchPresence: Equatable, Sendable {
  case inMatch
  case notInMatch
  /// Hearthstone's connections can't be read. The button falls back to showing whenever the game is in front.
  case unknown
}

/// Decides `MatchPresence` from Hearthstone's open TCP connections (polled about once a second) and the log lines
/// read since the last poll.
///
/// The connections are the ground truth. Game servers and Battle.net both use port 1119: in menus Hearthstone has one
/// connection there (Battle.net), in a match two (the game server too). A connection to a game server the logs named
/// counts at once; two connections on the port count once they are seen on `confirmPolls` polls in a row, so
/// Battle.net briefly overlapping itself while it reconnects doesn't count. Hearthstone doesn't always log a new match's game
/// server, so the logs are never required. They only help:
/// - A logged clean leave (or a menu scene) ends the match at once instead of after the grace period. Until a new
///   connection opens after it, the connections that were open then don't count as a match.
/// - A game entered from a scene other than Battlegrounds (Constructed, Arena, Mercenaries, …) isn't a match for the
///   button. Without a logged scene the match counts, so Duos and unlogged matches still show it. When
///   `LoadingScreen.log` names the menu the player was in, a game-mode menu decides before the game's own scene
///   loads, so those games don't flash the button.
/// - A reconnect (logged drop, or one the app started) keeps the match for `reconnectHold`, not `leaveGrace`, while
///   the game connection is closed. The hold ends once the connection is back.
public struct MatchPresenceCore: Equatable, Sendable {
  public static let gamePort: UInt16 = 1119
  /// Polls in a row with two connections on the game port before they count as a match (about 2–3 s).
  public static let confirmPolls = 3
  /// How long a match outlasts its game connection when nothing says it ended.
  public static let leaveGrace: TimeInterval = 6
  /// How long it outlasts it while Hearthstone reconnects.
  public static let reconnectHold: TimeInterval = 20
  /// A reconnect whose game connection is still open this long after it was asked for no longer holds the match.
  public static let reconnectSettle: TimeInterval = 5
  /// Unreadable polls in a row before the presence is `unknown`.
  public static let unreadablePollsBeforeUnknown = 3
  /// With nothing applied for this long, a new line is taken as newer whatever its time of day says (time stamps
  /// carry no date, so after 12 h quiet the midnight rule would read every new line as older).
  public static let logOrderingWindow: TimeInterval = 6 * 3600
  /// Menu scenes that only start games other than Battlegrounds.
  static let otherGameMenus: Set<String> = ["TOURNAMENT", "DRAFT", "ADVENTURE", "TAVERN_BRAWL", "FRIENDLY",
                                            "PVP_DUNGEON_RUN", "FIRESIDE_GATHERING", "GAME_MODE"]

  public enum MatchKind: Equatable, Sendable { case unknown, battlegrounds, other }
  public enum LogPhase: Equatable, Sendable { case none, joined, dropped, left }

  public private(set) var presence = MatchPresence.notInMatch
  /// False until the first poll that could read the connections.
  public private(set) var hasVerdict = false
  /// Socket evidence of a game connection, kept through the grace period. `presence` adds the mode check.
  public private(set) var isConnected = false
  public private(set) var phase = LogPhase.none
  public private(set) var kind = MatchKind.unknown
  /// Counts of the last poll, for the local log (never addresses).
  public private(set) var lastGamePortConnections = 0
  public private(set) var lastSawLoggedGameServer = false

  private var phaseTime: TimeInterval?
  private var phaseObservedAt: TimeInterval?
  /// What the menu the player was last in starts (`LoadingScreen.log` only). Used while the game's own scene is
  /// unknown.
  private var menuKind = MatchKind.unknown
  /// Set by a logged drop or a reconnect the app asked for; ends when the game connection is back.
  private var reconnectSince: TimeInterval?
  private var reconnectGapSeen = false
  private var phaseCategory: LogPhase = .none
  private var leaveTime: TimeInterval?
  private var leaveObservedAt: TimeInterval?
  private var leaveSnapshotPending = false
  /// Connections open when the latest leave was seen, minus the ones that closed since.
  private var connectionsAtLeave: Set<String>?
  private var loggedServers = Set<String>()
  private var evidencePolls = 0
  private var lastEvidenceAt: TimeInterval?
  private var matchStartedAt: TimeInterval?
  private var unreadablePolls = 0

  public init() {}

  /// Log lines in the order they were read. Lines older than the newest one already applied (the same event read
  /// again from the other log, or one flushed late) don't change the phase.
  ///
  /// `historical`: lines that were already in the file when reading began (the app or the button started, or a
  /// log started over). They set the phase and the game's mode, but a leave among them happened at an unknown
  /// time, so it doesn't mark the connections open now as the old match's: Hearthstone may have started a match it
  /// didn't log since then, and that match must still count.
  public mutating func ingest(_ lines: [MatchLogLine], now: TimeInterval, historical: Bool = false) {
    for line in lines { ingest(line, now: now, historical: historical) }
  }

  /// The app asked for a reconnect: the game connection is about to close and reopen.
  public mutating func noteReconnect(at now: TimeInterval) { startReconnectHold(at: now) }

  /// One poll. `openConnections`: Hearthstone's open TCP connections as "host:port", nil when they can't be read.
  @discardableResult
  public mutating func evaluate(openConnections: [String]?, now: TimeInterval) -> MatchPresence {
    guard let openConnections else {
      unreadablePolls += 1
      if unreadablePolls >= Self.unreadablePollsBeforeUnknown {
        presence = .unknown
        hasVerdict = true
      }
      return presence
    }
    unreadablePolls = 0
    hasVerdict = true

    var ports: Set<UInt16> = [Self.gamePort]
    for server in loggedServers { if let port = Self.port(of: server) { ports.insert(port) } }
    let onPort = Set(openConnections.filter { connection in
      guard let port = Self.port(of: connection), ports.contains(port) else { return false }
      return Self.isPublicIPv4(Self.host(of: connection))
    })

    if leaveSnapshotPending {
      connectionsAtLeave = onPort
      leaveSnapshotPending = false
    } else if let atLeave = connectionsAtLeave {
      // A connection that closed and opens again later is a new one.
      connectionsAtLeave = atLeave.intersection(onPort)
    }
    let stale = phase == .left && connectionsAtLeave.map { onPort.isSubset(of: $0) } == true
    let loggedServerOpen = !onPort.isDisjoint(with: loggedServers)
    let evidence = !stale && (loggedServerOpen || onPort.count >= 2)
    lastGamePortConnections = onPort.count
    lastSawLoggedGameServer = loggedServerOpen

    if let since = reconnectSince {
      // The connection is back after the reconnect closed it, or stayed open long enough that it never closed.
      if !evidence { reconnectGapSeen = true }
      else if reconnectGapSeen || now - since >= Self.reconnectSettle { reconnectSince = nil }
    }
    if evidence {
      evidencePolls += 1
      lastEvidenceAt = now
      if !isConnected && (loggedServerOpen || evidencePolls >= Self.confirmPolls) {
        isConnected = true
        matchStartedAt = now
      }
    } else {
      evidencePolls = 0
      if isConnected && shouldEnd(now: now) { endMatch() }
    }
    let effectiveKind = kind == .unknown ? menuKind : kind
    presence = isConnected && effectiveKind != .other ? .inMatch : .notInMatch
    return presence
  }

  /// The button's view of this core: connecting before the first verdict, unavailable while `unknown`.
  public var detectorState: MatchDetectorState {
    guard hasVerdict else { return .connecting }
    return presence == .unknown ? .unavailable : .attached
  }

  private func shouldEnd(now: TimeInterval) -> Bool {
    let startedAt = matchStartedAt ?? now
    if phase == .left, let observed = leaveObservedAt, observed >= startedAt { return true }
    let reconnecting = reconnectSince.map { now - $0 <= Self.reconnectHold } == true
    let hold = reconnecting ? Self.reconnectHold : Self.leaveGrace
    return now - (lastEvidenceAt ?? startedAt) >= hold
  }

  private mutating func endMatch() {
    isConnected = false
    matchStartedAt = nil
    kind = .unknown
    reconnectSince = nil
  }

  private mutating func startReconnectHold(at now: TimeInterval) {
    reconnectSince = now
    reconnectGapSeen = false
  }

  private mutating func ingest(_ line: MatchLogLine, now: TimeInterval, historical: Bool) {
    // Quiet for hours: the old time stamps can't be ordered against new ones any more.
    if let observed = phaseObservedAt, now - observed >= Self.logOrderingWindow {
      phaseTime = nil
      leaveTime = nil
      phaseObservedAt = nil
    }
    let category: LogPhase
    switch line.event {
    case .joined(let address, let fromMode):
      if let address { loggedServers.insert(address) }
      if let fromMode, leaveTime.map({ !Self.isEarlier(line.time, than: $0) }) ?? true {
        kind = Self.kind(enteredFrom: fromMode, current: kind)
      }
      category = .joined
    case .dropped: category = .dropped
    case .left: category = .left
    }
    if let previous = phaseTime {
      if Self.isEarlier(line.time, than: previous) { return }
      if line.time == previous && category == phaseCategory { return }
    }
    phaseTime = line.time
    phaseObservedAt = now
    phaseCategory = category
    phase = category
    switch line.event {
    case .left(let menu):
      leaveTime = line.time
      leaveObservedAt = historical ? nil : now
      leaveSnapshotPending = !historical
      if historical { connectionsAtLeave = nil }
      kind = .unknown
      if let menu { menuKind = Self.kind(ofMenu: menu) }
    case .dropped:
      startReconnectHold(at: now)
      connectionsAtLeave = nil
      leaveSnapshotPending = false
    case .joined:
      connectionsAtLeave = nil
      leaveSnapshotPending = false
    }
  }

  /// What the next game will be, from the menu it is started from; unknown for menus that start no game.
  static func kind(ofMenu menu: String) -> MatchKind {
    if menu.hasPrefix("BACON") { return .battlegrounds }
    if otherGameMenus.contains(menu) || menu.hasPrefix("LETTUCE") { return .other }
    return .unknown
  }

  /// A reload (`GAMEPLAY`) or a game resumed at launch (`LOGIN`, `STARTUP`) keeps what the match was.
  static func kind(enteredFrom mode: String, current: MatchKind) -> MatchKind {
    switch mode {
    case "GAMEPLAY", "LOGIN", "STARTUP": current
    case _ where mode.hasPrefix("BACON"): .battlegrounds
    default: .other
    }
  }

  /// Time-of-day comparison that survives midnight: anything up to 12 h behind is earlier.
  static func isEarlier(_ time: TimeInterval, than other: TimeInterval) -> Bool {
    var difference = time - other
    if difference > 43_200 { difference -= 86_400 }
    if difference < -43_200 { difference += 86_400 }
    return difference < 0
  }

  static func host(of connection: String) -> String {
    connection.split(separator: ":", maxSplits: 1).first.map(String.init) ?? connection
  }

  static func port(of connection: String) -> UInt16? {
    guard let colon = connection.lastIndex(of: ":") else { return nil }
    return UInt16(connection[connection.index(after: colon)...])
  }

  static func isPublicIPv4(_ host: String) -> Bool {
    let octets = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    switch (octets[0], octets[1]) {
    case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
    case (172, 16...31): return false
    case (224..., _): return false
    default: return true
    }
  }
}

extension ReconnectButtonVisibilityPolicy {
  /// The button's match signal. The log-and-connection monitor decides; the lobby reader (memory helper), only while
  /// attached, can add a match the monitor hasn't confirmed yet, but never hide or delay one.
  public static func matchSignal(monitor: MatchDetectorState, monitorInMatch: Bool,
                                 reader: MatchDetectorState, readerInMatch: Bool)
    -> (detector: MatchDetectorState, inMatch: Bool) {
    if reader == .attached && readerInMatch { return (.attached, true) }
    return (monitor, monitor == .attached && monitorInMatch)
  }
}
