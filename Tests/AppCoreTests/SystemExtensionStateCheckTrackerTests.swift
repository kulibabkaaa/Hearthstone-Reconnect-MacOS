import Testing

@testable import AppCore

@Suite("System extension state check tracker")
struct SystemExtensionStateCheckTrackerTests {
  @Test("brief failures keep the last known state")
  func briefFailuresAreTolerated() {
    var tracker = SystemExtensionStateCheckTracker()

    for _ in 1..<SystemExtensionStateCheckTracker.failuresBeforeUnavailable {
      #expect(tracker.recordFailure() == .keepLastKnownState)
    }
  }

  @Test("repeated failures mark reconnect unavailable once per streak")
  func repeatedFailuresMarkUnavailable() {
    var tracker = SystemExtensionStateCheckTracker()
    for _ in 1..<SystemExtensionStateCheckTracker.failuresBeforeUnavailable {
      _ = tracker.recordFailure()
    }

    #expect(tracker.recordFailure() == .markUnavailable(isNewStreak: true))
    #expect(tracker.recordFailure() == .markUnavailable(isNewStreak: false))
    #expect(tracker.recordFailure() == .markUnavailable(isNewStreak: false))
  }

  @Test("a successful check starts a new streak")
  func successResetsStreak() {
    var tracker = SystemExtensionStateCheckTracker()
    for _ in 0..<SystemExtensionStateCheckTracker.failuresBeforeUnavailable {
      _ = tracker.recordFailure()
    }

    tracker.recordSuccess()

    #expect(tracker.consecutiveFailures == 0)
    #expect(tracker.recordFailure() == .keepLastKnownState)
  }

  @Test("a success between failures prevents the error")
  func interleavedSuccessNeverMarksUnavailable() {
    var tracker = SystemExtensionStateCheckTracker()

    for _ in 0..<10 {
      #expect(tracker.recordFailure() == .keepLastKnownState)
      #expect(tracker.recordFailure() == .keepLastKnownState)
      tracker.recordSuccess()
    }
  }

  @Test("background poll slows down only while the extension is on")
  func pollInterval() {
    let interval = SystemExtensionStateCheckTracker.enabledPollInterval
    #expect(
      SystemExtensionStateCheckTracker.isPollDue(
        lastCheckStartedAt: nil, now: 100, extensionEnabled: true
      )
    )
    #expect(
      !SystemExtensionStateCheckTracker.isPollDue(
        lastCheckStartedAt: 100, now: 100 + interval - 0.1, extensionEnabled: true
      )
    )
    #expect(
      SystemExtensionStateCheckTracker.isPollDue(
        lastCheckStartedAt: 100, now: 100 + interval, extensionEnabled: true
      )
    )
    #expect(
      SystemExtensionStateCheckTracker.isPollDue(
        lastCheckStartedAt: 100, now: 100.5, extensionEnabled: false
      )
    )
  }

  @Test("telemetry sends only the failure kind, error source and Apple error code")
  func telemetryParameters() {
    #expect(
      SystemExtensionStateCheckTelemetry.failureParameters(
        timedOut: true, errorDomain: "HSReconnect.SystemExtensionControllerError", errorCode: 0
      ) == ["stateCheck.failure": "timeout"]
    )
    #expect(
      SystemExtensionStateCheckTelemetry.failureParameters(
        timedOut: false, errorDomain: "OSSystemExtensionErrorDomain", errorCode: 4
      ) == [
        "stateCheck.failure": "error",
        "stateCheck.errorSource": "systemExtension",
        "stateCheck.errorCode": "4",
      ]
    )
    #expect(
      SystemExtensionStateCheckTelemetry.failureParameters(
        timedOut: false, errorDomain: "NSCocoaErrorDomain", errorCode: 4097
      ) == [
        "stateCheck.failure": "error",
        "stateCheck.errorSource": "cocoa",
        "stateCheck.errorCode": "4097",
      ]
    )
    #expect(
      SystemExtensionStateCheckTelemetry.failureParameters(
        timedOut: false, errorDomain: "SomeOtherDomain", errorCode: 7
      ) == ["stateCheck.failure": "error", "stateCheck.errorSource": "other"]
    )
  }
}
