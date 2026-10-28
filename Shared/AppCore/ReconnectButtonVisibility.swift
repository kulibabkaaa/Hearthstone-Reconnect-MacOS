import Foundation

/// How the lobby reader (the match detector) runs.
public enum LobbyReaderMode: Equatable, Sendable {
  case off
  /// Lobby info is on: rows, ratings, statuses; may ask for lobby access as it always did.
  case lobby
  /// Lobby info is off but the Reconnect button is on: detects matches only. Draws nothing, downloads nothing,
  /// and never asks for lobby access (it attaches only when macOS already allows it without a dialog).
  case matchDetectionOnly
}

/// When the floating Reconnect button is on screen. Outside layout mode it shows only while the player is in a
/// Battlegrounds match (Solo or Duos), as the lobby reader sees it. When the reader can't tell (not attached:
/// access not granted, helper failing, still starting) the button falls back to showing whenever Hearthstone is
/// frontmost, so the switch never looks broken. Layout mode shows it at any time.
public enum ReconnectButtonVisibilityPolicy {
  /// Duos matches count although the lobby overlay is Solo-only.
  public static let countsDuos = true

  public static func readerMode(lobbyEnabled: Bool, buttonEnabled: Bool, hearthstoneRunning: Bool) -> LobbyReaderMode {
    if lobbyEnabled { return .lobby }
    return buttonEnabled && hearthstoneRunning ? .matchDetectionOnly : .off
  }

  /// Whether a live lobby capture that has a game UUID is a match for the button.
  public static func countsAsMatch(_ disposition: LobbyLiveCaptureDisposition,
                                   countsDuos: Bool = countsDuos) -> Bool {
    switch disposition {
    case .publish: true
    case .unsupported: countsDuos
    case .waitForMode: false
    }
  }

  /// Phases that answer a click. While one is on screen the button stays up, so a match signal that drops
  /// during the reconnect it started doesn't cut off its spinner or result.
  public static func isReconnectFeedback(_ phase: ReconnectButtonPhase) -> Bool {
    switch phase {
    case .reconnecting, .succeeded, .noGameFound, .failed: true
    case .ready, .unavailable, .cooldown: false
    }
  }

  /// `detectorAvailable`: the reader is attached to Hearthstone, so `inMatch` can be trusted.
  /// `isShowingFeedback`: the button is on screen now and its phase is `isReconnectFeedback`.
  public static func shouldShow(buttonEnabled: Bool, hasGameWindow: Bool, gameFrontmost: Bool,
                                detectorAvailable: Bool, inMatch: Bool, isEditingLayout: Bool,
                                isShowingFeedback: Bool) -> Bool {
    guard buttonEnabled, hasGameWindow, gameFrontmost else { return false }
    return !detectorAvailable || inMatch || isEditingLayout || isShowingFeedback
  }
}
