import Foundation
import Testing

@testable import MonoReader

/// A fake Hearthstone object graph on top of FakeMono, shaped like Hearthstone 37.0's classes.
private final class FakeHearthstone {
  let mono: FakeMono
  private let csharp: UInt64
  private let core: UInt64
  private let corlib: UInt64
  private var classes: [String: UInt64] = [:]
  private var gameStateStorage: UInt64 = 0
  private var serviceEntries: (data: UInt64, count: Int) = (0, 0)
  private var dictionaryObject: UInt64 = 0
  private var entryClass: UInt64 = 0
  private var linkClass: UInt64 = 0

  init(architecture: CPUArchitecture = .arm64) {
    mono = FakeMono(architecture: architecture)
    mono.makeRuntime(assemblies: ["Assembly-CSharp", "Blizzard.T5.Core"])
    csharp = mono.image("Assembly-CSharp")
    core = mono.image("Blizzard.T5.Core")
    corlib = mono.image("mscorlib")
    entryClass = mono.addClass(image: corlib, namespace: "", name: "Entry", valueType: true)
    mono.setFields(entryClass, [
      FieldSpec(name: "hashCode", type: MonoTypeCode.i4, offset: 16), FieldSpec(name: "next", type: MonoTypeCode.i4, offset: 20),
      FieldSpec(name: "key", type: MonoTypeCode.classType, offset: 24), FieldSpec(name: "value", type: MonoTypeCode.classType, offset: 32),
    ])
    linkClass = mono.addClass(image: core, namespace: "", name: "Link", valueType: true)
    mono.setFields(linkClass, [FieldSpec(name: "HashCode", type: MonoTypeCode.i4, offset: 16),
                               FieldSpec(name: "Next", type: MonoTypeCode.i4, offset: 20)])
  }

  private func klass(_ name: String, namespace: String = "", fields: [FieldSpec] = [], parent: UInt64? = nil,
                     nestedIn: UInt64 = 0, image: UInt64? = nil) -> UInt64 {
    if let existing = classes[name] { return existing }
    let made = mono.addClass(image: image ?? csharp, namespace: namespace, name: name, parent: parent ?? mono.objectClass,
                             nestedIn: nestedIn)
    if !fields.isEmpty { mono.setFields(made, fields) }
    classes[name] = made
    return made
  }

  private func object(_ klass: UInt64) -> UInt64 { mono.newObject(klass) }
  private func set(_ object: UInt64, _ offset: UInt64, _ value: UInt64) { mono.pointer(object + offset, value) }

  private func accountObject(high: Int64, low: Int64) -> UInt64 {
    let entityClass = klass("EntityId", fields: [FieldSpec(name: "high_", type: MonoTypeCode.u8, offset: 16),
                                                 FieldSpec(name: "low_", type: MonoTypeCode.u8, offset: 24)])
    let gameAccountClass = klass("BnetGameAccountId", fields: [
      FieldSpec(name: "<EntityId>k__BackingField", type: MonoTypeCode.classType, data: entityClass, offset: 16)])
    let entity = object(entityClass)
    mono.memory.write(entity + 16, high)
    mono.memory.write(entity + 24, low)
    let account = object(gameAccountClass)
    set(account, 16, entity)
    return account
  }

  /// BnetPresenceMgr.s_instance with the local player's account and BattleTag.
  func signIn(name: String?, number: String?, high: Int64 = 0x200_0000_0000_47, low: Int64 = 1_054_431_362) {
    let tagClass = klass("BnetBattleTag", fields: [FieldSpec(name: "m_name", type: MonoTypeCode.string, offset: 16),
                                                   FieldSpec(name: "m_number", type: MonoTypeCode.string, offset: 24)])
    let gameAccountClass = klass("BnetGameAccount", fields: [
      FieldSpec(name: "m_battleTag", type: MonoTypeCode.classType, data: tagClass, offset: 16)])
    let playerClass = klass("BnetPlayer", fields: [
      FieldSpec(name: "m_account", type: MonoTypeCode.classType, offset: 16),
      FieldSpec(name: "m_hsGameAccount", type: MonoTypeCode.classType, data: gameAccountClass, offset: 24)])
    let presenceClass = klass("BnetPresenceMgr", fields: [
      FieldSpec(name: "s_instance", type: MonoTypeCode.classType, isStatic: true, offset: 0),
      FieldSpec(name: "m_myGameAccountId", type: MonoTypeCode.classType, offset: 16),
      FieldSpec(name: "m_myPlayer", type: MonoTypeCode.classType, data: playerClass, offset: 24)])
    let tag = object(tagClass)
    if let name { set(tag, 16, mono.newString(name)) }
    if let number { set(tag, 24, mono.newString(number)) }
    let gameAccount = object(gameAccountClass)
    set(gameAccount, 16, tag)
    let player = object(playerClass)
    set(player, 24, gameAccount)
    let presence = object(presenceClass)
    set(presence, 16, accountObject(high: high, low: low))
    set(presence, 24, player)
    set(mono.staticStorage(for: presenceClass, size: 8), 0, presence)
  }

