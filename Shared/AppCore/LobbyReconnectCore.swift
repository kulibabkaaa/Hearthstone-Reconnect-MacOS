import Foundation

public enum LobbyReconnectPhase: Equatable, Sendable {
  case live
  case resuming
  case probing
  case idle
}

public enum LobbyLiveCaptureDisposition: Equatable, Sendable {
  case publish
  case waitForMode
  case unsupported
}

/// What kind of game is on: the Reconnect button counts Solo and Duos, the lobby overlay is Solo-only.
public enum BattlegroundsMatchKind: Equatable, Sendable {
  case solo
  case duos
  /// Not Battlegrounds: Constructed, Arena, Tavern Brawl, Mercenaries, …, or a game type nobody has seen before
  /// with no Battlegrounds evidence.
  case other
  /// Nothing known yet (no game type, nothing else says either way). Counts, as an unknown game always has.
  case undetermined
}

/// Everything that can tell a Battlegrounds game apart. Each part may be unknown (nil).
public struct BattlegroundsEvidence: Equatable, Sendable {
  /// PegasusShared.GameType (`GameMgr.m_gameType`, or `GameType=` in Power.log); 0 = none yet.
  public var gameType: Int?
  /// The mode selected in the Battlegrounds menu ("solo" / "duos"). It stays set after leaving that menu, so it
  /// only tells Solo from Duos; it is never evidence that the game itself is Battlegrounds.
  public var selectedMode: String?
  /// BACON_DUO_TEAM_ID; nonzero only in Battlegrounds Duos.
  public var duoTeamID: Int?
  /// Whether the game was entered from a Battlegrounds scene (BACON…, from the logs); nil when not logged.
  public var enteredFromBattlegrounds: Bool?
  /// Players with an account in the match: 8 in Battlegrounds (Solo and Duos), 2–4 in every other mode.
  public var contestantCount: Int?
  /// This same game (same game id) was already positively seen as Battlegrounds (Solo or Duos, not merely
  /// undetermined), so one poll that sees fewer contestants can't end and restart it.
  public var alreadyCounted: Bool

  public init(gameType: Int? = nil, selectedMode: String? = nil, duoTeamID: Int? = nil,
              enteredFromBattlegrounds: Bool? = nil, contestantCount: Int? = nil, alreadyCounted: Bool = false) {
    self.gameType = gameType
    self.selectedMode = selectedMode
    self.duoTeamID = duoTeamID
    self.enteredFromBattlegrounds = enteredFromBattlegrounds
    self.contestantCount = contestantCount
    self.alreadyCounted = alreadyCounted
  }
}

/// The one place that decides whether a game is Battlegrounds. Known type numbers decide first; a type number
/// Blizzard adds later counts as Battlegrounds only with other evidence (a Battlegrounds scene, a Duos team, eight
/// contestants), so a new Battlegrounds mode still shows the button and the overlay, and a new non-Battlegrounds
/// mode still doesn't.
public enum BattlegroundsGameClassifier {
  /// GT_BATTLEGROUNDS (23), _FRIENDLY (24), _AI_VS_AI (35), _PLAYER_VS_AI (36).
  public static let soloGameTypes: Set<Int> = [23, 24, 35, 36]
  /// GT_BATTLEGROUNDS_DUO (37), _DUO_VS_AI (38), _DUO_FRIENDLY (39), _DUO_AI_VS_AI (40), _DUO_1_PLAYER_VS_AI (41).
  public static let duosGameTypes: Set<Int> = [37, 38, 39, 40, 41]
  /// Every other type Hearthstone 37.0.255790 defines (PegasusShared.GameType in blizzard.bgsclient.dll; Firestone's
  /// copy lacks 14, 15, 43–45): vs AI/friend, tutorial, Arena, test, Ranked, Casual, Hearthstone Duos (14, 15), Tavern
  /// Brawl, Fireside, Duels, Mercenaries, Underground Arena (42), achievement test, Arena and Underground Arena vs AI.
  /// Never Battlegrounds, whatever else is seen.
  public static let otherGameTypes: Set<Int> = [1, 2, 4, 5, 6, 7, 8, 14, 15, 16, 17, 18, 19, 20, 21, 22, 28, 29, 30,
                                                31, 32, 33, 34, 42, 43, 44, 45]
  public static let battlegroundsContestants = 8

