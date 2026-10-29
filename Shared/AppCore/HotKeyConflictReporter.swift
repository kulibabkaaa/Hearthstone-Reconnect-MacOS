import Foundation

/// Decides when a shortcut that couldn't be registered is worth telling the user about. The layout shortcut
/// is re-registered automatically every time Hearthstone launches or quits; those re-registrations report a
/// conflict only once per shortcut, and again only after it registered fine. Registrations the user caused
/// (launch, a settings change, finishing a recording) always report, since the message line is often
/// overwritten soon after.
public struct HotKeyConflictReporter: Equatable, Sendable {
  private var reportedKeyCode: UInt32?
  private var reportedModifiers: UInt32?
  /// The wanted shortcut failed to register and is still unregistered. The app shows the conflict again
  /// when the window opens.
  public private(set) var isConflicting = false

  public init() {}

  /// Records one registration attempt. Returns true when its failure should be shown.
  public mutating func shouldReport(
    keyCode: UInt32, modifiers: UInt32, registered: Bool, userInitiated: Bool = true
  ) -> Bool {
    isConflicting = !registered
    guard !registered else {
      reportedKeyCode = nil
      reportedModifiers = nil
      return false
    }
    let alreadyReported = reportedKeyCode == keyCode && reportedModifiers == modifiers
    reportedKeyCode = keyCode
    reportedModifiers = modifiers
    return userInitiated || !alreadyReported
  }

  /// The shortcut was unregistered on purpose (no overlay needs it right now). The last report is kept, so
  /// the next automatic re-registration with the same conflict stays quiet.
  public mutating func unregistered() {
    isConflicting = false
  }
}
