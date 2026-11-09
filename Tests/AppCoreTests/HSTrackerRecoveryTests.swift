import Darwin
import Foundation
import Testing

@testable import AppCore

@Suite("HSTracker reconnect recovery")
struct HSTrackerRecoveryTests {
  private let reconnect = """
    D 12:00:00.8370780 LoadingScreen.OnScenePreUnload() - prevMode=GAMEPLAY nextMode=GAMEPLAY m_phase=INVALID
    D 12:00:00.9364530 Gameplay.Start()
    D 12:00:01.2371830 MulliganManager.HandleGameStart() - IsPastBeginPhase()=True
    D 12:00:02.6059910 LoadingScreen.OnSceneLoaded() - prevMode=GAMEPLAY currMode=GAMEPLAY
    """

  @Test("requires a complete reconnect sequence from the current request")
  func reconnectSequence() {
    var observation = HSTrackerRecoveryObservation()
    observation.observe("LoadingScreen.OnSceneLoaded() - prevMode=GAMEPLAY currMode=GAMEPLAY\n")
    #expect(observation.state == .waiting)
    observation.observe(reconnect)
    #expect(observation.state == .ready)
  }

  @Test("ignores stale mulligan signals and cancels a superseding reload")
  func ordersReloadSignals() {
    var observation = HSTrackerRecoveryObservation()
    observation.observe("MulliganManager.HandleGameStart() - IsPastBeginPhase()=True\n")
    observation.observe("Gameplay.Start()\nLoadingScreen.OnSceneLoaded() - prevMode=GAMEPLAY currMode=GAMEPLAY\n")
    #expect(observation.state == .waiting)
    observation.observe("Gameplay.Start()\n")
    #expect(observation.state == .cancelled)
  }

  @Test("does not recover a new match or a match the player has left")
  func cancelsTransitions() {
    var newMatch = HSTrackerRecoveryObservation()
    newMatch.observe("Gameplay.Start()\nMulliganManager.HandleGameStart() - IsPastBeginPhase()=False\n")
    #expect(newMatch.state == .cancelled)
    var exited = HSTrackerRecoveryObservation()
    exited.observe(reconnect)
    exited.observe("LoadingScreen.OnScenePreUnload() - prevMode=GAMEPLAY nextMode=BACON\n")
    #expect(exited.state == .cancelled)
    exited.observe(reconnect)
    #expect(exited.state == .cancelled)
  }

  @Test("runs only for the installed version with the observed bug")
  func versions() {
    #expect(HSTrackerRecoveryPolicy.needsRecovery(version: "3.7.3"))
    #expect(!HSTrackerRecoveryPolicy.needsRecovery(version: "3.7.4"))
    #expect(!HSTrackerRecoveryPolicy.needsRecovery(version: ""))
  }

