import Testing
@testable import AppCore

@Suite("Hotkey conflict reporter")
struct HotKeyConflictReporterTests {
  /// `#expect` can't call a mutating method directly.
  func report(_ reporter: inout HotKeyConflictReporter, keyCode: UInt32, modifiers: UInt32, registered: Bool) -> Bool {
    reporter.shouldReport(keyCode: keyCode, modifiers: modifiers, registered: registered)
  }

  @Test("the same conflict is reported once, however often it is re-registered")
  func reportsOnce() {
    var reporter = HotKeyConflictReporter()
    #expect(report(&reporter, keyCode: 37, modifiers: 768, registered: false))
    #expect(!report(&reporter, keyCode: 37, modifiers: 768, registered: false))
    #expect(!report(&reporter, keyCode: 37, modifiers: 768, registered: false))
  }

  @Test("successful registrations are never reported")
  func successIsSilent() {
    var reporter = HotKeyConflictReporter()
    #expect(!report(&reporter, keyCode: 37, modifiers: 768, registered: true))
    #expect(!report(&reporter, keyCode: 37, modifiers: 768, registered: true))
  }

  @Test("a conflict that clears and comes back is reported again")
  func reportsAgainAfterSuccess() {
    var reporter = HotKeyConflictReporter()
    #expect(report(&reporter, keyCode: 37, modifiers: 768, registered: false))
    #expect(!report(&reporter, keyCode: 37, modifiers: 768, registered: true))
    #expect(report(&reporter, keyCode: 37, modifiers: 768, registered: false))
  }

  @Test("a different shortcut that fails is reported")
  func differentShortcut() {
    var reporter = HotKeyConflictReporter()
    #expect(report(&reporter, keyCode: 37, modifiers: 768, registered: false))
    #expect(report(&reporter, keyCode: 38, modifiers: 768, registered: false))
    #expect(report(&reporter, keyCode: 38, modifiers: 256, registered: false))
    #expect(!report(&reporter, keyCode: 38, modifiers: 256, registered: false))
  }
}
