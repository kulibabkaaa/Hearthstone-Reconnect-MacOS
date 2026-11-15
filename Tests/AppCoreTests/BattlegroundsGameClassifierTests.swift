import Testing

@testable import AppCore

private func kind(_ evidence: BattlegroundsEvidence) -> BattlegroundsMatchKind { BattlegroundsGameClassifier.kind(evidence) }

@Suite("Battlegrounds game classifier")
struct BattlegroundsGameClassifierTests {
  @Test("known Battlegrounds Solo types are Solo", arguments: [23, 24, 35, 36])
  func knownSolo(gameType: Int) {
    #expect(kind(.init(gameType: gameType, selectedMode: "solo")) == .solo)
    #expect(kind(.init(gameType: gameType)) == .solo)
  }

  @Test("known Duos types are Duos, including Duos vs AI (41)", arguments: [37, 38, 39, 40, 41])
  func knownDuos(gameType: Int) {
    #expect(kind(.init(gameType: gameType, selectedMode: "solo")) == .duos)
  }

  @Test("a nonzero Duos team or a Duos selection makes a Battlegrounds game Duos")
  func duosSignals() {
    #expect(kind(.init(gameType: 23, duoTeamID: 2)) == .duos)
    #expect(kind(.init(gameType: 23, selectedMode: " Duos ")) == .duos)
    #expect(kind(.init(gameType: 23, duoTeamID: 0)) == .solo)
  }

