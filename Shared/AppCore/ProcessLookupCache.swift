import Foundation

/// When to look up a running app again instead of reusing the one found last time.
///
/// Finding Hearthstone among the running apps asks Launch Services about every app's bundle identifier, a
/// round trip per app. Done four times a second it was most of HS Reconnect's idle CPU. Once found, the process
/// can't change identity until it quits, so it is reused while it runs. It is looked up again only when:
/// - nothing was looked up yet, or an app launched or quit since (`invalidate()` on Workspace notifications);
/// - the process found last time has exited (a restart of the game);
/// - nothing was found and `missingRefreshInterval` has passed: a safety net should a launch notification be missed.
public struct ProcessLookupCache: Equatable, Sendable {
  public static let missingRefreshInterval: TimeInterval = 5

  private var lookedUpAt: TimeInterval?
  private var found = false
  private var invalidated = true

  public init() {}

  /// An app launched or quit: the next request looks up again.
  public mutating func invalidate() { invalidated = true }

  /// `cachedIsRunning`: the process found last time still runs (false when none was found).
  public func needsLookup(now: TimeInterval, cachedIsRunning: Bool) -> Bool {
    guard !invalidated, let lookedUpAt else { return true }
    if found { return !cachedIsRunning }
    return now - lookedUpAt >= Self.missingRefreshInterval || now < lookedUpAt
  }

  public mutating func didLookUp(now: TimeInterval, found: Bool) {
    lookedUpAt = now
    self.found = found
    invalidated = false
  }
}
