import Foundation

/// What the app does after a failed system extension state check.
public enum SystemExtensionStateCheckFailureResponse: Equatable, Sendable {
  /// A short stall: keep the last known state and leave reconnect as it was.
  case keepLastKnownState
  /// Checks keep failing: turn reconnect off. `isNewStreak` is true once per failure streak.
  case markUnavailable(isNewStreak: Bool)
}

/// macOS answers state checks through sysextd, which can stall for a few seconds under load. One slow
/// answer says nothing about the extension itself, so reconnect is turned off only after several failures
/// in a row.
public struct SystemExtensionStateCheckTracker: Sendable {
  public static let failuresBeforeUnavailable = 3
  /// While the extension is on its state rarely changes, so the background poll asks macOS every few
  /// seconds instead of on every 0.5 s UI tick. During setup the fast interval notices approval quickly.
  /// Keep this at or below `SystemExtensionController.stateCheckTimeout`, so a late answer is picked up
  /// by the next poll within the controller's 2 s hand-off window.
  public static let enabledPollInterval: TimeInterval = 5

  public private(set) var consecutiveFailures = 0

  public init() {}

  /// Whether the background timer should ask macOS again. `pollSlowly` is true while the extension is on
  /// or checks keep failing. Event-driven checks (launch, activation, setup steps) always run.
  public static func isPollDue(
    lastCheckStartedAt: TimeInterval?,
    now: TimeInterval,
    pollSlowly: Bool
  ) -> Bool {
    guard pollSlowly, let lastCheckStartedAt else { return true }
    return now - lastCheckStartedAt >= enabledPollInterval
  }

  /// True once checks have failed often enough to turn reconnect off on their own.
  public var isFailing: Bool {
    consecutiveFailures >= Self.failuresBeforeUnavailable
  }

  /// Normally reconnect needs the last reported extension state to be enabled and the proxy to be
  /// connected. While macOS can't report the state, a connected proxy is proof enough: it can only
  /// connect through a running extension.
  public func allowsReconnect(
    lastKnownState: SystemExtensionRuntimeState?,
    proxyConnected: Bool,
    isUninstalling: Bool
  ) -> Bool {
    if isFailing { return proxyConnected && !isUninstalling }
    return lastKnownState?.allowsReconnect(
      proxyConnected: proxyConnected,
      isUninstalling: isUninstalling
    ) ?? false
  }

  public mutating func recordSuccess() {
    consecutiveFailures = 0
  }

  public mutating func recordFailure() -> SystemExtensionStateCheckFailureResponse {
    consecutiveFailures += 1
    guard consecutiveFailures >= Self.failuresBeforeUnavailable else {
      return .keepLastKnownState
    }
    return .markUnavailable(
      isNewStreak: consecutiveFailures == Self.failuresBeforeUnavailable
    )
  }
}

/// Parameters for `Extension.StateCheckFailed`: the failure kind and, for errors, a coarse error source
/// plus the numeric code from known Apple domains. Nothing identifying.
public enum SystemExtensionStateCheckTelemetry {
  public static let kindParameter = "stateCheck.failure"
  public static let sourceParameter = "stateCheck.errorSource"
  public static let codeParameter = "stateCheck.errorCode"

  static let knownDomains = [
    "OSSystemExtensionErrorDomain": "systemExtension",
    "NSCocoaErrorDomain": "cocoa",
  ]

  public static func failureParameters(
    timedOut: Bool,
    errorDomain: String,
    errorCode: Int
  ) -> [String: String] {
    if timedOut { return [kindParameter: "timeout"] }
    guard let source = knownDomains[errorDomain] else {
      return [kindParameter: "error", sourceParameter: "other"]
    }
    return [
      kindParameter: "error",
      sourceParameter: source,
      codeParameter: String(errorCode),
    ]
  }
}