  /// HearthstoneJobs.s_dependencyBuilder[0].m_serviceLocator.m_services with these services.
  func services(_ services: [(name: String, object: UInt64)], removed: Set<String> = []) {
    let corlibList = mono.genericDefinition(namespace: "System.Collections.Generic", name: "List`1", image: corlib)
    let corlibDictionary = mono.genericDefinition(namespace: "System.Collections.Generic", name: "Dictionary`2", image: corlib)
    let holderClass = klass("Service", fields: [
      FieldSpec(name: "<ServiceTypeName>k__BackingField", type: MonoTypeCode.string, offset: 16),
      FieldSpec(name: "<Service>k__BackingField", type: MonoTypeCode.object, offset: 24)])
    let dictionaryClass = mono.genericInstance(of: corlibDictionary, image: corlib, fields: [
      FieldSpec(name: "_entries", type: MonoTypeCode.szArray, offset: 16), FieldSpec(name: "_count", type: MonoTypeCode.i4, offset: 24)])
    let (entries, data) = mono.newArray(of: entryClass, elementSize: 24, count: services.count + 2)
    for (index, service) in services.enumerated() {
      let holder = object(holderClass)
      set(holder, 16, mono.newString(service.name))
      set(holder, 24, service.object)
      let slot = data + UInt64(index * 24)
      mono.memory.write(slot, Int32(index + 100))
      mono.memory.write(slot + 4, Int32(removed.contains(service.name) ? -3 : -1))
      set(slot, 16, holder)
    }
    let dictionary = object(dictionaryClass)
    set(dictionary, 16, entries)
    mono.memory.write(dictionary + 24, Int32(services.count))
    let locatorClass = klass("ServiceLocator", fields: [
      FieldSpec(name: "m_services", type: MonoTypeCode.genericInstance, data: mono.genericType(corlibDictionary), offset: 16)])
    let locator = object(locatorClass)
    set(locator, 16, dictionary)
    let builderClass = klass("DependencyBuilder", fields: [
      FieldSpec(name: "m_serviceLocator", type: MonoTypeCode.classType, data: locatorClass, offset: 16)])
    let builder = object(builderClass)
    set(builder, 16, locator)
    let listClass = mono.genericInstance(of: corlibList, image: corlib, fields: [
      FieldSpec(name: "_items", type: MonoTypeCode.szArray, offset: 16), FieldSpec(name: "_size", type: MonoTypeCode.i4, offset: 24)])
    let (items, itemData) = mono.newArray(of: builderClass, elementSize: 8, count: 4)
    set(itemData, 0, builder)
    let list = object(listClass)
    set(list, 16, items)
    mono.memory.write(list + 24, Int32(1))
    let jobs = klass("HearthstoneJobs", namespace: "Hearthstone", fields: [
      FieldSpec(name: "s_dependencyBuilder", type: MonoTypeCode.genericInstance, data: mono.genericType(corlibList), isStatic: true, offset: 8)])
    set(mono.staticStorage(for: jobs, size: 16), 8, list)
  }

  func lobbyManager(mode: String?) -> UInt64 {
    let lobbyClass = klass("BaconLobbyMgr", fields: [
      FieldSpec(name: "m_selectedBattlegroundsGameMode", type: MonoTypeCode.string, offset: 16)])
    let lobby = object(lobbyClass)
    if let mode { set(lobby, 16, mono.newString(mode)) }
    return lobby
  }

