import Testing
@testable import AppCore

@Suite("Hotkey conflict reporter")
struct HotKeyConflictReporterTests {
  /// `#expect` can't call a mutating method directly.
  func report(
    _ reporter: inout HotKeyConflictReporter, keyCode: UInt32 = 37, modifiers: UInt32 = 768,
    registered: Bool, userInitiated: Bool = false
  ) -> Bool {
    reporter.shouldReport(keyCode: keyCode, modifiers: modifiers, registered: registered, userInitiated: userInitiated)
  }

  @Test("Hearthstone launching and quitting reports the same conflict only once")
  func automaticReportsOnce() {
    var reporter = HotKeyConflictReporter()
    #expect(report(&reporter, registered: false))
    reporter.unregistered()                                  // Hearthstone quit
    #expect(!reporter.isConflicting)
    #expect(!report(&reporter, registered: false))           // launched again
    #expect(reporter.isConflicting)
    reporter.unregistered()
    #expect(!report(&reporter, registered: false))
  }

  @Test("a registration the user caused always reports its conflict")
  func userInitiatedAlwaysReports() {
    var reporter = HotKeyConflictReporter()
    #expect(report(&reporter, registered: false))
    #expect(report(&reporter, registered: false, userInitiated: true))
    #expect(report(&reporter, registered: false, userInitiated: true))
    #expect(!report(&reporter, registered: false))           // an automatic one after it stays quiet
  }

  @Test("successful registrations are never reported and clear the conflict")
  func successIsSilent() {
    var reporter = HotKeyConflictReporter()
    #expect(!report(&reporter, registered: true))
    #expect(!report(&reporter, registered: true, userInitiated: true))
    #expect(report(&reporter, registered: false))
    #expect(!report(&reporter, registered: true))
    #expect(!reporter.isConflicting)
  }

  @Test("a conflict that clears and comes back is reported again")
  func reportsAgainAfterSuccess() {
    var reporter = HotKeyConflictReporter()
    #expect(report(&reporter, registered: false))
    #expect(!report(&reporter, registered: true))
    #expect(report(&reporter, registered: false))
  }

  @Test("a different failing shortcut is reported")
  func differentShortcut() {
    var reporter = HotKeyConflictReporter()
    #expect(report(&reporter, keyCode: 37, registered: false))
    #expect(report(&reporter, keyCode: 38, registered: false))
    #expect(report(&reporter, keyCode: 38, modifiers: 256, registered: false))
    #expect(!report(&reporter, keyCode: 38, modifiers: 256, registered: false))
  }
}
