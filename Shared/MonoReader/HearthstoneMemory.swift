import Foundation

// Hearthstone's own field paths. Everything Hearthstone-specific lives in this file; MonoRuntime knows only Mono.
// Paths follow Firestone's maintained reader (MIT, see NOTICE.md) and were checked against Hearthstone 37.0.

public struct HearthstoneAccountID: Equatable, Sendable {
  public let high: Int64
  public let low: Int64

  public init(high: Int64, low: Int64) {
    self.high = high
    self.low = low
  }
}

public struct BattlegroundsRatings: Equatable, Sendable {
  public let rating: Int
  public let duosRating: Int
}

public struct LobbyPlayer: Equatable, Sendable {
  public let accountHigh: Int64
  public let accountLow: Int64
  public let heroCardID: String
  public let name: String

  public init(accountHigh: Int64, accountLow: Int64, heroCardID: String, name: String) {
    self.accountHigh = accountHigh
    self.accountLow = accountLow
    self.heroCardID = heroCardID
    self.name = name
  }
}

/// The match on screen: its id and the players Hearthstone knows by account.
public struct MatchLobby: Equatable, Sendable {
  public let gameUUID: String?
  public let players: [LobbyPlayer]
}

public enum BattlegroundsMode {
  /// `BaconLobbyMgr.m_selectedBattlegroundsGameMode` holds "solo" or "duos". Anything else (empty, a future
  /// mode) is "unknown", the value the helper has always sent for a mode it doesn't know.
  public static func normalized(_ raw: String?) -> String {
    switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "solo": return "solo"
    case "duos": return "duos"
    default: return "unknown"
    }
  }

  /// The rating the overlay shows for the selected mode.
  public static func ownRating(mode: String, ratings: BattlegroundsRatings?) -> Int? {
    guard let ratings else { return nil }
    return mode == "duos" ? ratings.duosRating : ratings.rating
  }
}

public enum BattlegroundsGameType {
  /// PegasusShared.GameType values of Battlegrounds games: GT_BATTLEGROUNDS (23), _FRIENDLY (24), _AI_VS_AI (35),
  /// _PLAYER_VS_AI (36) and the Duos types 37–41.
  public static let values: Set<Int> = [23, 24, 35, 36, 37, 38, 39, 40, 41]

  /// The lobby overlay is for Battlegrounds only. A game type that isn't known yet (0, or unreadable) doesn't rule a
  /// lobby out: the game can report it late, for example while reconnecting.
  public static func lobbyApplies(gameType: Int?) -> Bool {
    guard let gameType, gameType != 0 else { return true }
    return values.contains(gameType)
  }
}

/// What a failed attach means for the lobby helper.
public enum LobbyReaderFailure: Equatable, Sendable {
  /// The game is starting (or its memory moved mid-read): try again later, silently.
  case gameNotReady
  /// This Hearthstone's Mono isn't one the reader can trust. Stop for this game process and send no lobby data.
  case unsupported(String)
  /// macOS refused access to the game.
  case accessDenied

  public init(_ error: Error) {
    switch error as? MonoReaderError {
    case let .unsupportedLayout(why)?: self = .unsupported(why)
    case .accessDenied?: self = .accessDenied
    default: self = .gameNotReady
    }
  }
}

public enum HearthstoneLogSession {
  /// The folder Hearthstone writes this run's logs to: the newest `<install>/Logs/Hearthstone_*` folder created
  /// at or after the game started (a minute's slack for clock rounding). Nil until the game has made it.
  public static func directory(appBundle: URL, launchDate: Date?, fileManager: FileManager = .default) -> URL? {
    let logs = appBundle.deletingLastPathComponent().appendingPathComponent("Logs", isDirectory: true)
    guard let entries = try? fileManager.contentsOfDirectory(
      at: logs, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
    let candidates: [(URL, Date)] = entries.compactMap { url in
      guard url.lastPathComponent.hasPrefix("Hearthstone_"),
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey]),
            values.isDirectory == true, let created = values.creationDate else { return nil }
      if let launchDate, created < launchDate.addingTimeInterval(-60) { return nil }
      return (url, created)
    }
    return candidates.max { $0.1 < $1.1 }?.0
  }
}

/// Reads what the lobby overlay needs from a running Hearthstone. Read-only. Each getter returns nil when the
/// value isn't there (not signed in, no match) or can't be read consistently right now.
public final class HearthstoneMemory {
  public let runtime: MonoRuntime
  private var services: [String: ManagedRef] = [:]

  public init(runtime: MonoRuntime) { self.runtime = runtime }

#if canImport(Darwin)
  /// Attaches to Hearthstone. Needs the taskport right; see TaskportAuthorization.
  public static func attach(pid: pid_t) throws -> HearthstoneMemory {
    let task = try TaskMemory(pid: pid)
    let runtime = try MonoRuntime.attach(memory: task, allImageInfoAddress: try task.allImageInfoAddress())
    return HearthstoneMemory(runtime: runtime)
  }
#endif

  /// Call once per poll: later reads see current memory.
  public func beginSnapshot() {
    runtime.beginSnapshot()
    services.removeAll(keepingCapacity: true)
  }

  /// Re-reads Assembly-CSharp's class list (classes load as the game opens menus). Never asks for permission.
  public func refreshClasses() throws { try runtime.index(assembly: "Assembly-CSharp", force: true) }

  // MARK: Account

  private func presence() throws -> ManagedRef? { try runtime.staticObject("BnetPresenceMgr", "s_instance") }

