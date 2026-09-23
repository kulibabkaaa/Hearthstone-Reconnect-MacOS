import AppKit
import Foundation
import HearthMirror

private struct CapturedPlayer: Codable, Equatable {
  let accountHigh: Int64
  let accountLow: Int64
  let heroCardID: String
  let name: String
}

private struct CaptureEvent: Codable, Equatable {
  let timestamp: String
  let event: String
  let hearthstonePID: Int32?
  let gameUUID: String?
  let gameType: Int?
  let region: String?
  let mode: String?
  let ownBattleTag: String?
  let ownAccountHigh: Int64?
  let ownAccountLow: Int64?
  let ownRating: Int?
  let players: [CapturedPlayer]
  let detail: String?
}

private final class EventWriter {
  private let encoder: JSONEncoder
  private let outputURL: URL?

  init() {
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
#if DEBUG
    outputURL = ProcessInfo.processInfo.environment["HS_LOBBY_CAPTURE_LOG"]
      .map(URL.init(fileURLWithPath:))
#else
    outputURL = nil
#endif
  }

  func write(_ event: CaptureEvent) {
    guard let data = try? encoder.encode(event) else { return }
    var line = data
    line.append(0x0a)
    FileHandle.standardOutput.write(line)

    guard let outputURL else { return }
    if !FileManager.default.fileExists(atPath: outputURL.path) {
      FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: outputURL) else { return }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } catch {
      FileHandle.standardError.write(
        Data("capture log write failed: \(error)\n".utf8)
      )
    }
  }
}

private final class LobbyCaptureProbe {
  private let writer = EventWriter()
  private let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private var mirror: HearthMirror?
  private var attachedPID: Int32?
  private var activeGameUUID: String?
  private var lastPayload: CaptureEvent?
  private var logSessionDirectory: String?
  private var attachedAt: Date?
  private var failedAttachmentPID: Int32?
  private var attachmentRetryAfter: Date?

  func run() -> Never {
    emit(event: "probe_started", detail: "Waiting for native Hearthstone.")

    while true {
      autoreleasepool {
        if hstrackerProcess() != nil {
          emitIfChanged(
            event: "blocked_hstracker_running",
            detail: "Quit HSTracker before running the standalone capture gate."
          )
          return
        }

        guard let hearthstone = hearthstoneProcess() else {
          if let gameUUID = activeGameUUID {
            emit(event: "match_suspended", gameUUID: gameUUID, detail: "Hearthstone exited during a match.")
          }
          resetAttachment(clearRetry: true)
          emitIfChanged(event: "waiting_for_hearthstone")
          return
        }

        if attachedPID != hearthstone.processIdentifier || mirror == nil {
          attach(to: hearthstone.processIdentifier)
        }
        capture()
      }
      Thread.sleep(forTimeInterval: 1)
    }
  }

  private func attach(to pid: Int32) {
    if !LobbyAttachRetryPolicy.canAttempt(
      failedPID: failedAttachmentPID,
      retryAfter: attachmentRetryAfter,
      currentPID: pid,
      now: Date()
    ) {
      return
    }
    if failedAttachmentPID != pid {
      failedAttachmentPID = nil
      attachmentRetryAfter = nil
    }
    resetAttachment()
    guard let application = NSRunningApplication(processIdentifier: pid),
          HearthstoneProcessTrust.isTrusted(application) else {
      recordAttachmentFailure(pid: pid)
      emitIfChanged(event: "attachment_failed", hearthstonePID: pid,
        detail: "Hearthstone could not be verified as the signed Blizzard application.")
      return
    }
    let permissionResult = acquireTaskportRight()
    guard permissionResult == 0 else {
      recordAttachmentFailure(pid: pid)
      emitIfChanged(
        event: "permission_failed",
        hearthstonePID: pid,
        detail: "acquireTaskportRight returned \(permissionResult)."
      )
      return
    }

    // Permission approval can take time; reject an exited or replaced process.
    guard HearthstoneProcessTrust.isTrusted(application) else { return }
    let candidate = HearthMirror(pid: pid, blocking: true)
    guard let logSessionDirectory = candidate.getLogSessionDir(), !logSessionDirectory.isEmpty else {
      recordAttachmentFailure(pid: pid)
      emitIfChanged(
        event: "attachment_failed",
        hearthstonePID: pid,
        detail: "HearthMirror did not expose a log session directory."
      )
      return
    }
    mirror = candidate
    attachedPID = pid
    self.logSessionDirectory = logSessionDirectory
    attachedAt = Date()
    failedAttachmentPID = nil
    attachmentRetryAfter = nil
    emit(event: "attached", hearthstonePID: pid)
  }