  func gameManager(gameType: Int32) -> UInt64 {
    let gameTypeEnum = mono.addClass(image: csharp, namespace: "PegasusShared", name: "GameType", parent: mono.objectClass,
                                     valueType: true, isEnum: true)
    mono.setFields(gameTypeEnum, [FieldSpec(name: "value__", type: MonoTypeCode.i4, offset: 16)])
    let managerClass = klass("GameMgr", fields: [
      FieldSpec(name: "m_gameType", type: MonoTypeCode.valueType, data: gameTypeEnum, offset: 104)])
    let manager = mono.newObject(managerClass, size: 0x100)
    mono.memory.write(manager + 104, gameType)
    return manager
  }

  /// A Blizzard.T5.Core.Map. `dead` slot indexes are removed entries (no HASH_FLAG) left in the arrays.
  func map(keys: [Int32], values: [UInt64], dead: Set<Int> = []) -> UInt64 {
    let definition = mono.genericDefinition(namespace: "Blizzard.T5.Core", name: "Map`2", image: core)
    let mapClass = mono.genericInstance(of: definition, image: core, fields: [
      FieldSpec(name: "linkSlots", type: MonoTypeCode.szArray, offset: 24), FieldSpec(name: "keySlots", type: MonoTypeCode.szArray, offset: 32),
      FieldSpec(name: "valueSlots", type: MonoTypeCode.szArray, offset: 40), FieldSpec(name: "touchedSlots", type: MonoTypeCode.i4, offset: 56),
      FieldSpec(name: "count", type: MonoTypeCode.i4, offset: 64)])
    let int32 = mono.addClass(image: corlib, namespace: "System", name: "Int32Copy", valueType: true, cached: false)
    let capacity = values.count + 3
    let (links, linkData) = mono.newArray(of: linkClass, elementSize: 8, count: capacity)
    let (keyArray, keyData) = mono.newArray(of: int32, elementSize: 4, count: capacity)
    let (valueArray, valueData) = mono.newArray(of: mono.objectClass, elementSize: 8, count: capacity)
    for (index, value) in values.enumerated() {
      let hash = dead.contains(index) ? Int32(0x1234) : Int32(bitPattern: 0x8000_0000 | UInt32(index))
      mono.memory.write(linkData + UInt64(index * 8), hash)
      mono.memory.write(keyData + UInt64(index * 4), keys[index])
      set(valueData, UInt64(index * 8), value)
    }
    let map = mono.newObject(mapClass)
    set(map, 24, links); set(map, 32, keyArray); set(map, 40, valueArray)
    mono.memory.write(map + 56, Int32(values.count))
    mono.memory.write(map + 64, Int32(values.count - dead.count))
    return map
  }

  func netCache(rating: Int32, duos: Int32) -> UInt64 {
    let definition = mono.genericDefinition(namespace: "Blizzard.T5.Core", name: "Map`2", image: core)
    let netCacheClass = klass("NetCache", fields: [
      FieldSpec(name: "m_netCache", type: MonoTypeCode.genericInstance, data: mono.genericType(definition), offset: 16)])
    let ratingClass = klass("NetCacheBaconRatingInfo", fields: [
      FieldSpec(name: "<Rating>k__BackingField", type: MonoTypeCode.i4, offset: 16),
      FieldSpec(name: "<DuosRating>k__BackingField", type: MonoTypeCode.i4, offset: 20)], nestedIn: netCacheClass)
    let other = object(klass("NetCacheProfileProgress"))
    let info = object(ratingClass)
    mono.memory.write(info + 16, rating)
    mono.memory.write(info + 20, duos)
    let cache = object(netCacheClass)
    set(cache, 16, map(keys: [1, 2], values: [other, info]))
    return cache
  }

  struct Player { var id: Int32; var high: Int64; var low: Int64; var name: String?; var hero: String? }

