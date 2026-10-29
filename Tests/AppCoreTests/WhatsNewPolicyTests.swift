import Foundation
import Testing

@testable import AppCore

@Suite("What's New policy")
struct WhatsNewPolicyTests {
  @Test("shows once Reconnect is ready and this version wasn't seen")
  func showsWhenReady() {
    #expect(WhatsNewPolicy.shouldShow(storedSeenVersion: nil, isReconnectReady: true))
  }

  @Test("waits while setup isn't done")
  func waitsForSetup() {
    #expect(!WhatsNewPolicy.shouldShow(storedSeenVersion: nil, isReconnectReady: false))
  }

  @Test("never shows again once this version is seen", arguments: [
    WhatsNewPolicy.currentVersion, WhatsNewPolicy.currentVersion + 3,
  ])
  func seenIsFinal(stored: Int) {
    #expect(!WhatsNewPolicy.shouldShow(storedSeenVersion: stored, isReconnectReady: true))
  }

  @Test("a later feature shows to people who only saw an earlier one")
  func laterVersionShowsAgain() {
    #expect(WhatsNewPolicy.shouldShow(storedSeenVersion: 1, isReconnectReady: true, currentVersion: 2))
  }

  @Test("odd stored strings never crash and count as not seen", arguments: [
    "garbage", "", "  ", "1.5", "-4",
  ] as [String])
  func oddStrings(value: String) {
    #expect(WhatsNewPolicy.seenVersion(from: value) <= 0)
    #expect(WhatsNewPolicy.shouldShow(storedSeenVersion: value, isReconnectReady: true))
  }

  @Test("other odd types never crash")
  func oddTypes() {
    let values: [Any?] = [nil, Double.nan, Double.infinity, -Double.infinity, 1e300, -1e300,
      Data([1, 2]), [1], ["version": 1], Date(), true]
    for value in values {
      _ = WhatsNewPolicy.shouldShow(storedSeenVersion: value, isReconnectReady: true)
    }
    #expect(WhatsNewPolicy.seenVersion(from: Double.nan) == 0)
    #expect(WhatsNewPolicy.seenVersion(from: 1e300) == Int.max)
    #expect(WhatsNewPolicy.seenVersion(from: -1e300) == Int.min)
  }

  @Test("reads numbers and numeric strings the way UserDefaults stores them")
  func lenientNumbers() {
    #expect(WhatsNewPolicy.seenVersion(from: 1) == 1)
    #expect(WhatsNewPolicy.seenVersion(from: 1.0) == 1)
    #expect(WhatsNewPolicy.seenVersion(from: NSNumber(value: 2)) == 2)
    #expect(WhatsNewPolicy.seenVersion(from: " 3 ") == 3)
  }
}
