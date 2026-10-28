import Foundation
import CoreGraphics

/// What the reconnect action is doing, as shown by the floating button and the main window.
public enum ReconnectButtonPhase: Equatable, Sendable {
  case ready
  /// The local proxy isn't ready yet.
  case unavailable
  case reconnecting
  /// Transient: a flow was closed.
  case succeeded
  /// Transient: no Battlegrounds game connection was found.
  case noGameFound
  /// Transient: the reconnect request failed.
  case failed
  /// Whole seconds left (always >= 1).
  case cooldown(seconds: Int)
}

public enum ReconnectButtonTone: Equatable, Sendable { case normal, dimmed, success, warning, error }

public struct ReconnectButtonAppearance: Equatable, Sendable {
  public let title: String
  public let tone: ReconnectButtonTone
  public let isClickable: Bool
  public let spinsIcon: Bool
  public init(title: String, tone: ReconnectButtonTone, isClickable: Bool, spinsIcon: Bool) {
    self.title = title; self.tone = tone; self.isClickable = isClickable; self.spinsIcon = spinsIcon
  }
}

public enum ReconnectButtonEvent: Equatable, Sendable {
  case proxyAvailability(ready: Bool)
  case started
  /// A flow was closed; the cooldown starts at `now`.
  case succeeded
  case noGameFound
  case failed
  /// A flow was closed by an attempt that already ended (its reply came after the timeout). Starts the
  /// cooldown at `now` without touching the running state or the transient.
  case cooldownStarted
}

/// Pure reconnect state. The app feeds it events and renders `phase(now:)`; time is always passed in.
public struct ReconnectButtonModel: Equatable, Sendable {
  public static let transientDuration: TimeInterval = 2

  public private(set) var proxyReady: Bool
  public private(set) var isRunning = false
  public private(set) var lastReconnectAt: TimeInterval
  public let cooldownSeconds: TimeInterval
  private var transient: (phase: ReconnectButtonPhase, until: TimeInterval)?

  public init(proxyReady: Bool, lastReconnectAt: TimeInterval, cooldownSeconds: TimeInterval) {
    self.proxyReady = proxyReady
    self.lastReconnectAt = lastReconnectAt
    self.cooldownSeconds = cooldownSeconds
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.proxyReady == rhs.proxyReady && lhs.isRunning == rhs.isRunning
      && lhs.lastReconnectAt == rhs.lastReconnectAt && lhs.cooldownSeconds == rhs.cooldownSeconds
      && lhs.transient?.phase == rhs.transient?.phase && lhs.transient?.until == rhs.transient?.until
  }

  public mutating func apply(_ event: ReconnectButtonEvent, now: TimeInterval) {
    switch event {
    case .proxyAvailability(let ready):
      proxyReady = ready
    case .started:
      isRunning = true
      transient = nil
    case .succeeded:
      isRunning = false
      lastReconnectAt = now
      transient = (.succeeded, now + Self.transientDuration)
    case .noGameFound:
      isRunning = false
      transient = (.noGameFound, now + Self.transientDuration)
    case .failed:
      isRunning = false
      transient = (.failed, now + Self.transientDuration)
    case .cooldownStarted:
      lastReconnectAt = now
    }
  }

  /// Priority: reconnecting > live transient > unavailable > cooldown > ready. A clickable transient
  /// ("No game found", "Try again") shows only while a click would start a reconnect; otherwise the
  /// unavailable or cooldown state shows instead, so a click never silently does nothing.
  public func phase(now: TimeInterval) -> ReconnectButtonPhase {
    if isRunning { return .reconnecting }
    let remaining = max(0, lastReconnectAt + cooldownSeconds - now)
    if let transient, now < transient.until,
      !Self.appearance(for: transient.phase).isClickable || (proxyReady && remaining <= 0) {
      return transient.phase
    }
    if !proxyReady { return .unavailable }
    // Cap before converting: a corrupt stored time (inf, 1e19) must not trap in Int().
    if remaining > 0 { return .cooldown(seconds: max(1, Int(min(remaining, 86_400).rounded(.up)))) }
    return .ready
  }

  /// The next time the phase can change without a new event, or nil when it is stable.
  public func nextChange(after now: TimeInterval) -> TimeInterval? {
    if isRunning { return nil }
    var candidates: [TimeInterval] = []
    if let transient, now < transient.until { candidates.append(transient.until) }
    let cooldownEnd = lastReconnectAt + cooldownSeconds
    if proxyReady, now < cooldownEnd {
      // Next whole-second boundary of the countdown.
      let remaining = cooldownEnd - now
      let step = remaining - (remaining.rounded(.up) - 1)
      candidates.append(now + (step > 0 ? step : 1))
    }
    return candidates.min()
  }

  public static func appearance(for phase: ReconnectButtonPhase) -> ReconnectButtonAppearance {
    switch phase {
    case .ready: ReconnectButtonAppearance(title: "Reconnect", tone: .normal, isClickable: true, spinsIcon: false)
    case .unavailable: ReconnectButtonAppearance(title: "Not ready", tone: .dimmed, isClickable: false, spinsIcon: false)
    case .reconnecting: ReconnectButtonAppearance(title: "Reconnecting…", tone: .normal, isClickable: false, spinsIcon: true)
    case .succeeded: ReconnectButtonAppearance(title: "Reconnected", tone: .success, isClickable: false, spinsIcon: false)
    case .noGameFound: ReconnectButtonAppearance(title: "No game found", tone: .warning, isClickable: true, spinsIcon: false)
    case .failed: ReconnectButtonAppearance(title: "Try again", tone: .error, isClickable: true, spinsIcon: false)
    case .cooldown(let seconds): ReconnectButtonAppearance(title: "Wait \(seconds)s…", tone: .dimmed, isClickable: false, spinsIcon: false)
    }
  }
}

/// The floating blocks that share one layout mode.
public enum OverlayBlockID: String, CaseIterable, Sendable { case lobby, reconnectButton }

public enum OverlayLayoutPolicy {
  /// Blocks a layout session edits, lobby first. Empty means layout mode should refuse.
  public static func editableBlocks(lobbyEnabled: Bool, reconnectButtonEnabled: Bool) -> [OverlayBlockID] {
    var blocks: [OverlayBlockID] = []
    if lobbyEnabled { blocks.append(.lobby) }
    if reconnectButtonEnabled { blocks.append(.reconnectButton) }
    return blocks
  }
}

/// Size and default spot of the Reconnect button, measured from the issue #44 mockup.
public enum ReconnectButtonLayout {
  /// The mockup's 175×55 px button at a 1584-px-wide game, scaled to a 1440-pt game.
  public static let baseSize = CGSize(width: 160, height: 50)
  /// Left edge, as a fraction of the game width from the game's left edge.
  public static let defaultLeftFraction = 0.735
  /// Top edge, as a fraction of the game height from the game's top edge.
  public static let defaultTopFraction = 0.184

  /// Default origin normalized to the game frame (bottom-left, AppKit), anchored by the top edge.
  public static func defaultNormalizedOrigin(scale: Double, gameFrame: CGRect) -> CGPoint {
    guard gameFrame.height > 0 else { return CGPoint(x: defaultLeftFraction, y: 0) }
    let height = Double(baseSize.height) * LobbyOverlayGeometry.clampScale(scale)
    return CGPoint(x: defaultLeftFraction,
                   y: 1 - defaultTopFraction - height / Double(gameFrame.height))
  }
}
