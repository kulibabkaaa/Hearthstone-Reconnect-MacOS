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
  /// No reply arrived within `ReconnectAttemptFlow.timeout`.
  case timedOut

  public var buttonEvent: ReconnectButtonEvent {
    switch self {
    case .flowClosed: .succeeded
    case .noFlowClosed, .endpointNotFound: .noGameFound
    case .requestFailed, .extensionUnavailable, .uninstalling, .timedOut: .failed
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

/// What the main window says about a reconnect request. The texts are the ones the app always used.
public enum ReconnectStatusMessage: Equatable, Sendable {
  case proxyNotReady
  case alreadyRunning
  case cooldown(seconds: Int)
  case reconnecting
  /// The app shows this one for a few seconds, then goes back to "Ready".
  case missingGame
  case checkingExtension
  case failed
  case triggered

  public var text: String {
    switch self {
    case .proxyNotReady: "The local proxy is still getting ready."
    case .alreadyRunning: "Reconnect is already in progress."
    case .cooldown(let seconds): "Please wait \(seconds) seconds and try again."
    case .reconnecting: "Reconnecting…"
    case .missingGame: "Start a Battlegrounds game and try again."
    case .checkingExtension: "Checking the reconnect extension…"
    case .failed: "Reconnect couldn't be completed. Please try again."
    case .triggered: "Reconnect triggered."
    }
  }

  public var isError: Bool {
    switch self {
    case .reconnecting, .checkingExtension, .triggered: false
    case .proxyNotReady, .alreadyRunning, .cooldown, .missingGame, .failed: true
    }
  }
}

/// How the extension's reply to one reconnect request reads, checked in the order the app always used:
/// uninstalling, then a disconnected extension or proxy, then the reply itself.
public enum ReconnectCompletion: Equatable, Sendable {
  case uninstalling
  case extensionUnavailable
  case failed
  case response(didCloseFlow: Bool)

  /// `didCloseFlow` is nil when the request itself failed.
  public init(isUninstalling: Bool, extensionConnected: Bool, didCloseFlow: Bool?) {
    if isUninstalling {
      self = .uninstalling
    } else if !extensionConnected {
      self = .extensionUnavailable
    } else if let didCloseFlow {
      self = .response(didCloseFlow: didCloseFlow)
    } else {
      self = .failed
    }
  }
}

/// What the app does after one step of a reconnect attempt, in this order: record the closed flow, send the
/// button event (or just redraw), set the main-window status, refresh the extension state, update availability.
public struct ReconnectAttemptEffects: Equatable, Sendable {
  /// Stamp `lastReconnectAt` with the current time and send the success analytics signal.
  public var recordsFlowClosed = false
  /// Event for `ReconnectButtonModel`, applied with the same time as the stamp.
  public var buttonEvent: ReconnectButtonEvent?
  /// Redraw the button from its model even without an event.
  public var rendersButton = false
  public var status: ReconnectStatusMessage?
  public var refreshesExtensionState = false
  /// Re-enable or disable the menu item and the main window's button.
  public var updatesAvailability = false

  public init(
    recordsFlowClosed: Bool = false,
    buttonEvent: ReconnectButtonEvent? = nil,
    rendersButton: Bool = false,
    status: ReconnectStatusMessage? = nil,
    refreshesExtensionState: Bool = false,
    updatesAvailability: Bool = false
  ) {
    self.recordsFlowClosed = recordsFlowClosed
    self.buttonEvent = buttonEvent
    self.rendersButton = rendersButton
    self.status = status
    self.refreshesExtensionState = refreshesExtensionState
    self.updatesAvailability = updatesAvailability
  }

  /// Nothing to do: a stale reply or timeout for an attempt that already ended.
  public static let none = ReconnectAttemptEffects()
  public var isNone: Bool { self == .none }
}

/// Identifies one reconnect attempt, so a reply or timeout for an older attempt can't end a newer one.
public struct ReconnectAttemptToken: Hashable, Sendable {
  let value: UInt64
}

/// The decisions behind the app's reconnect action (shortcut, menu, main window, floating button).
/// Every started attempt ends exactly once: by its reply, by "no game endpoint", or by the timeout,
/// whichever comes first. Anything that arrives for an attempt that already ended is ignored for the UI.
public struct ReconnectAttemptFlow: Equatable, Sendable {
  /// How long the app waits for the extension's reply before showing a failure. Longer than the proxy
  /// controller's own 10 s wait for the tunnel to start, so a slow start isn't shown as a failure.
  public static let timeout: TimeInterval = 12

  public private(set) var activeAttempt: ReconnectAttemptToken?
  private var lastIssued: UInt64 = 0
  /// Attempts that timed out and may still get their one late reply.
  private var timedOutAttempts: Set<ReconnectAttemptToken> = []
  public var isRunning: Bool { activeAttempt != nil }

  public init() {}

  public enum Request: Equatable, Sendable {
    case refused(ReconnectAttemptEffects)
    /// Schedule `timeOut(_:isUninstalling:)` for the token after `timeout` seconds, then send the request.
    case started(ReconnectAttemptToken, ReconnectAttemptEffects)
  }

  public mutating func request(proxyReady: Bool, cooldownRemaining: TimeInterval) -> Request {
    // Refusals redraw the button so it never keeps offering a click that does nothing.
    guard proxyReady else { return .refused(.init(rendersButton: true, status: .proxyNotReady)) }
    guard !isRunning else { return .refused(.init(rendersButton: true, status: .alreadyRunning)) }
    guard cooldownRemaining <= 0 else {
      let seconds = ReconnectCooldownDisplay.wholeSeconds(remaining: cooldownRemaining)
      return .refused(.init(rendersButton: true, status: .cooldown(seconds: seconds)))
    }
    lastIssued += 1
    let token = ReconnectAttemptToken(value: lastIssued)
    activeAttempt = token
    return .started(token, .init(buttonEvent: .started, status: .reconnecting, updatesAvailability: true))
  }

  /// No Battlegrounds game endpoint could be resolved, so no request was sent.
  public mutating func endpointNotFound(_ token: ReconnectAttemptToken) -> ReconnectAttemptEffects {
    guard end(token) else { return .none }
    return .init(buttonEvent: ReconnectAttemptOutcome.endpointNotFound.buttonEvent, status: .missingGame,
                 updatesAvailability: true)
  }

  /// The extension replied. The late reply of an attempt that timed out changes nothing the user sees, but a
  /// flow it really closed still counts: the stamp and the cooldown, so no click is offered that the cooldown
  /// would refuse. Any other reply for an attempt that already ended is ignored.
  public mutating func complete(_ token: ReconnectAttemptToken, _ completion: ReconnectCompletion)
    -> ReconnectAttemptEffects
  {
    guard end(token) else {
      guard timedOutAttempts.remove(token) != nil, completion == .response(didCloseFlow: true) else {
        return .none
      }
      return .init(recordsFlowClosed: true, buttonEvent: .cooldownStarted, updatesAvailability: true)
    }
    switch completion {
    case .uninstalling:
      // The uninstall status stays on screen.
      return .init(buttonEvent: ReconnectAttemptOutcome.uninstalling.buttonEvent)
    case .extensionUnavailable:
      return .init(buttonEvent: ReconnectAttemptOutcome.extensionUnavailable.buttonEvent,
                   status: .checkingExtension, refreshesExtensionState: true, updatesAvailability: true)
    case .failed:
      return .init(buttonEvent: ReconnectAttemptOutcome.requestFailed.buttonEvent, status: .failed,
                   updatesAvailability: true)
    case .response(didCloseFlow: true):
      return .init(recordsFlowClosed: true, buttonEvent: ReconnectAttemptOutcome.flowClosed.buttonEvent,
                   status: .triggered, updatesAvailability: true)
    case .response(didCloseFlow: false):
      return .init(buttonEvent: ReconnectAttemptOutcome.noFlowClosed.buttonEvent, status: .missingGame,
                   updatesAvailability: true)
    }
  }

  /// `timeout` seconds passed since the attempt started. Does nothing if it already ended.
  public mutating func timeOut(_ token: ReconnectAttemptToken, isUninstalling: Bool) -> ReconnectAttemptEffects {
    guard end(token) else { return .none }
    timedOutAttempts.insert(token)
    let event = ReconnectAttemptOutcome.timedOut.buttonEvent
    // While uninstalling, the uninstall status stays on screen.
    if isUninstalling { return .init(buttonEvent: event) }
    return .init(buttonEvent: event, status: .failed, updatesAvailability: true)
  }

  /// Ends the attempt if `token` is the running one. False for a stale token.
  private mutating func end(_ token: ReconnectAttemptToken) -> Bool {
    guard activeAttempt == token else { return false }
    activeAttempt = nil
    return true
  }
}
