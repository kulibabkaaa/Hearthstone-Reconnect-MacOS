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

/// What the match detector (the lobby reader) can say about the player being in a match.
public enum MatchDetectorState: Equatable, Sendable {
  /// Not known yet: the reader is off or starting, Hearthstone is still opening or logging in, the helper is
  /// launching or restarting, or an attach is being retried. The button stays hidden, like the lobby overlay.
  case connecting
  /// Attached to Hearthstone, so its match signal can be trusted.
  case attached
  /// It won't attach: lobby access isn't granted without a dialog (match detection only) or was declined, the
  /// attach gave up for this game, the helper is missing, or it kept failing. The button falls back to showing
  /// whenever Hearthstone is frontmost, so the switch never looks broken.
  case unavailable
}

/// What the reader reports about attaching, for `MatchDetectorTracker`.
public enum MatchDetectorSignal: Equatable, Sendable {
  /// A fresh helper starts: for a new Hearthstone process or a retry the player asked for.
  case starting
  /// The helper waits for Hearthstone, or for its one automatic attach retry.
  case waiting
  case attached
  /// Access isn't granted without a dialog, was declined, the attach gave up, or the helper is missing.
  case gaveUp
  /// The helper exited or couldn't launch; the reader launches it again.
  case helperFailed
}

/// Turns reader signals into a `MatchDetectorState`. Start a new tracker whenever the reader starts or switches
/// mode. A helper that exits now and then reads as connecting; one that fails
/// `helperFailuresBeforeGivingUp` times in a row without attaching counts as unavailable.
public struct MatchDetectorTracker: Equatable, Sendable {
  public static let helperFailuresBeforeGivingUp = 3
  public private(set) var state = MatchDetectorState.connecting
  private var helperFailures = 0

  public init() {}

  public mutating func handle(_ signal: MatchDetectorSignal) {
    switch signal {
    case .starting:
      helperFailures = 0
      state = .connecting
    case .waiting:
      state = helperFailures >= Self.helperFailuresBeforeGivingUp ? .unavailable : .connecting
    case .attached:
      helperFailures = 0
      state = .attached
    case .gaveUp:
      state = .unavailable
    case .helperFailed:
      helperFailures += 1
      state = helperFailures >= Self.helperFailuresBeforeGivingUp ? .unavailable : .connecting
    }
  }
}

/// When the floating Reconnect button is on screen. Outside layout mode it shows only while the player is in a
/// Battlegrounds match (Solo or Duos), as the lobby reader sees it. While the reader is still connecting
/// (launch, login, helper restart) it stays hidden. Only when the reader won't attach at all does the button
/// fall back to showing whenever Hearthstone is frontmost. Layout mode shows it at any time.
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

  /// `inMatch` counts only while `detector` is `.attached`.
  /// `isShowingFeedback`: the button is on screen now and its phase is `isReconnectFeedback`.
  public static func shouldShow(buttonEnabled: Bool, hasGameWindow: Bool, gameFrontmost: Bool,
                                detector: MatchDetectorState, inMatch: Bool, isEditingLayout: Bool,
                                isShowingFeedback: Bool) -> Bool {
    guard buttonEnabled, hasGameWindow, gameFrontmost else { return false }
    if isEditingLayout || isShowingFeedback { return true }
    switch detector {
    case .connecting: return false
    case .attached: return inMatch
    case .unavailable: return true
    }
  }
}