  public static func kind(_ evidence: BattlegroundsEvidence) -> BattlegroundsMatchKind {
    let gameType = evidence.gameType ?? 0
    if otherGameTypes.contains(gameType) { return .other }
    let duosSignal = duosGameTypes.contains(gameType) || (evidence.duoTeamID ?? 0) != 0
      || evidence.selectedMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "duos"
    let battlegroundsEvidence = evidence.enteredFromBattlegrounds == true || (evidence.duoTeamID ?? 0) != 0
      || (evidence.contestantCount ?? 0) >= battlegroundsContestants || evidence.alreadyCounted
    let isBattlegrounds: Bool?
    if soloGameTypes.contains(gameType) || duosGameTypes.contains(gameType) {
      isBattlegrounds = true
    } else if evidence.enteredFromBattlegrounds == false {
      isBattlegrounds = false  // entered from Constructed, Arena, … : a new type there isn't Battlegrounds
    } else if battlegroundsEvidence {
      isBattlegrounds = true
    } else {
      // No type yet: unknown (counts, as before). A type nobody knows, with no evidence: not Battlegrounds.
      isBattlegrounds = gameType == 0 ? nil : false
    }
    switch isBattlegrounds {
    case true?: return duosSignal ? .duos : .solo
    case false?: return .other
    case nil: return duosSignal ? .duos : .undetermined
    }
  }

  /// The Reconnect button and the helper's lobby rows: any Battlegrounds game, Solo or Duos, or one not known yet.
  public static func countsAsMatch(_ kind: BattlegroundsMatchKind) -> Bool { kind != .other }

  /// What the lobby helper knows from memory: the game type, the menu's mode, how many players with an account the
  /// match has, and whether this game id is the one it confirmed as Battlegrounds earlier (`confirmedGameUUID`).
  public static func helperEvidence(gameType: Int, selectedMode: String, contestants: Int?, gameUUID: String?,
                                    confirmedGameUUID: String?) -> BattlegroundsEvidence {
    BattlegroundsEvidence(gameType: gameType, selectedMode: selectedMode, contestantCount: contestants,
                          alreadyCounted: gameUUID != nil && gameUUID == confirmedGameUUID)
  }

  /// The game id the helper may pass as `confirmedGameUUID` next poll. Only an id positively seen as Solo or Duos is
  /// latched; one let through while the type was still unknown (`.undetermined`) is not, so a game whose type later
  /// reads as something new and non-Battlegrounds is dropped instead of staying counted.
  public static func confirmedGameUUID(kind: BattlegroundsMatchKind, gameUUID: String?,
                                       previous: String?) -> String? {
    guard let gameUUID else { return nil }
    switch kind {
    case .solo, .duos: return gameUUID
    case .undetermined: return previous == gameUUID ? previous : nil
    case .other: return nil
    }
  }
}

public enum LobbyReconnectPolicy {
  public static let startupGrace: TimeInterval = 30

  public static func sessionLogSaysReconnect(_ text: String) -> Bool {
    guard let marker = text.range(of: "reconnecting=", options: .backwards) else { return false }
    return text[marker.upperBound...].hasPrefix("True")
  }

  /// Whether the newest game-connection line in `GameNetLogger.log` is a clean leave of the game server
  /// (`Network.DisconnectFromGameServer()`, written when the end screen opens or the player leaves). An in-game
  /// reconnect logs `OnGameServerDisconnectEvent` and a new `GotoGameServe()` instead, so it never reads as a leave.
  public static func sessionLogSaysLeftGameServer(_ text: String) -> Bool {
    let join = text.range(of: "Network.GotoGameServe() - address=", options: .backwards)
    guard let leave = text.range(of: "Network.DisconnectFromGameServer()", options: .backwards) else { return false }
    guard let join else { return true }
    return leave.lowerBound > join.lowerBound
  }

  public static func phase(gameUUIDPresent: Bool, gameType: Int, mode: String,
                           sessionLogSaysReconnect: Bool,
                           secondsSinceAttachment: TimeInterval) -> LobbyReconnectPhase {
    // The Solo-only overlay has nothing to resume in Duos. A Duos selection idles any game, as it always has.
    let kind = BattlegroundsGameClassifier.kind(BattlegroundsEvidence(gameType: gameType, selectedMode: mode))
    if kind == .duos || mode == "duos" { return .idle }
    if gameUUIDPresent { return .live }
    if sessionLogSaysReconnect && secondsSinceAttachment <= startupGrace { return .resuming }
    if secondsSinceAttachment < startupGrace { return .probing }
    return .idle
  }

