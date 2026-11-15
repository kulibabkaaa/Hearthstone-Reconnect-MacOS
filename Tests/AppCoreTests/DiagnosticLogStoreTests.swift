import Foundation
import Testing
@testable import AppCore

/// A clock the tests can move forward.
private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  init(_ start: Date) { current = start }
  var now: Date { lock.withLock { current } }
  func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

struct DiagnosticLogStoreTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("hsr-diagnostic-log-\(UUID().uuidString)", isDirectory: true)
    return url
  }

  @Test func writesRedactedLinesThatSurviveANewStore() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock(start)

    let first = DiagnosticLogStore(directory: directory, now: { clock.now })
    first.append(.reconnectTarget, .notice, "choice=loggedAndOpen logged=1 open=1")
    first.append(.loginItem, .error, "Couldn't register: /Users/somebody/Library\nfor Name#1234")
    _ = first.entries()

    // A later run (the app restarted) still sees both lines.
    clock.advance(60)
    let second = DiagnosticLogStore(directory: directory, now: { clock.now })
    let entries = second.entries()

    #expect(entries.count == 2)
    #expect(entries[0].category == "ReconnectTarget")
    #expect(entries[0].message == "choice=loggedAndOpen logged=1 open=1")
    #expect(entries[1].level == "error")
    #expect(entries[1].message == "Couldn't register: /Users/~/Library for <battletag>")
    let raw = try String(contentsOf: directory.appendingPathComponent(DiagnosticLogStore.currentFileName), encoding: .utf8)
    #expect(!raw.contains("somebody"))
    #expect(!raw.contains("Name#1234"))
  }

  @Test func dropsLinesOlderThanThreeDays() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock(start)

    let first = DiagnosticLogStore(directory: directory, now: { clock.now })
    first.append(.trackerRecovery, .notice, "old")
    clock.advance(2 * 24 * 60 * 60)
    first.append(.trackerRecovery, .notice, "recent")
    _ = first.entries()

    clock.advance(2 * 24 * 60 * 60)
    let later = DiagnosticLogStore(directory: directory, now: { clock.now })
    #expect(later.entries().map(\.message) == ["recent"])
    let raw = try String(contentsOf: directory.appendingPathComponent(DiagnosticLogStore.currentFileName), encoding: .utf8)
    #expect(!raw.contains("old"))
  }

  @Test func rotatesAndStaysWithinTwoFiles() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock(start)
    let store = DiagnosticLogStore(directory: directory, now: { clock.now })
    let message = String(repeating: "x", count: 250)

    for index in 0 ..< 3_000 {
      store.append(.analytics, .notice, "\(index) \(message)")
    }
    let entries = store.entries()

    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(files == [DiagnosticLogStore.previousFileName, DiagnosticLogStore.currentFileName].sorted())
    for name in files {
      let size = try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent(name).path
      )[.size] as? Int ?? .max
      #expect(size <= DiagnosticLogStore.maximumFileBytes)
    }
    #expect(entries.last?.message.hasPrefix("2999 ") == true)
    #expect(entries.count < 3_000)
  }

  @Test func skipsALineCutShortByACrash() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let good = DiagnosticLogFormat.line(date: start, category: .loginItem, level: .notice, message: "fine")
    let cutInMessage = DiagnosticLogFormat.line(
      date: start, category: .loginItem, level: .notice, message: "Couldn't register the helper again"
    ).dropLast(12)
    try Data((good + cutInMessage).utf8)
      .write(to: directory.appendingPathComponent(DiagnosticLogStore.currentFileName))
    let clock = TestClock(start.addingTimeInterval(10))

    let store = DiagnosticLogStore(directory: directory, now: { clock.now })
    store.append(.loginItem, .notice, "after restart")

    #expect(store.entries().map(\.message) == ["fine", "after restart"])
  }

  @Test func aDamagedByteDoesNotCostTheWholeFile() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var data = Data(DiagnosticLogFormat.line(date: start, category: .loginItem, level: .notice, message: "keep me").utf8)
    data.append(Data([0xFF, 0x0A]))
    try data.write(to: directory.appendingPathComponent(DiagnosticLogStore.currentFileName))
    let clock = TestClock(start.addingTimeInterval(10))

    let store = DiagnosticLogStore(directory: directory, now: { clock.now })

    #expect(store.entries().map(\.message) == ["keep me"])
  }

  @Test func appendsAfterAnotherWriterInsteadOfOverwriting() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock(start)
    let first = DiagnosticLogStore(directory: directory, now: { clock.now })
    let second = DiagnosticLogStore(directory: directory, now: { clock.now })
    _ = first.entries()
    _ = second.entries()

    first.append(.loginItem, .notice, "from first")
    _ = first.entries()
    second.append(.loginItem, .notice, "from second")

    #expect(second.entries().map(\.message) == ["from first", "from second"])
  }

  @Test func formatRoundTripsAndRejectsUnknownCategories() {
    let line = DiagnosticLogFormat.line(date: start, category: .trackerRecovery, level: .error, message: "a\tb")
    let parsed = DiagnosticLogFormat.parse(line + "2026-11-15T17:00:00.000Z\tLobbyCapture\tnotice\tsecret\n")

    #expect(parsed.count == 1)
    #expect(parsed[0].date == start)
    #expect(parsed[0].message == "a b")
  }

  @Test func mergesFileAndCurrentRunWithoutCopies() {
    let file = [
      BugReportAppLogEntry(date: start, category: "TrackerRecovery", level: "notice", message: "earlier run"),
      BugReportAppLogEntry(date: start.addingTimeInterval(100), category: "LoginItem", level: "notice", message: "both"),
    ]
    let currentRun = [
      BugReportAppLogEntry(
        date: start.addingTimeInterval(100.4), category: "LoginItem", level: "notice", message: "both"),
      BugReportAppLogEntry(
        date: start.addingTimeInterval(200), category: "ReconnectTarget", level: "notice",
        message: "choice=loggedAndOpen logged=1 open=1"),
      BugReportAppLogEntry(
        date: start.addingTimeInterval(300), category: "LoginItem", level: "notice", message: "both"),
    ]
    let merged = BugReportDiagnostics.mergedAppLogEntries(file: file, currentRun: currentRun)

    #expect(merged.map(\.message) == ["earlier run", "both", "choice=loggedAndOpen logged=1 open=1", "both"])
  }
}