  func game(uuid: String?, players: [Player], dead: Set<Int> = []) {
    let entityBase = klass("Entity", fields: [FieldSpec(name: "m_cardIdInternal", type: MonoTypeCode.string, offset: 40)])
    let infoClass = klass("SharedPlayerInfo", fields: [
      FieldSpec(name: "m_gameAccountId", type: MonoTypeCode.classType, offset: 280),
      FieldSpec(name: "m_name", type: MonoTypeCode.string, offset: 288),
      FieldSpec(name: "m_playerHero", type: MonoTypeCode.classType, data: entityBase, offset: 296)], parent: entityBase)
    let gameEntityClass = klass("GameEntity", fields: [FieldSpec(name: "<Uuid>k__BackingField", type: MonoTypeCode.string, offset: 16)],
                                parent: entityBase)
    let definition = mono.genericDefinition(namespace: "Blizzard.T5.Core", name: "Map`2", image: core)
    let stateClass = klass("GameState", fields: [
      FieldSpec(name: "s_instance", type: MonoTypeCode.classType, isStatic: true, offset: 0),
      FieldSpec(name: "m_playerInfoMap", type: MonoTypeCode.genericInstance, data: mono.genericType(definition), offset: 56),
      FieldSpec(name: "m_gameEntity", type: MonoTypeCode.classType, data: gameEntityClass, offset: 64)])
    var infos: [UInt64] = []
    for player in players {
      let info = mono.newObject(infoClass, size: 0x140)
      set(info, 280, accountObject(high: player.high, low: player.low))
      if let name = player.name { set(info, 288, mono.newString(name)) }
      if let hero = player.hero {
        let heroEntity = object(entityBase)
        set(heroEntity, 40, mono.newString(hero))
        set(info, 296, heroEntity)
      }
      infos.append(info)
    }
    let state = mono.newObject(stateClass, size: 0x100)
    set(state, 56, map(keys: players.map(\.id), values: infos, dead: dead))
    if let uuid {
      let entity = object(gameEntityClass)
      set(entity, 16, mono.newString(uuid))
      set(state, 64, entity)
    }
    if gameStateStorage == 0 { gameStateStorage = mono.staticStorage(for: stateClass, size: 8) }
    set(gameStateStorage, 0, state)
  }

  func endGame() { set(gameStateStorage, 0, 0) }

  func attach() throws -> HearthstoneMemory {
    mono.finishClassCaches()
    mono.install()
    return HearthstoneMemory(runtime: try mono.attach())
  }
}

private func eightPlayers() -> [FakeHearthstone.Player] {
  (0..<8).map { index in
    FakeHearthstone.Player(id: Int32(12 - index), high: 0x200_0000_0000_47, low: Int64(1000 + index),
                           name: "Player\(index)", hero: "TB_BaconShop_HERO_\(index)")
  }
}

@Suite("Hearthstone memory")
struct HearthstoneMemoryTests {
  @Test("reads the signed-in account and BattleTag", arguments: [CPUArchitecture.arm64, .x86_64])
  func account(architecture: CPUArchitecture) throws {
    let fake = FakeHearthstone(architecture: architecture)
    fake.signIn(name: "kulibabka", number: "2342")
    let memory = try fake.attach()
    #expect(memory.battleTag() == "kulibabka#2342")
    #expect(memory.accountID() == HearthstoneAccountID(high: 0x200_0000_0000_47, low: 1_054_431_362))
  }

  @Test("no BattleTag before sign-in fills it in")
  func notSignedIn() throws {
    let fake = FakeHearthstone()
    fake.signIn(name: nil, number: nil, high: 0, low: 0)
    let memory = try fake.attach()
    #expect(memory.battleTag() == nil)
    #expect(memory.accountID() == HearthstoneAccountID(high: 0, low: 0))
  }

  @Test("nothing to read before the game creates its managers")
  func beforeStartup() throws {
    let memory = try FakeHearthstone().attach()
    #expect(memory.battleTag() == nil)
    #expect(memory.accountID() == nil)
    #expect(memory.selectedBattlegroundsMode() == "unknown")
    #expect(memory.battlegroundsRatings() == nil)
    #expect(memory.gameType() == nil)
    #expect(memory.matchLobby() == nil)
  }

