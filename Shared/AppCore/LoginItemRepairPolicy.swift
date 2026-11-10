import Foundation

/// What macOS reports for the "Open with Hearthstone" login item.
public enum LoginItemRegistration: Equatable, Sendable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound
}

/// Decides when the "Open with Hearthstone" helper needs to be registered again.
///
/// macOS can report the login item as enabled while launchd is unable to start
/// it: launchd's job stays tied to a background-item record that macOS has
/// since replaced, for example after the app was replaced by a build signed
/// with a different kind of certificate. Registering again ties the job to the
/// current record. The first new registration can still be rejected (the old
/// record is only replaced on launchd's next retry), so one more repair may be
/// needed after a wait.
public struct LoginItemRepairPolicy: Sendable {
  public enum Decision: Equatable, Sendable {
    /// The helper is running. Stop checking.
    case healthy
    /// The login item is off or waits for the user's approval. Stop checking.
    case notApplicable
    /// Register the login item again, then check once more after `recheckDelay`.
    case reregister
    /// The helper still isn't running after every allowed repair. Stop checking.
    case gaveUp
  }

  public static let maximumRepairs = 3
  /// Lets a login item that macOS is still starting (right after login) settle.
  public static let firstCheckDelay: TimeInterval = 10
  /// The gap between switching the login item off and on again.
  public static let reregisterPause: TimeInterval = 1
  /// launchd retries a failed start every 10 seconds, and macOS replaces a
  /// rejected record on that retry. Checking any sooner would reuse it.
  public static let recheckDelay: TimeInterval = 15

  public private(set) var repairsStarted = 0

  public init() {}

  /// A repair switches the login item off for a moment. If the app was killed
  /// in that gap, the next launch has to register it again.
  public static func shouldResumeInterruptedRepair(
    repairWasInProgress: Bool,
    registration: LoginItemRegistration
  ) -> Bool {
    guard repairWasInProgress else {
      return false
    }
    switch registration {
    case .notRegistered, .notFound:
      return true
    case .enabled, .requiresApproval:
      return false
    }
  }

  public mutating func evaluate(
    registration: LoginItemRegistration,
    isHelperRunning: Bool
  ) -> Decision {
    switch registration {
    case .requiresApproval:
      return .notApplicable
    case .notRegistered, .notFound:
      // Before any repair this means the option is off. After one it means
      // our own registration did not go through, so it has to be redone.
      guard repairsStarted > 0 else {
        return .notApplicable
      }
    case .enabled:
      if isHelperRunning {
        return .healthy
      }
    }

    guard repairsStarted < Self.maximumRepairs else {
      return .gaveUp
    }
    repairsStarted += 1
    return .reregister
  }
}