  @Test("Constructed, Arena, Brawl, Mercenaries and Underground Arena never count, whatever else is seen",
        arguments: [1, 2, 4, 5, 6, 7, 8, 14, 15, 16, 20, 28, 29, 30, 31, 32, 33, 34, 42, 43, 44, 45])
  func knownOther(gameType: Int) {
    #expect(kind(.init(gameType: gameType)) == .other)
    #expect(kind(.init(gameType: gameType, selectedMode: "solo", duoTeamID: 1, enteredFromBattlegrounds: true,
                       contestantCount: 8)) == .other)
  }

  @Test("an unknown new type with Battlegrounds evidence counts", arguments: [46, 47, 60, 999])
  func newTypeWithEvidence(gameType: Int) {
    #expect(kind(.init(gameType: gameType, selectedMode: "solo", contestantCount: 8)) == .solo)
    #expect(kind(.init(gameType: gameType, enteredFromBattlegrounds: true)) == .solo)
    #expect(kind(.init(gameType: gameType, duoTeamID: 3)) == .duos)
    #expect(kind(.init(gameType: gameType, selectedMode: "duos", contestantCount: 8)) == .duos)
    #expect(BattlegroundsGameClassifier.countsAsMatch(kind(.init(gameType: gameType, contestantCount: 8))))
  }

  @Test("an unknown new type without Battlegrounds evidence doesn't count", arguments: [46, 47, 60, 999])
  func newTypeWithoutEvidence(gameType: Int) {
    // The menu's Battlegrounds selection stays set in every mode: it isn't evidence.
    #expect(kind(.init(gameType: gameType, selectedMode: "solo")) == .other)
    #expect(kind(.init(gameType: gameType, selectedMode: "duos", contestantCount: 2)) == .other)
    #expect(kind(.init(gameType: gameType)) == .other)
    #expect(!BattlegroundsGameClassifier.countsAsMatch(kind(.init(gameType: gameType, selectedMode: "solo"))))
  }

  @Test("a new type entered from another scene isn't Battlegrounds, even with eight players")
  func newTypeFromOtherScene() {
    #expect(kind(.init(gameType: 46, enteredFromBattlegrounds: false, contestantCount: 8)) == .other)
  }

  @Test("a game already counted keeps counting through a poll that sees fewer players; a known other type doesn't")
  func alreadyCounted() {
    #expect(kind(.init(gameType: 46, contestantCount: 7, alreadyCounted: true)) == .solo)
    #expect(kind(.init(gameType: 46, contestantCount: 7)) == .other)
    #expect(kind(.init(gameType: 7, contestantCount: 2, alreadyCounted: true)) == .other)
  }

  @Test("the helper's evidence: players counted, and 'already counted' only for the same game id")
  func helperEvidence() {
    let fresh = BattlegroundsGameClassifier.helperEvidence(gameType: 46, selectedMode: "solo", contestants: 8,
                                                           gameUUID: "a", confirmedGameUUID: nil)
    #expect(fresh.contestantCount == 8 && !fresh.alreadyCounted)
    #expect(kind(fresh) == .solo)
    let same = BattlegroundsGameClassifier.helperEvidence(gameType: 46, selectedMode: "solo", contestants: 7,
                                                          gameUUID: "a", confirmedGameUUID: "a")
    #expect(same.alreadyCounted && kind(same) == .solo)
    let other = BattlegroundsGameClassifier.helperEvidence(gameType: 46, selectedMode: "solo", contestants: 7,
                                                           gameUUID: "b", confirmedGameUUID: "a")
    #expect(!other.alreadyCounted && kind(other) == .other)
    let none = BattlegroundsGameClassifier.helperEvidence(gameType: 46, selectedMode: "solo", contestants: 7,
                                                          gameUUID: nil, confirmedGameUUID: nil)
    #expect(!none.alreadyCounted)
  }

  @Test("no game type yet: undetermined (counts) unless something says otherwise")
  func noTypeYet() {
    #expect(kind(.init()) == .undetermined)
    #expect(kind(.init(gameType: 0, selectedMode: "solo")) == .undetermined)
    #expect(BattlegroundsGameClassifier.countsAsMatch(.undetermined))
    #expect(kind(.init(gameType: 0, selectedMode: "duos")) == .duos)
    #expect(kind(.init(enteredFromBattlegrounds: true)) == .solo)
    #expect(kind(.init(enteredFromBattlegrounds: false)) == .other)
    #expect(kind(.init(gameType: 0, contestantCount: 8)) == .solo)
  }

  @Test("Solo and Duos count for the button and the helper's rows; other games don't")
  func countsAsMatch() {
    #expect(BattlegroundsGameClassifier.countsAsMatch(.solo))
    #expect(BattlegroundsGameClassifier.countsAsMatch(.duos))
    #expect(!BattlegroundsGameClassifier.countsAsMatch(.other))
  }

  @Test("only a game positively seen as Battlegrounds is latched, never one let through while its type was unknown")
  func confirmedLatch() {
    #expect(BattlegroundsGameClassifier.confirmedGameUUID(kind: .solo, gameUUID: "a", previous: nil) == "a")
    #expect(BattlegroundsGameClassifier.confirmedGameUUID(kind: .duos, gameUUID: "a", previous: nil) == "a")
    #expect(BattlegroundsGameClassifier.confirmedGameUUID(kind: .undetermined, gameUUID: "a", previous: nil) == nil)
    #expect(BattlegroundsGameClassifier.confirmedGameUUID(kind: .undetermined, gameUUID: "a", previous: "a") == "a")
    #expect(BattlegroundsGameClassifier.confirmedGameUUID(kind: .undetermined, gameUUID: "b", previous: "a") == nil)
    #expect(BattlegroundsGameClassifier.confirmedGameUUID(kind: .other, gameUUID: "a", previous: "a") == nil)
    #expect(BattlegroundsGameClassifier.confirmedGameUUID(kind: .solo, gameUUID: nil, previous: "a") == nil)
  }

  /// Runs the helper's two steps (classify, then latch) over a sequence of polls of one game.
  private func polls(_ samples: [(gameType: Int, players: Int)], id: String = "g") -> [BattlegroundsMatchKind] {
    var confirmed: String?
    return samples.map { sample in
      let result = kind(BattlegroundsGameClassifier.helperEvidence(gameType: sample.gameType, selectedMode: "solo",
        contestants: sample.players, gameUUID: id, confirmedGameUUID: confirmed))
      confirmed = BattlegroundsGameClassifier.confirmedGameUUID(kind: result, gameUUID: id, previous: confirmed)
      return result
    }
  }

  @Test("a 2-player game first seen with no type, then an unknown type, is dropped (review finding on PR #61)")
  func provisionalGameIsDropped() {
    #expect(polls([(0, 2), (0, 2), (46, 2), (46, 2)]) == [.undetermined, .undetermined, .other, .other])
  }

  @Test("an eight-player game of a new type stays counted through a poll that misreads a player")
  func confirmedGameStays() {
    #expect(polls([(46, 8), (46, 7), (46, 8)]) == [.solo, .solo, .solo])
    #expect(polls([(0, 8), (46, 7)]) == [.solo, .solo])
  }

  @Test("the known type lists don't overlap")
  func disjoint() {
    let solo = BattlegroundsGameClassifier.soloGameTypes
    let duos = BattlegroundsGameClassifier.duosGameTypes
    let other = BattlegroundsGameClassifier.otherGameTypes
    #expect(solo.isDisjoint(with: duos) && solo.isDisjoint(with: other) && duos.isDisjoint(with: other))
  }
}

@Suite("Lobby reconnect phase uses the classifier")
struct LobbyReconnectPhaseClassifierTests {
  @Test("Duos vs AI (41) is Duos now, like 37–40: the Solo-only overlay stays idle")
  func duosVersusAI() {
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: true, gameType: 41, mode: "solo",
                                       sessionLogSaysReconnect: false, secondsSinceAttachment: 60) == .idle)
  }

  @Test("a Duos selection idles any game, as before")
  func duosSelection() {
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: true, gameType: 7, mode: "duos",
                                       sessionLogSaysReconnect: false, secondsSinceAttachment: 60) == .idle)
  }

  @Test("a Solo game with an id is live, a new Battlegrounds-like type too")
  func soloLive() {
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: true, gameType: 23, mode: "solo",
                                       sessionLogSaysReconnect: false, secondsSinceAttachment: 60) == .live)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: true, gameType: 46, mode: "solo",
                                       sessionLogSaysReconnect: false, secondsSinceAttachment: 60) == .live)
  }
}