  @Test("services, selected mode, ratings and game type", arguments: ["solo", "duos"])
  func services(mode: String) throws {
    let fake = FakeHearthstone()
    fake.services([("BaconLobbyMgr", fake.lobbyManager(mode: mode)), ("NetCache", fake.netCache(rating: 6305, duos: 5120)),
                   ("GameMgr", fake.gameManager(gameType: 30))])
    let memory = try fake.attach()
    #expect(memory.selectedBattlegroundsMode() == mode)
    #expect(memory.battlegroundsRatings() == BattlegroundsRatings(rating: 6305, duosRating: 5120))
    #expect(memory.gameType() == 30)
  }

  @Test("a removed service-locator entry is ignored")
  func removedService() throws {
    let fake = FakeHearthstone()
    fake.services([("BaconLobbyMgr", fake.lobbyManager(mode: "duos"))], removed: ["BaconLobbyMgr"])
    #expect(try fake.attach().selectedBattlegroundsMode() == "unknown")
  }

  @Test("a full Battlegrounds lobby: eight players in player-id order with names, accounts and heroes")
  func lobby() throws {
    let fake = FakeHearthstone()
    var players = eightPlayers()
    // Bob the innkeeper has no account and must not take a lobby row.
    players.insert(FakeHearthstone.Player(id: 1, high: 0, low: 0, name: "Bob", hero: nil), at: 3)
    fake.game(uuid: "c0ffee00-1234-4abc-9def-001122334455", players: players)
    let lobby = try #require(try fake.attach().matchLobby())
    #expect(lobby.gameUUID == "c0ffee00-1234-4abc-9def-001122334455")
    #expect(lobby.players.count == 8)
    #expect(lobby.players.map(\.name) == (0..<8).reversed().map { "Player\($0)" })
    #expect(lobby.players.first == LobbyPlayer(accountHigh: 0x200_0000_0000_47, accountLow: 1007,
                                                 heroCardID: "TB_BaconShop_HERO_7", name: "Player7"))
  }

  @Test("removed map slots and missing names or heroes don't break the lobby")
  func partialLobby() throws {
    let fake = FakeHearthstone()
    var players = eightPlayers()
    players[2].name = nil
    players[5].hero = nil
    fake.game(uuid: "id", players: players, dead: [7])
    let lobby = try #require(try fake.attach().matchLobby())
    #expect(lobby.players.count == 7)
    #expect(lobby.players.contains { $0.name.isEmpty })
    #expect(lobby.players.contains { $0.heroCardID.isEmpty })
    #expect(!lobby.players.contains { $0.name == "Player7" })
  }

  @Test("a game state without a game entity has no id; ending the match clears the lobby")
  func lobbyLifecycle() throws {
    let fake = FakeHearthstone()
    fake.game(uuid: nil, players: eightPlayers())
    let memory = try fake.attach()
    #expect(memory.matchLobby()?.gameUUID == nil)
    fake.endGame()
    memory.beginSnapshot()
    #expect(memory.matchLobby() == nil)
  }

  @Test("values of the wrong type read as missing, never as garbage")
  func wrongTypes() throws {
    let fake = FakeHearthstone()
    // A mode field holding a number-typed field name collision: the reader must refuse, not reinterpret.
    let lobbyClass = fake.mono.addClass(image: fake.mono.image("Assembly-CSharp"), namespace: "", name: "BaconLobbyMgr")
    fake.mono.setFields(lobbyClass, [FieldSpec(name: "m_selectedBattlegroundsGameMode", type: MonoTypeCode.i4, offset: 16)])
    let lobby = fake.mono.newObject(lobbyClass)
    fake.mono.memory.write(lobby + 16, Int32(2))
    fake.services([("BaconLobbyMgr", lobby)])
    #expect(try fake.attach().selectedBattlegroundsMode() == "unknown")
  }
}

@Suite("Battlegrounds mode")
struct BattlegroundsModeTests {
  @Test("mode strings map to the helper's values", arguments: [
    ("solo", "solo"), ("duos", "duos"), ("SOLO", "solo"), (" Duos ", "duos"), ("", "unknown"), ("trios", "unknown"),
  ])
  func normalized(raw: String, expected: String) {
    #expect(BattlegroundsMode.normalized(raw) == expected)
  }