  public static func liveCaptureDisposition(mode: String) -> LobbyLiveCaptureDisposition {
    switch mode {
    case "solo": return .publish
    case "duos": return .unsupported
    default: return .waitForMode
    }
  }
}

public enum LobbyResumeCachePolicy {
  public static let maximumAge: TimeInterval = 3 * 60 * 60

  public static func isUsable(savedAt: Date, now: Date, gameUUID: String?,
                              mode: String, playerCount: Int,
                              namedPlayerCount: Int,
                              distinctAccountCount: Int) -> Bool {
    let age = now.timeIntervalSince(savedAt)
    return age >= -300 && age <= maximumAge
      && gameUUID?.isEmpty == false && mode == "solo"
      && playerCount == 8 && namedPlayerCount == 8 && distinctAccountCount == 8
  }
}

public enum LobbyHelperProcessPolicy {
  public static func shouldRestart(previousPID: Int32?, currentPID: Int32?) -> Bool {
    guard let currentPID else { return false }
    return currentPID != previousPID
  }
}

/// Why an attach attempt didn't end in a usable reader.
public enum LobbyAttachFailureKind: Equatable, Sendable {
  /// A macOS permission dialog was declined.
  case permissionRejected
  /// Access was granted with no dialog when the wait for the game began, and no longer is. Asking again would
  /// put up a dialog nobody asked for, so the helper stops and leaves that to the player's Retry.
  case permissionLapsed
  /// The attempt asked, or would have to ask, for permission with a dialog.
  case mayPrompt
  /// macOS grants access with no dialog, but the game exposes nothing yet: it has only just opened.
  case gameNotReadable
  /// Attached with no dialog, but Hearthstone hasn't signed in yet.
  case notSignedIn

  /// Trying again cannot show a dialog, so it may repeat.
  public var retriesSilently: Bool { self == .gameNotReadable || self == .notSignedIn }
}

public enum LobbyAttachRetryPolicy {
  // A first attach can fail while the two macOS approval dialogs settle. An attempt that may show a
  // dialog gets one automatic recovery attempt, never more: a declined dialog must not come back in a loop.
  public static let automaticRetryDelay: TimeInterval = 8
  // A Hearthstone that is still starting is tried again at this pace, then less often. These attempts
  // run only while macOS grants access with no dialog, so they cannot prompt.
  public static let startupRetryDelay: TimeInterval = 2
  public static let slowStartupRetryDelay: TimeInterval = 10
  public static let startupRetriesBeforeSlowing = 30
  // A game that never becomes readable at all (about 6 minutes) is a broken reader, not a slow start.
  // Waiting for sign-in has no limit: a login screen can stay open for any length of time.
  public static let unreadableRetriesBeforeGivingUp = 60

  /// `failureCount`: failures in a row for this Hearthstone process, this one included.
  /// For `.gameNotReadable` the helper passes only the failures of that kind, so time spent waiting for sign-in
  /// doesn't count toward giving up on an unreadable game.
  public static func retryAfter(now: Date, failureCount: Int, kind: LobbyAttachFailureKind) -> Date {
    switch kind {
    case .permissionRejected, .permissionLapsed:
      return .distantFuture
    case .mayPrompt:
      return failureCount == 1 ? now.addingTimeInterval(automaticRetryDelay) : .distantFuture
    case .gameNotReadable where failureCount > unreadableRetriesBeforeGivingUp:
      return .distantFuture
    case .gameNotReadable, .notSignedIn:
      return now.addingTimeInterval(
        failureCount <= startupRetriesBeforeSlowing ? startupRetryDelay : slowStartupRetryDelay)
    }
  }

  public static func canAttempt(failedPID: Int32?, retryAfter: Date?,
                                currentPID: Int32, now: Date) -> Bool {
    guard failedPID == currentPID, let retryAfter else { return true }
    return retryAfter <= now
  }
}

public enum LobbyMirrorCandidateDisposition: Equatable, Sendable {
  case accept
  /// The game hasn't signed in yet: throw this reader away and make a new one shortly.
  case retryLater
  case failed
}

