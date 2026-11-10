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

public enum LobbyReconnectPolicy {
  public static let startupGrace: TimeInterval = 30

  public static func sessionLogSaysReconnect(_ text: String) -> Bool {
    guard let marker = text.range(of: "reconnecting=", options: .backwards) else { return false }
    return text[marker.upperBound...].hasPrefix("True")
  }

  public static func phase(gameUUIDPresent: Bool, gameType: Int, mode: String,
                           sessionLogSaysReconnect: Bool,
                           secondsSinceAttachment: TimeInterval) -> LobbyReconnectPhase {
    if mode == "duos" || (37...40).contains(gameType) { return .idle }
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

/// HearthMirror lists the game's classes once, when a reader is made, and never again. A reader made
/// while Hearthstone is still starting attaches fine (the log folder is known within seconds) but cannot
/// find classes loaded later, so it never sees a lobby and reports nothing wrong. That is what left
/// both overlays off on 10 Nov 2026 until the helper was restarted. HSTracker guards the same way: it
/// accepts a reader only once the BattleTag is readable.
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