  private func recordAttachmentFailure(pid: Int32) {
    failedAttachmentPID = pid
    attachmentRetryAfter = Date().addingTimeInterval(LobbyAttachRetryPolicy.retryDelay)
  }

  private func capture() {
    guard let mirror, let attachedPID else { return }

    let lobby = mirror.getBattlegroundsLobbyInfo()
    let gameUUID = trimmed(lobby?.gameUuid)
    let account = mirror.getAccountId()
    let ratingInfo = mirror.getBattlegroundsRatingInfo()
    let mode = battlegroundsMode(mirror.getSelectedBattlegroundsGameMode().intValue)
    let ownRating: Int?
    switch mode {
    case "duos": ownRating = ratingInfo?.duosRating.intValue
    default: ownRating = ratingInfo?.rating.intValue
    }
    let players = (lobby?.players ?? []).prefix(8).map {
      CapturedPlayer(
        accountHigh: $0.accountId.hi.int64Value,
        accountLow: $0.accountId.lo.int64Value,
        heroCardID: $0.heroCardId,
        name: trimmed($0.name) ?? ""
      )
    }
    let namedPlayerCount = players.filter { !$0.name.isEmpty }.count
    let distinctAccountCount = Set(
      players.map { "\($0.accountHigh):\($0.accountLow)" }
    ).count
    let hasCompleteLobby = players.count == 8
      && namedPlayerCount == 8
      && distinctAccountCount == 8
    let captureDetail: String?
    if gameUUID == nil {
      captureDetail = nil
    } else if hasCompleteLobby {
      captureDetail = "Captured all eight lobby names with distinct account identities."
    } else {
      captureDetail = "Incomplete lobby capture: \(players.count) rows, "
        + "\(namedPlayerCount) nonempty names, "
        + "\(distinctAccountCount) distinct account identities."
    }
    let region = account.map { regionName(accountHigh: $0.hi.int64Value) }
    let gameType = mirror.getGameType()?.intValue ?? 0
    let reconnectPhase = LobbyReconnectPolicy.phase(
      gameUUIDPresent: gameUUID != nil,
      gameType: gameType,
      mode: mode,
      sessionLogSaysReconnect: sessionLogSaysReconnect(),
      secondsSinceAttachment: Date().timeIntervalSince(attachedAt ?? Date())
    )
    if reconnectPhase == .probing { return }
    let eventName: String
    if let gameUUID, activeGameUUID != gameUUID {
      if let previous = activeGameUUID {
        emit(event: "match_ended", hearthstonePID: attachedPID, gameUUID: previous)
      }
      activeGameUUID = gameUUID
      eventName = "match_started"
    } else if gameUUID != nil {
      eventName = "match_snapshot"
    } else if reconnectPhase == .resuming {
      eventName = "reconnecting_match"
    } else if let previous = activeGameUUID {
      activeGameUUID = nil
      emit(event: "match_ended", hearthstonePID: attachedPID, gameUUID: previous)
      return
    } else {
      eventName = "waiting_for_match"
    }

    emitIfChanged(
      event: eventName,
      hearthstonePID: attachedPID,
      gameUUID: gameUUID,
      gameType: gameType,
      region: region,
      mode: mode,
      ownBattleTag: trimmed(mirror.getBattleTag()),
      ownAccountHigh: account?.hi.int64Value,
      ownAccountLow: account?.lo.int64Value,
      ownRating: ownRating,
      players: players,
      detail: captureDetail
    )
  }

  private func resetAttachment(clearRetry: Bool = false) {
    mirror = nil
    attachedPID = nil
    activeGameUUID = nil
    logSessionDirectory = nil
    attachedAt = nil
    if clearRetry {
      failedAttachmentPID = nil
      attachmentRetryAfter = nil
    }
  }

