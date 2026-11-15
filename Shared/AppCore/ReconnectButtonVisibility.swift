import Foundation

/// How the lobby reader (the memory helper) runs. It runs only for lobby info: the Reconnect button has its own
/// match signal from Hearthstone's logs and connections (`MatchPresenceCore`).
public enum LobbyReaderMode: Equatable, Sendable {
  case off
  /// Lobby info is on: rows, ratings, statuses; may ask for lobby access as it always did.
  case lobby
}

/// What a match detector can say about the player being in a match. Used for the Reconnect button's monitor
/// (`MatchPresenceCore.detectorState`) and for the lobby reader (`MatchDetectorTracker`).
public enum MatchDetectorState: Equatable, Sendable {
  /// Not known yet: the monitor hasn't read Hearthstone yet, or the lobby reader is off or starting, Hearthstone
  /// is still opening or logging in, the helper is launching or restarting, or an attach is being retried.
  case connecting
  /// Its match signal can be trusted.
  case attached
  /// It can't tell: Hearthstone's connections can't be read (monitor), or the reader won't attach (access declined,
  /// the attach gave up, the helper is missing or kept failing). With the monitor unavailable, the button falls back
  /// to showing whenever Hearthstone is frontmost, so the switch never looks broken.
  case unavailable
}

/// What the reader reports about attaching, for `MatchDetectorTracker`.
public enum MatchDetectorSignal: Equatable, Sendable {
  /// A fresh helper starts: for a new Hearthstone process or a retry the player asked for.
  case starting
  /// The helper waits for Hearthstone, for it to finish starting and sign in, or for an attach retry.
  case waiting
  case attached
  /// Access isn't granted without a dialog, was declined, the attach gave up, or the helper is missing.
  case gaveUp
  /// The helper exited or couldn't launch; the reader launches it again.
  case helperFailed
  /// No progress for `MatchDetectorTracker.connectingTimeout` while Hearthstone runs: the helper hangs, or a lobby
  /// access dialog is left unanswered.
  case timedOut
}

/// Turns reader signals into a `MatchDetectorState`. Start a new tracker whenever the reader starts or switches
/// mode. A helper that exits now and then reads as connecting; one that fails
/// `helperFailuresBeforeGivingUp` times in a row without attaching, or stays connecting with no new signal for
/// `connectingTimeout` while Hearthstone runs, counts as unavailable.
public struct MatchDetectorTracker: Equatable, Sendable {
  public static let helperFailuresBeforeGivingUp = 3
  /// Well past a normal start (the helper attaches once Hearthstone has signed in, some 10 to 20 s after it
  /// opens). A login screen left open longer counts as unavailable until the helper attaches.
  public static let connectingTimeout: TimeInterval = 60
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
    case .timedOut:
      if state == .connecting { state = .unavailable }
    }
  }
}

/// When the floating Reconnect button is on screen. Outside layout mode it shows only while the player is in a
/// Battlegrounds match (Solo or Duos), as `matchSignal` sees it. Before the monitor's first verdict it stays
/// hidden. Only when the monitor can't read Hearthstone at all does the button fall back to showing whenever
/// Hearthstone is frontmost. Layout mode shows it at any time.
public enum ReconnectButtonVisibilityPolicy {
  /// Duos matches count although the lobby overlay is Solo-only.
  public static let countsDuos = true

  /// The memory helper runs only for lobby info, so with it off nothing asks for Developer Tools access.
  public static func readerMode(lobbyEnabled: Bool) -> LobbyReaderMode {
    lobbyEnabled ? .lobby : .off
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

  /// `detector` and `inMatch` come from `matchSignal`; `inMatch` counts only while `detector` is `.attached`.
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