  @Test("no mode is unknown")
  func missing() { #expect(BattlegroundsMode.normalized(nil) == "unknown") }

  @Test("own rating follows the mode", arguments: [("solo", 6305), ("duos", 5120), ("unknown", 6305)])
  func ownRating(mode: String, expected: Int) {
    #expect(BattlegroundsMode.ownRating(mode: mode, ratings: BattlegroundsRatings(rating: 6305, duosRating: 5120)) == expected)
  }

  @Test("no ratings, no own rating")
  func noRatings() { #expect(BattlegroundsMode.ownRating(mode: "solo", ratings: nil) == nil) }
}

@Suite("Battlegrounds game types")
struct BattlegroundsGameTypeTests {
  @Test("Battlegrounds solo, duos, friendly and AI games have a lobby", arguments: [23, 24, 35, 36, 37, 38, 39, 40, 41])
  func battlegrounds(gameType: Int) { #expect(BattlegroundsGameType.lobbyApplies(gameType: gameType)) }

  @Test("ranked, casual, arena, brawl and Mercenaries games don't", arguments: [1, 2, 5, 7, 8, 16, 30, 31, 42])
  func otherModes(gameType: Int) { #expect(!BattlegroundsGameType.lobbyApplies(gameType: gameType)) }

  @Test("a game type not known yet doesn't hide a lobby")
  func unknown() {
    #expect(BattlegroundsGameType.lobbyApplies(gameType: 0))
    #expect(BattlegroundsGameType.lobbyApplies(gameType: nil))
  }
}

@Suite("Lobby reader failures")
struct LobbyReaderFailureTests {
  @Test("an unsupported layout stops the reader; starting-up states retry")
  func classification() {
    #expect(LobbyReaderFailure(MonoReaderError.unsupportedLayout("x")) == .unsupported("x"))
    #expect(LobbyReaderFailure(MonoReaderError.notReady("x")) == .gameNotReady)
    #expect(LobbyReaderFailure(MonoReaderError.readFailed(address: 1, count: 1)) == .gameNotReady)
    #expect(LobbyReaderFailure(MonoReaderError.accessDenied(5)) == .accessDenied)
  }
}

@Suite("Hearthstone log session folder")
struct HearthstoneLogSessionTests {
  private func install() throws -> (app: URL, logs: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-log-\(UUID().uuidString)")
    let app = root.appendingPathComponent("Hearthstone.app")
    let logs = root.appendingPathComponent("Logs")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    return (app, logs)
  }

  private func folder(_ logs: URL, _ name: String, created: Date) throws {
    let url = logs.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
  }

  @Test("picks the newest session folder made after the game started")
  func newest() throws {
    let (app, logs) = try install()
    let launch = Date(timeIntervalSince1970: 1_800_000_000)
    try folder(logs, "Hearthstone_2026_11_15_17_52_19", created: launch.addingTimeInterval(-3600))
    try folder(logs, "Hearthstone_2026_11_15_18_21_30", created: launch.addingTimeInterval(2))
    try folder(logs, "Other_2026", created: launch.addingTimeInterval(5))
    #expect(HearthstoneLogSession.directory(appBundle: app, launchDate: launch)?.lastPathComponent
              == "Hearthstone_2026_11_15_18_21_30")
  }

  @Test("an older run's folder is not this run's")
  func onlyOlder() throws {
    let (app, logs) = try install()
    let launch = Date(timeIntervalSince1970: 1_800_000_000)
    try folder(logs, "Hearthstone_old", created: launch.addingTimeInterval(-600))
    #expect(HearthstoneLogSession.directory(appBundle: app, launchDate: launch) == nil)
  }

  @Test("without the game's start time no folder is trusted")
  func unknownStart() throws {
    let (app, logs) = try install()
    try folder(logs, "Hearthstone_old", created: Date().addingTimeInterval(-86_400))
    #expect(HearthstoneLogSession.directory(appBundle: app, launchDate: nil) == nil)
  }

  @Test("no Logs folder, no session")
  func noLogs() {
    #expect(HearthstoneLogSession.directory(appBundle: URL(fileURLWithPath: "/nonexistent/Hearthstone.app"),
                                            launchDate: nil) == nil)
  }
}