/// A reader that attaches while Hearthstone is still starting finds Mono fine, but the game hasn't signed in:
/// no BattleTag, no account, and its lobby classes may not be loaded yet. The helper's reader (Shared/MonoReader)
/// re-reads the class list when a lookup misses, but accepting it before sign-in would still report an empty
/// game as if it were ready. So a reader is accepted only once the BattleTag or account id is readable (the same
/// guard HSTracker uses), unless retrying would need a permission dialog: then the early reader is kept.
/// (With HearthMirror, which listed classes once, this left both overlays off on 10 Nov 2026 until the helper
/// was restarted.)
public enum LobbyMirrorReadinessPolicy {
  public static func isSignedIn(battleTag: String?, accountHigh: Int64?, accountLow: Int64?) -> Bool {
    let tag = battleTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !tag.isEmpty && !tag.hasPrefix("#") { return true }
    return (accountHigh ?? 0) != 0 || (accountLow ?? 0) != 0
  }

  /// `canRetryWithoutDialog`: macOS grants lobby access with no dialog, so making another reader is
  /// silent. Without that an early reader is kept, as before this policy existed.
  public static func disposition(hasLogSessionDirectory: Bool, signedIn: Bool,
                                 canRetryWithoutDialog: Bool) -> LobbyMirrorCandidateDisposition {
    guard hasLogSessionDirectory else { return .failed }
    if signedIn || !canRetryWithoutDialog { return .accept }
    return .retryLater
  }
}

/// Signing in comes several seconds before the menus finish loading, so the class list of an accepted
/// reader is read again a few times, with no dialog, while no match is on screen.
public enum LobbyMirrorRefreshPolicy {
  /// Seconds after the previous class list was read. After the last one it is kept.
  public static let refreshDelays: [TimeInterval] = [15, 30, 60]

  public static func isDue(now: Date, snapshotAt: Date, refreshesDone: Int, matchVisible: Bool) -> Bool {
    guard !matchVisible, refreshDelays.indices.contains(refreshesDone) else { return false }
    return now.timeIntervalSince(snapshotAt) >= refreshDelays[refreshesDone]
  }
}

/// Decides when the lobby helper reports a match as started or over. Hearthstone rebuilds its game state for about
/// a second during an in-game reconnect (and once while a match starts): the game id disappears and the same id
/// comes back. Reporting that as an end plus a new start made the overlay close and redraw (final test, 15 Nov
/// 2026). So a game id that vanishes is held for `hold` seconds, and the same id back in time is reported as nothing
/// new. A clean leave of the game server, a different id, or the hold running out still ends the match.
public struct LobbyMatchTracker: Equatable, Sendable {
  public static let hold: TimeInterval = 3

  public enum Report: Equatable, Sendable {
    /// No match to report.
    case noMatch
    case started(String)
    /// The reported match goes on.
    case ongoing(String)
    /// The game id is missing, but only for less than `hold`: report nothing new, keep the match.
    case holding(String)
    case ended(String)
    /// A different game id: the first match ended and a new one started.
    case replaced(ended: String, started: String)
  }

  /// The match the helper currently reports, if any (also during a hold).
  public private(set) var reportedGameUUID: String?
  private var vanishedAt: TimeInterval?
  /// A match that ended while its game state lingers (the end screen): its id must not start it again.
  private var finishedGameUUID: String?

  public init() {}

  /// One poll. `gameUUID`: the Battlegrounds game id read now (nil when there is none). `leftGameServer`: the session
  /// log's newest game-connection line is a clean leave. `now`: seconds on any steady clock.
  public mutating func observe(gameUUID: String?, leftGameServer: Bool, now: TimeInterval) -> Report {
    if gameUUID == nil { finishedGameUUID = nil }
    if let reported = reportedGameUUID {
      if leftGameServer { return finish(reported, lingering: gameUUID) }
      if let gameUUID {
        vanishedAt = nil
        if gameUUID == reported { return .ongoing(gameUUID) }
        reportedGameUUID = gameUUID
        return .replaced(ended: reported, started: gameUUID)
      }
      let since = vanishedAt ?? now
      vanishedAt = since
      if now - since < Self.hold { return .holding(reported) }
      return finish(reported, lingering: nil)
    }
    guard let gameUUID, gameUUID != finishedGameUUID else { return .noMatch }
    if leftGameServer {
      finishedGameUUID = gameUUID
      return .noMatch
    }
    reportedGameUUID = gameUUID
    vanishedAt = nil
    return .started(gameUUID)
  }

  /// Hearthstone quit: the match that was reported (also one on hold), for `match_suspended`. Starts over.
  public mutating func hearthstoneExited() -> String? {
    let reported = reportedGameUUID
    self = LobbyMatchTracker()
    return reported
  }

  private mutating func finish(_ reported: String, lingering: String?) -> Report {
    reportedGameUUID = nil
    vanishedAt = nil
    finishedGameUUID = lingering
    return .ended(reported)
  }
}
