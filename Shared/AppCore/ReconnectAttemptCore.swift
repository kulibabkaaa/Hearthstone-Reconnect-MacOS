import Foundation

/// How one reconnect attempt ended after the app sent `.started`. Every exit of the app's reconnect
/// action after that point is one of these, so `ReconnectButtonModel` always gets exactly one finish event.
public enum ReconnectAttemptOutcome: Equatable, Sendable, CaseIterable {
  /// The extension closed the game flow; the cooldown starts.
  case flowClosed
  /// The request ran but no game flow was open.
  case noFlowClosed
  /// No Battlegrounds game endpoint could be resolved before sending the request.
  case endpointNotFound
  /// The extension reported an error.
  case requestFailed
  /// The reply arrived after the extension or proxy stopped being connected.
  case extensionUnavailable
  /// The reply arrived while the app is uninstalling.
  case uninstalling

  public var buttonEvent: ReconnectButtonEvent {
    switch self {
    case .flowClosed: .succeeded
    case .noFlowClosed, .endpointNotFound: .noGameFound
    case .requestFailed, .extensionUnavailable, .uninstalling: .failed
    }
  }
}

public enum ReconnectCooldownDisplay {
  /// Same cap as `ReconnectButtonModel`: a corrupt stored time (inf, 1e19) must not trap in `Int()`.
  public static let maximumSeconds: TimeInterval = 86_400

  /// Whole seconds to show for a cooldown, rounded up; 0 when no cooldown is left.
  public static func wholeSeconds(remaining: TimeInterval) -> Int {
    guard remaining > 0 else { return 0 }
    return Int(min(remaining, maximumSeconds).rounded(.up))
  }
}
