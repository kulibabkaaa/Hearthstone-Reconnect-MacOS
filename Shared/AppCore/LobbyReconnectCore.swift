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

public enum LobbyAttachRetryPolicy {
  public static let retryDelay: TimeInterval = 5 * 60

  public static func canAttempt(failedPID: Int32?, retryAfter: Date?,
                                currentPID: Int32, now: Date) -> Bool {
    guard failedPID == currentPID, let retryAfter else { return true }
    return retryAfter <= now
  }
}