  public func accountID() -> HearthstoneAccountID? {
    guard let presence = try? presence(),
          let entity = try? runtime.path(presence, "m_myGameAccountId", "<EntityId>k__BackingField") else { return nil }
    return accountID(entity)
  }

  private func accountID(_ entity: ManagedRef) -> HearthstoneAccountID? {
    guard let high = try? runtime.int64Field(entity, "high_"), let low = try? runtime.int64Field(entity, "low_") else { return nil }
    return HearthstoneAccountID(high: high, low: low)
  }

  /// The local player's "Name#1234".
  public func battleTag() -> String? {
    guard let presence = try? presence(), let player = try? runtime.objectField(presence, "m_myPlayer") else { return nil }
    for account in ["m_hsGameAccount", "m_account"] {
      if let tag = try? runtime.path(player, account, "m_battleTag"), let text = format(battleTag: tag) { return text }
    }
    return nil
  }

  private func format(battleTag tag: ManagedRef) -> String? {
    guard let name = (try? runtime.stringField(tag, "m_name")) ?? nil, !name.isEmpty else { return nil }
    let number: String?
    if let text = try? runtime.stringField(tag, "m_number") {
      number = text
    } else if let value = try? runtime.int32Field(tag, "m_number") {
      number = String(value)  // older clients stored it as an int
    } else {
      number = nil
    }
    guard let number, !number.isEmpty else { return nil }
    return "\(name)#\(number)"
  }

  // MARK: Services

  /// A game manager registered with Hearthstone's service locator
  /// (`HearthstoneJobs.s_dependencyBuilder[0].m_serviceLocator.m_services`).
  func service(_ name: String) -> ManagedRef? {
    if services.isEmpty, let all = try? readServices() { services = all }
    return services[name]
  }

  private func readServices() throws -> [String: ManagedRef] {
    guard let builders = try runtime.staticObject("Hearthstone.HearthstoneJobs", "s_dependencyBuilder"),
          let first = try runtime.listItems(builders).first ?? nil,
          let dictionary = try runtime.path(first, "m_serviceLocator", "m_services") else { return [:] }
    var found: [String: ManagedRef] = [:]
    for entry in try runtime.dictionaryEntries(dictionary) {
      guard let holder = try runtime.objectField(entry, "value"),
            let name = try runtime.stringField(holder, "<ServiceTypeName>k__BackingField"),
            let service = try runtime.objectField(holder, "<Service>k__BackingField") else { continue }
      found[name] = service
    }
    return found
  }

  // MARK: Battlegrounds

  /// "solo", "duos" or "unknown".
  public func selectedBattlegroundsMode() -> String {
    guard let lobby = service("BaconLobbyMgr") else { return "unknown" }
    return BattlegroundsMode.normalized((try? runtime.stringField(lobby, "m_selectedBattlegroundsGameMode")) ?? nil)
  }

  /// NetCache's NetCacheBaconRatingInfo item.
  public func battlegroundsRatings() -> BattlegroundsRatings? {
    guard let netCache = service("NetCache"), let map = try? runtime.objectField(netCache, "m_netCache"),
          let (slots, _, values) = try? runtime.mapSlots(map), let values else { return nil }
    for slot in slots {
      guard let item = try? runtime.element(values, slot),
            (try? runtime.name(item.klass)) == "NetCacheBaconRatingInfo" else { continue }
      guard let rating = try? runtime.int32Field(item, "<Rating>k__BackingField"),
            let duos = try? runtime.int32Field(item, "<DuosRating>k__BackingField") else { return nil }
      return BattlegroundsRatings(rating: Int(rating), duosRating: Int(duos))
    }
    return nil
  }

  /// PegasusShared.GameType of the current or last game (GameMgr.m_gameType); 0 when none.
  public func gameType() -> Int? {
    guard let gameManager = service("GameMgr"), let value = try? runtime.int32Field(gameManager, "m_gameType") else { return nil }
    return Int(value)
  }

  /// The match on screen (any mode): `GameState.s_instance`'s game entity id and its players
  /// (`m_playerInfoMap`, SharedPlayerInfo: account, name, hero). Nil when no game state exists.
  public func matchLobby() -> MatchLobby? {
    guard let state = try? runtime.staticObject("GameState", "s_instance") else { return nil }
    var gameUUID: String?
    if let entity = try? runtime.objectField(state, "m_gameEntity") {
      gameUUID = (try? runtime.stringField(entity, "<Uuid>k__BackingField")) ?? nil
    }
    var players: [(Int32, LobbyPlayer)] = []
    if let map = try? runtime.objectField(state, "m_playerInfoMap"),
       let (slots, keys, values) = try? runtime.mapSlots(map), let keys, let values {
      for slot in slots {
        guard let info = try? runtime.element(values, slot), let playerID = try? runtime.int32Element(keys, slot),
              let entity = try? runtime.path(info, "m_gameAccountId", "<EntityId>k__BackingField"),
              let account = accountID(entity), account.high != 0 || account.low != 0 else { continue }
        let name = ((try? runtime.stringField(info, "m_name")) ?? nil) ?? ""
        var hero = ""
        if let heroEntity = try? runtime.objectField(info, "m_playerHero") {
          hero = ((try? runtime.stringField(heroEntity, "m_cardIdInternal")) ?? nil) ?? ""
        }
        players.append((playerID, LobbyPlayer(accountHigh: account.high, accountLow: account.low, heroCardID: hero, name: name)))
      }
    }
    return MatchLobby(gameUUID: gameUUID, players: players.sorted { $0.0 < $1.0 }.map(\.1))
  }
}
