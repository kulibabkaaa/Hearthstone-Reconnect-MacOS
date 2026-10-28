import Foundation

/// Decides when a shortcut that couldn't be registered is worth telling the user about. The layout shortcut
/// is re-registered often (settings toggles, Hearthstone launching and quitting), so the same conflict is
/// reported once, and again only after that shortcut registered fine or a different shortcut fails.
public struct HotKeyConflictReporter: Equatable, Sendable {
  private var reportedKeyCode: UInt32?
  private var reportedModifiers: UInt32?

  public init() {}

  /// Records one registration attempt. Returns true when its failure should be shown.
  public mutating func shouldReport(keyCode: UInt32, modifiers: UInt32, registered: Bool) -> Bool {
    guard !registered else {
      reportedKeyCode = nil
      reportedModifiers = nil
      return false
    }
    guard reportedKeyCode != keyCode || reportedModifiers != modifiers else { return false }
    reportedKeyCode = keyCode
    reportedModifiers = modifiers
    return true
  }
}
