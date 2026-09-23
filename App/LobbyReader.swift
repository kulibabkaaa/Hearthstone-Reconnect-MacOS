import AppKit
import Foundation

struct LobbyCapture: Codable, Equatable {
  let gameUUID: String?
  let gameType: Int
  let region: String
  let mode: String
  let ownBattleTag: String?
  let ownAccountID: LobbyAccountID?
  let ownRating: Int?
  let players: [LobbyPlayer]
}

private struct LobbyHelperPlayer: Decodable {
  let accountHigh: Int64
  let accountLow: Int64
  let name: String
}

private struct LobbyHelperEvent: Decodable {
  let event: String
  let gameUUID: String?
  let gameType: Int?
  let region: String?
  let mode: String?
  let ownBattleTag: String?
  let ownAccountHigh: Int64?
  let ownAccountLow: Int64?
  let ownRating: Int?
  let players: [LobbyHelperPlayer]
}

struct LobbyReaderDeliveryToken: Equatable, Sendable {
  fileprivate let run: Int
  fileprivate let process: Int?
}

final class LobbyReaderDeliveryGeneration: @unchecked Sendable {
  private let lock = NSLock()
  private var run = 0
  private var process = 0
  private var running = false

  func startRun() -> LobbyReaderDeliveryToken {
    lock.lock(); defer { lock.unlock() }
    if !running { run += 1; process = 0; running = true }
    return LobbyReaderDeliveryToken(run: run, process: nil)
  }

  func stopRun() {
    lock.lock(); defer { lock.unlock() }
    running = false
    run += 1
    process += 1
  }

  func beginProcess(for token: LobbyReaderDeliveryToken) -> LobbyReaderDeliveryToken? {
    lock.lock(); defer { lock.unlock() }
    guard running, token.run == run, token.process == nil else { return nil }
    process += 1
    return LobbyReaderDeliveryToken(run: run, process: process)
  }

  func invalidateProcess(for token: LobbyReaderDeliveryToken) {
    lock.lock(); defer { lock.unlock() }
    guard running, token.run == run else { return }
    process += 1
  }

  func accepts(_ token: LobbyReaderDeliveryToken) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard running, token.run == run else { return false }
    return token.process == nil || token.process == process
  }
}

final class LobbyReader {
  private static let maximumEventBytes = 256 * 1_024
  var onCapture: ((LobbyCapture) -> Void)?
  var onReconnectDetected: (() -> Void)?
  var onStatus: ((String) -> Void)?

  private let queue = DispatchQueue(label: "HSReconnect.LobbyReader")
  private let decoder = JSONDecoder()
  private let deliveryGeneration = LobbyReaderDeliveryGeneration()
  private var process: Process?
  private var activeProcessToken: LobbyReaderDeliveryToken?
  private var outputHandle: FileHandle?
  private var outputBuffer = Data()
  private var shouldRun = false
  private var observedHearthstonePID: Int32?
  private var hearthstoneMonitor: DispatchSourceTimer?

  func start() {
    let runToken = deliveryGeneration.startRun()
    queue.async {
      guard self.deliveryGeneration.accepts(runToken) else { return }
      if !self.shouldRun {
        self.shouldRun = true
        self.observedHearthstonePID = self.currentHearthstonePID()
        self.startHearthstoneMonitor(runToken: runToken)
      }
      self.launchIfNeeded(runToken: runToken)
    }
  }

  func stop() {
    deliveryGeneration.stopRun()
    queue.async {
      self.shouldRun = false
      self.outputHandle?.readabilityHandler = nil
      self.outputHandle = nil
      self.outputBuffer.removeAll(keepingCapacity: false)
      self.hearthstoneMonitor?.cancel()
      self.hearthstoneMonitor = nil
      self.observedHearthstonePID = nil
      self.process?.terminationHandler = nil
      if self.process?.isRunning == true { self.process?.terminate() }
      self.process = nil
      self.activeProcessToken = nil
    }
  }

  func retrySetup() {
    queue.async {
      guard self.shouldRun else { return }
      let runToken = self.deliveryGeneration.startRun()
      guard self.deliveryGeneration.accepts(runToken) else { return }
      self.restartCaptureHelper(runToken: runToken)
    }
  }