  @Test("recovery marker passes the tracker filter and invokes its gameStart condition")
  func markerContract() throws {
    let event = HSTrackerRecoveryPolicy.event(at: Date())
    let content = String(event.dropFirst(19))
    // HSTracker LogReaderManager's LoadingScreen prefix filter.
    #expect(content.hasPrefix("LoadingScreen.OnSceneLoaded"))
    // LoadingScreenHandler's actual GameModeRegex and gameStart condition.
    let regex = try NSRegularExpression(pattern: #"prevMode=(\w+).*currMode=(\w+)"#)
    let match = try #require(regex.firstMatch(in: event, range: NSRange(event.startIndex..., in: event)))
    let previous = (event as NSString).substring(with: match.range(at: 1))
    let current = (event as NSString).substring(with: match.range(at: 2))
    #expect(previous != "GAMEPLAY" && current == "GAMEPLAY")
    #expect(event.contains("source=HSReconnect.HSTrackerRecovery"))
    #expect(!event.contains("Gameplay.Start()"))
  }

  @Test("reports recovery only for two positive restored player IDs")
  func verification() {
    #expect(HSTrackerRecoveryPolicy.didRecoverPlayers(in:
      "12:00:09.123 INFO Game.updatePlayers():1997 - Local [PlayerId=7] vs Bob [PlayerId=15]\n"))
    #expect(!HSTrackerRecoveryPolicy.didRecoverPlayers(in:
      "Game.updatePlayers():1997 - Local [PlayerId=-1] vs Bob [PlayerId=15]"))
    #expect(!HSTrackerRecoveryPolicy.didRecoverPlayers(in: "Waiting for playerEntity"))
  }

  @Test("verification discards old player initialization and consumes only new records")
  func verificationOffset() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let log = try HSTrackerRecoveryLog(url: url)
    let writer = try FileHandle(forWritingTo: url)
    defer { try? writer.close() }
    let players = Data("Game.updatePlayers():1997 - Local [PlayerId=7] vs Bob [PlayerId=15]\n".utf8)
    // Initialization may still be queued when the reconnect request captures
    // its offsets. It must not confirm recovery of the replacement board.
    try writer.write(contentsOf: players)
    try log.discardPendingLines()
    #expect(!HSTrackerRecoveryPolicy.didRecoverPlayers(in: try log.readNewLines()))
    try writer.write(contentsOf: players)
    #expect(HSTrackerRecoveryPolicy.didRecoverPlayers(in: try log.readNewLines()))
  }

  @Test("reads only complete new lines and appends without replacing existing game data")
  func logAppend() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("LoadingScreen.log")
    let original = Data("previous reconnect\n".utf8)
    try original.write(to: url)
    let log = try HSTrackerRecoveryLog(url: url)
    #expect(try log.readNewLines().isEmpty)
    let gameWriter = try FileHandle(forWritingTo: url)
    defer { try? gameWriter.close() }
    try gameWriter.seekToEnd()
    try gameWriter.write(contentsOf: Data("Gameplay.St".utf8))
    #expect(try log.readNewLines().isEmpty)
    #expect(throws: HSTrackerRecoveryLogError.self) { try log.appendRecoveryEvent(at: Date()) }
    try gameWriter.write(contentsOf: Data("art()\n".utf8))
    #expect(try log.readNewLines() == "Gameplay.Start()\n")
    try gameWriter.write(contentsOf: Data("another game event\n".utf8))
    #expect(try log.appendRecoveryEvent(at: Date()) == false)
    #expect(try log.readNewLines() == "another game event\n")
    let date = Date()
    #expect(try log.appendRecoveryEvent(at: date))
    let actual = try Data(contentsOf: url)
    let expected = original + Data("Gameplay.Start()\nanother game event\n".utf8)
      + Data(HSTrackerRecoveryPolicy.event(at: date).utf8)
    #expect(actual == expected)
  }

  @Test("will not append to a replaced or truncated session log")
  func rejectsChangedFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("LoadingScreen.log")
    try Data("existing\n".utf8).write(to: url)
    let replaced = try HSTrackerRecoveryLog(url: url)
    try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("old.log"))
    try Data("replacement\n".utf8).write(to: url)
    #expect(throws: HSTrackerRecoveryLogError.self) { try replaced.appendRecoveryEvent(at: Date()) }
    #expect(try String(contentsOf: url, encoding: .utf8) == "replacement\n")
    let truncated = try HSTrackerRecoveryLog(url: url)
    let writer = try FileHandle(forWritingTo: url)
    try writer.truncate(atOffset: 0)
    try writer.close()
    #expect(throws: HSTrackerRecoveryLogError.self) { try truncated.readNewLines() }
  }

  @Test("rejects symlinks and nonregular files without blocking")
  func rejectsNonregularFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target.log")
    try Data("original\n".utf8).write(to: target)
    let link = directory.appendingPathComponent("link.log")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: HSTrackerRecoveryLogError.self) { try HSTrackerRecoveryLog(url: link) }
    let fifo = directory.appendingPathComponent("pipe.log")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: HSTrackerRecoveryLogError.self) { try HSTrackerRecoveryLog(url: fifo) }
    let original = try HSTrackerRecoveryLog(url: target)
    try FileManager.default.removeItem(at: target)
    #expect(mkfifo(target.path, 0o600) == 0)
    #expect(throws: HSTrackerRecoveryLogError.self) { try original.appendRecoveryEvent(at: Date()) }
  }
}
