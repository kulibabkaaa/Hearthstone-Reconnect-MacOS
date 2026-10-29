import Foundation

/// Decides whether to show the one-time What's New spotlight.
///
/// Each release with a feature worth introducing bumps `currentVersion`. Everyone sees it once: people updating as
/// soon as the main window is open with Reconnect ready, brand-new installs once setup has made Reconnect ready.
public enum WhatsNewPolicy {
  /// 1 = 2.1.0, the floating Reconnect button.
  public static let currentVersion = 1

  /// - Parameters:
  ///   - storedSeenVersion: the raw stored "seen version" setting, whatever type it has.
  ///   - isReconnectReady: whether setup is done, so the spotlight never covers a setup or error prompt.
  public static func shouldShow(
    storedSeenVersion: Any?,
    isReconnectReady: Bool,
    currentVersion: Int = currentVersion
  ) -> Bool {
    isReconnectReady && seenVersion(from: storedSeenVersion) < currentVersion
  }

  /// Reads a stored version leniently: numbers and numeric strings count; anything else counts as never seen.
  public static func seenVersion(from value: Any?) -> Int {
    switch value {
    case let number as Int: return number
    case let number as Double:
      // NaN and infinity count as never seen; NSNumber.intValue on them differs between Intel and Apple Silicon.
      guard number.isFinite else { return 0 }
      // Double(Int.max) rounds up past Int.max, so clamp with a margin before converting.
      if number >= 9.0e18 { return Int.max }
      if number <= -9.0e18 { return Int.min }
      return Int(number)
    case let text as String: return Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    case let number as NSNumber: return number.intValue
    default: return 0
    }
  }
}