  private func startHearthstoneMonitor(runToken: LobbyReaderDeliveryToken) {
    guard hearthstoneMonitor == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in self?.pollHearthstoneProcess(runToken: runToken) }
    timer.resume()
    hearthstoneMonitor = timer
  }

  private func pollHearthstoneProcess(runToken: LobbyReaderDeliveryToken) {
    guard deliveryGeneration.accepts(runToken) else { return }
    let currentPID = currentHearthstonePID()
    defer { observedHearthstonePID = currentPID }
    guard LobbyHelperProcessPolicy.shouldRestart(
      previousPID: observedHearthstonePID,
      currentPID: currentPID
    ) else { return }
    restartCaptureHelper(runToken: runToken)
  }

  private func restartCaptureHelper(runToken: LobbyReaderDeliveryToken) {
    guard shouldRun, deliveryGeneration.accepts(runToken) else { return }
    deliveryGeneration.invalidateProcess(for: runToken)
    activeProcessToken = nil
    outputHandle?.readabilityHandler = nil
    outputHandle = nil
    outputBuffer.removeAll(keepingCapacity: false)
    process?.terminationHandler = nil
    if process?.isRunning == true { process?.terminate() }
    process = nil
    status("Restarting lobby capture…", token: runToken)
    queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.launchIfNeeded(runToken: runToken)
    }
  }

  private func currentHearthstonePID() -> Int32? {
    NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
    }?.processIdentifier
  }

  private func launchIfNeeded(runToken: LobbyReaderDeliveryToken) {
    guard shouldRun, deliveryGeneration.accepts(runToken), process == nil else { return }
    let helper = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app")
      .appendingPathComponent("Contents/MacOS/HS Reconnect Lobby Capture Probe")
    guard FileManager.default.isExecutableFile(atPath: helper.path) else {
      status("Lobby capture helper is missing", token: runToken)
      return
    }

    guard let processToken = deliveryGeneration.beginProcess(for: runToken) else { return }
    activeProcessToken = processToken

    let process = Process()
    let output = Pipe()
    process.executableURL = helper
    process.environment = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "TMPDIR": FileManager.default.temporaryDirectory.path,
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.queue.async {
        guard let self, self.process === process else { return }
        self.consume(data, token: processToken)
      }
    }
    process.terminationHandler = { [weak self, weak process] _ in
      self?.queue.async {
        guard let self, self.process === process,
              self.deliveryGeneration.accepts(processToken) else { return }
        self.deliveryGeneration.invalidateProcess(for: runToken)
        self.activeProcessToken = nil
        self.outputHandle?.readabilityHandler = nil
        self.outputHandle = nil
        self.process = nil
        self.outputBuffer.removeAll(keepingCapacity: false)
        guard self.shouldRun, self.deliveryGeneration.accepts(runToken) else { return }
        self.status("Restarting lobby capture…", token: runToken)
        self.queue.asyncAfter(deadline: .now() + 2) {
          self.launchIfNeeded(runToken: runToken)
        }
      }
    }

    do {
      try process.run()
      self.process = process
      outputHandle = output.fileHandleForReading
    } catch {
      deliveryGeneration.invalidateProcess(for: runToken)
      activeProcessToken = nil
      status("Lobby capture could not start", token: runToken)
      queue.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.launchIfNeeded(runToken: runToken)
      }
    }
  }

  private func consume(_ data: Data, token: LobbyReaderDeliveryToken) {
    guard shouldRun, activeProcessToken == token,
          deliveryGeneration.accepts(token) else { return }
    guard data.count <= Self.maximumEventBytes else {
      outputBuffer.removeAll(keepingCapacity: false)
      status("Lobby capture returned invalid data", token: token)
      return
    }
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0a) {
      let line = outputBuffer[..<newline]
      outputBuffer.removeSubrange(...newline)
      guard !line.isEmpty,
            line.count <= Self.maximumEventBytes,
            let event = try? decoder.decode(LobbyHelperEvent.self, from: Data(line)) else {
        continue
      }
      accept(event, token: token)
    }
    if outputBuffer.count > Self.maximumEventBytes {
      outputBuffer.removeAll(keepingCapacity: false)
      status("Lobby capture returned invalid data", token: token)
    }
  }

  private func accept(_ event: LobbyHelperEvent, token: LobbyReaderDeliveryToken) {
    guard deliveryGeneration.accepts(token) else { return }
    switch event.event {
    case "probe_started", "waiting_for_hearthstone", "match_suspended":
      status("Waiting for Hearthstone", token: token)
    case "blocked_hstracker_running":
      emitEmptyCaptureIfNeeded(for: event, token: token)
      status("Quit HSTracker to use lobby info", token: token)
    case "permission_failed", "attachment_failed":
      emitEmptyCaptureIfNeeded(for: event, token: token)
      status("Lobby setup needs approval", token: token)
    case "attached":
      status("Waiting for a Solo match", token: token)
    case "reconnecting_match":
      status("Restoring lobby info…", token: token)
      deliver(token: token) { $0.onReconnectDetected?() }
    case "match_started", "match_snapshot", "waiting_for_match", "match_ended":
      emitCapture(event, token: token)
    default:
      break
    }
  }

  private func emitEmptyCaptureIfNeeded(for event: LobbyHelperEvent,
                                        token: LobbyReaderDeliveryToken) {
    guard event.event != "probe_started" else { return }
    emitCapture(event, forceNoMatch: true, token: token)
  }

  private func emitCapture(_ event: LobbyHelperEvent, forceNoMatch: Bool = false,
                           token: LobbyReaderDeliveryToken) {
    let noMatch = forceNoMatch || event.event == "waiting_for_match" || event.event == "match_ended"
    let ownAccountID: LobbyAccountID?
    if let high = event.ownAccountHigh, let low = event.ownAccountLow {
      ownAccountID = LobbyAccountID(high: high, low: low)
    } else {
      ownAccountID = nil
    }
    let capture = LobbyCapture(
      gameUUID: noMatch ? nil : event.gameUUID,
      gameType: event.gameType ?? 0,
      region: normalizedRegion(event.region),
      mode: event.mode ?? "unknown",
      ownBattleTag: event.ownBattleTag,
      ownAccountID: ownAccountID,
      ownRating: event.ownRating,
      players: event.players.prefix(8).enumerated().map { index, player in
        LobbyPlayer(
          position: index,
          accountID: LobbyAccountID(high: player.accountHigh, low: player.accountLow),
          name: player.name
        )
      }
    )
    deliver(token: token) { $0.onCapture?(capture) }
  }

  private func normalizedRegion(_ value: String?) -> String {
    switch value {
    case "Americas": return "US"
    case "Asia-Pacific": return "AP"
    case "China": return "CN"
    case "EU", "US", "AP", "CN": return value ?? "unknown"
    default: return "unknown"
    }
  }

  private func status(_ text: String, token: LobbyReaderDeliveryToken) {
    deliver(token: token) { $0.onStatus?(text) }
  }

  private func deliver(token: LobbyReaderDeliveryToken,
                       action: @escaping (LobbyReader) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.deliveryGeneration.accepts(token) else { return }
      action(self)
    }
  }
}