  private func sessionLogSaysReconnect() -> Bool {
    guard let logSessionDirectory else { return false }
    let url = URL(fileURLWithPath: logSessionDirectory).appendingPathComponent("GameNetLogger.log")
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let fileSize = (try? handle.seekToEnd()) ?? 0
    let tailSize: UInt64 = 64 * 1024
    try? handle.seek(toOffset: fileSize > tailSize ? fileSize - tailSize : 0)
    guard let data = try? handle.readToEnd(),
          let text = String(data: data, encoding: .utf8) else { return false }
    return LobbyReconnectPolicy.sessionLogSaysReconnect(text)
  }

  private func hearthstoneProcess() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == HearthstoneProcessTrust.bundleIdentifier
    }
  }

  private func hstrackerProcess() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == "net.hearthsim.HSTracker"
        || $0.bundleIdentifier == "com.illiakulibaba.hstracker"
        || $0.localizedName == "HSTracker"
    }
  }

  private func regionName(accountHigh: Int64) -> String {
    switch Int((accountHigh >> 32) & 255) {
    case 1: return "Americas"
    case 2: return "EU"
    case 3: return "Asia-Pacific"
    case 5: return "China"
    default: return "unknown"
    }
  }

  private func battlegroundsMode(_ rawValue: Int) -> String {
    switch rawValue {
    case 1: return "solo"
    case 2: return "duos"
    default: return "unknown"
    }
  }

  private func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }

  private func emitIfChanged(
    event: String,
    hearthstonePID: Int32? = nil,
    gameUUID: String? = nil,
    gameType: Int? = nil,
    region: String? = nil,
    mode: String? = nil,
    ownBattleTag: String? = nil,
    ownAccountHigh: Int64? = nil,
    ownAccountLow: Int64? = nil,
    ownRating: Int? = nil,
    players: [CapturedPlayer] = [],
    detail: String? = nil
  ) {
    let payload = makeEvent(
      event: event,
      hearthstonePID: hearthstonePID,
      gameUUID: gameUUID,
      gameType: gameType,
      region: region,
      mode: mode,
      ownBattleTag: ownBattleTag,
      ownAccountHigh: ownAccountHigh,
      ownAccountLow: ownAccountLow,
      ownRating: ownRating,
      players: players,
      detail: detail
    )
    var comparable = payload
    if let lastPayload {
      comparable = CaptureEvent(
        timestamp: lastPayload.timestamp,
        event: payload.event,
        hearthstonePID: payload.hearthstonePID,
        gameUUID: payload.gameUUID,
        gameType: payload.gameType,
        region: payload.region,
        mode: payload.mode,
        ownBattleTag: payload.ownBattleTag,
        ownAccountHigh: payload.ownAccountHigh,
        ownAccountLow: payload.ownAccountLow,
        ownRating: payload.ownRating,
        players: payload.players,
        detail: payload.detail
      )
    }
    guard comparable != lastPayload else { return }
    lastPayload = payload
    writer.write(payload)
  }

  private func emit(
    event: String,
    hearthstonePID: Int32? = nil,
    gameUUID: String? = nil,
    detail: String? = nil
  ) {
    let payload = makeEvent(
      event: event,
      hearthstonePID: hearthstonePID,
      gameUUID: gameUUID,
      detail: detail
    )
    lastPayload = payload
    writer.write(payload)
  }

  private func makeEvent(
    event: String,
    hearthstonePID: Int32? = nil,
    gameUUID: String? = nil,
    gameType: Int? = nil,
    region: String? = nil,
    mode: String? = nil,
    ownBattleTag: String? = nil,
    ownAccountHigh: Int64? = nil,
    ownAccountLow: Int64? = nil,
    ownRating: Int? = nil,
    players: [CapturedPlayer] = [],
    detail: String? = nil
  ) -> CaptureEvent {
    CaptureEvent(
      timestamp: timestampFormatter.string(from: Date()),
      event: event,
      hearthstonePID: hearthstonePID,
      gameUUID: gameUUID,
      gameType: gameType,
      region: region,
      mode: mode,
      ownBattleTag: ownBattleTag,
      ownAccountHigh: ownAccountHigh,
      ownAccountLow: ownAccountLow,
      ownRating: ownRating,
      players: players,
      detail: detail
    )
  }
}

LobbyCaptureProbe().run()
