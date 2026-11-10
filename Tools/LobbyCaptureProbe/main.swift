import AppKit
import Darwin
import Foundation
import HearthMirror
import Security

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
  private let expectedParentPID = ProcessInfo.processInfo.environment[
    "HS_RECONNECT_PARENT_PID"
  ].flatMap(Int32.init)
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
  private var attachmentFailureCount = 0
  /// The last failure was "the game isn't ready" while macOS granted access with no dialog. The next attempt
  /// then never calls acquireTaskportRight(): it attaches if access is still granted silently and otherwise
  /// stops with "permission_failed". So a long wait for sign-in can never bring a permission dialog back.
  private var retryWithoutPrompt = false
  /// When the attached reader's class list was read, and how many of the scheduled re-reads are done.
  private var mirrorSnapshotAt: Date?
  private var mirrorRefreshesDone = 0
  /// Match detection only (lobby info off, Reconnect button on): never show the lobby access dialog.
  private let quietAttach = ProcessInfo.processInfo.environment["HS_RECONNECT_QUIET_ATTACH"] == "1"
  private static let quietRetryInterval: TimeInterval = 30
  private var quietRetryAfter: Date?

  func run() -> Never {
    emit(event: "probe_started", detail: "Waiting for native Hearthstone.")

    while true {
      // A forced app quit cannot run LobbyReader.stop(). Do not keep an orphaned
      // probe attached to Hearthstone or show later permission dialogs.
      if let expectedParentPID, getppid() != expectedParentPID { exit(0) }
      autoreleasepool {
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
        } else {
          refreshMirrorIfDue(pid: hearthstone.processIdentifier)
        }
        capture()
      }
      Thread.sleep(forTimeInterval: 1)
    }
  }

  private func attach(to pid: Int32) {
    if quietAttach, let quietRetryAfter, Date() < quietRetryAfter { return }
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
      attachmentFailureCount = 0
      retryWithoutPrompt = false
    }
    resetAttachment()
    guard let application = NSRunningApplication(processIdentifier: pid),
          HearthstoneProcessTrust.isTrusted(application) else {
      let willRetry = recordAttachmentFailure(pid: pid, kind: .mayPrompt)
      emitIfChanged(event: willRetry ? "attachment_retrying" : "attachment_failed",
        hearthstonePID: pid,
        detail: "Hearthstone could not be verified as the signed Blizzard application.")
      return
    }
    // acquireTaskportRight() may show a password dialog. Quiet mode skips it and attaches only when macOS
    // already grants task_for_pid's right without one (an approval within its 10 h timeout, or developer tools
    // access enabled), and checks again later. So does a retry for a game that is still starting.
    let grantedWithoutDialog = (quietAttach || retryWithoutPrompt) && Self.taskportRightGrantedWithoutDialog()
    if quietAttach && !grantedWithoutDialog {
      quietRetryAfter = Date().addingTimeInterval(Self.quietRetryInterval)
      emitIfChanged(event: "permission_unavailable", hearthstonePID: pid,
        detail: "Lobby access isn't granted now; match detection doesn't ask for it.")
      return
    }
    if retryWithoutPrompt && !grantedWithoutDialog {
      // The approval ran out (or was revoked) while waiting for the game to sign in, possibly hours after the
      // player last looked. Don't ask now: the app shows "Lobby access needs approval" with Retry instead.
      recordAttachmentFailure(pid: pid, kind: .permissionLapsed)
      emitIfChanged(event: "permission_failed", hearthstonePID: pid,
        detail: "Lobby access is no longer granted without asking.")
      return
    }
    let permissionResult = grantedWithoutDialog ? 0 : acquireTaskportRight()
    guard permissionResult == 0 else {
      let rejected = permissionResult == errAuthorizationCanceled
        || permissionResult == errAuthorizationDenied
      let willRetry = recordAttachmentFailure(pid: pid, kind: rejected ? .permissionRejected : .mayPrompt)
      emitIfChanged(
        event: willRetry ? "attachment_retrying" : "permission_failed",
        hearthstonePID: pid,
        detail: "acquireTaskportRight returned \(permissionResult)."
      )
      return
    }

    // Permission approval can take time; reject an exited or replaced process.
    guard HearthstoneProcessTrust.isTrusted(application) else { return }
    // HearthMirror lists the game's classes once, here, and keeps one process-wide pointer to the newest list.
    // So a reader made before Hearthstone signs in stays blind to classes loaded later (the lobby among them),
    // and only the newest reader may ever be used: resetAttachment() above let go of the previous one.
    let candidate = HearthMirror(pid: pid, blocking: true)
    let logSessionDirectory = candidate.getLogSessionDir() ?? ""
    let signedIn = !logSessionDirectory.isEmpty && Self.isSignedIn(candidate)
    // Asked only when it decides something: another reader must never cost a dialog.
    let canRetryWithoutDialog = !signedIn && Self.taskportRightGrantedWithoutDialog()
    switch LobbyMirrorReadinessPolicy.disposition(
      hasLogSessionDirectory: !logSessionDirectory.isEmpty, signedIn: signedIn,
      canRetryWithoutDialog: canRetryWithoutDialog
    ) {
    case .failed:
      let willRetry = recordAttachmentFailure(
        pid: pid, kind: canRetryWithoutDialog ? .gameNotReadable : .mayPrompt)
      emitIfChanged(
        event: willRetry ? "attachment_retrying" : "attachment_failed",
        hearthstonePID: pid,
        detail: "HearthMirror did not expose a log session directory."
      )
      return
    case .retryLater:
      recordAttachmentFailure(pid: pid, kind: .notSignedIn)
      emitIfChanged(event: "attachment_retrying", hearthstonePID: pid,
        detail: "Hearthstone is still starting.")
      return
    case .accept:
      break
    }
    mirror = candidate
    attachedPID = pid
    self.logSessionDirectory = logSessionDirectory
    attachedAt = Date()
    mirrorSnapshotAt = attachedAt
    mirrorRefreshesDone = 0
    failedAttachmentPID = nil
    attachmentRetryAfter = nil
    attachmentFailureCount = 0
    retryWithoutPrompt = false
    emit(event: "attached", hearthstonePID: pid)
  }

  private static func isSignedIn(_ mirror: HearthMirror) -> Bool {
    let account = mirror.getAccountId()
    return LobbyMirrorReadinessPolicy.isSignedIn(
      battleTag: mirror.getBattleTag(),
      accountHigh: account?.hi.int64Value, accountLow: account?.lo.int64Value)
  }

  /// Signing in comes before the menus finish loading, so the class list is read again a few times while no
  /// match is on screen. A re-read never asks for permission. If it can't be made silently, the reader in
  /// use stays.
  private func refreshMirrorIfDue(pid: Int32) {
    guard let snapshotAt = mirrorSnapshotAt,
          LobbyMirrorRefreshPolicy.isDue(now: Date(), snapshotAt: snapshotAt,
                                         refreshesDone: mirrorRefreshesDone,
                                         matchVisible: activeGameUUID != nil) else { return }
    mirrorRefreshesDone += 1
    mirrorSnapshotAt = Date()
    guard Self.taskportRightGrantedWithoutDialog() else { return }
    // Let go of the reader in use before making the next one (see attach(to:)).
    mirror = nil
    let candidate = HearthMirror(pid: pid, blocking: true)
    guard let directory = candidate.getLogSessionDir(), !directory.isEmpty else {
      // Hearthstone is closing or stopped being readable: attach again from the start, silently.
      attachedPID = nil
      recordAttachmentFailure(pid: pid, kind: .gameNotReadable)
      return
    }
    mirror = candidate
    logSessionDirectory = directory
    // For the app's log only; written directly so it doesn't disturb `emitIfChanged`'s last payload.
    writer.write(makeEvent(event: "reader_refreshed", hearthstonePID: pid))
  }

  /// The right task_for_pid (inside HearthMirror's init) is checked against, with no user interaction allowed.
  /// Not the one `acquireTaskportRight()` asks for: HearthMirror spells it "system.privilege.taskport:", which
  /// has no rule of its own and falls back to the default admin rule (5 min timeout).
  private static func taskportRightGrantedWithoutDialog() -> Bool {
    var authorization: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
          let authorization else { return false }
    defer { AuthorizationFree(authorization, []) }
    return "system.privilege.taskport".withCString { name in
      var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
      return withUnsafeMutablePointer(to: &item) { pointer in
        var rights = AuthorizationRights(count: 1, items: pointer)
        return AuthorizationCopyRights(authorization, &rights, nil, [.extendRights], nil) == errAuthorizationSuccess
      }
    }
  }

  @discardableResult
  private func recordAttachmentFailure(pid: Int32, kind: LobbyAttachFailureKind) -> Bool {
    if failedAttachmentPID != pid { attachmentFailureCount = 0 }
    attachmentFailureCount += 1
    failedAttachmentPID = pid
    retryWithoutPrompt = kind.retriesSilently
    attachmentRetryAfter = LobbyAttachRetryPolicy.retryAfter(
      now: Date(), failureCount: attachmentFailureCount, kind: kind
    )
    return attachmentRetryAfter != .distantFuture
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
    mirrorSnapshotAt = nil
    mirrorRefreshesDone = 0
    if clearRetry {
      quietRetryAfter = nil
      failedAttachmentPID = nil
      attachmentRetryAfter = nil
      attachmentFailureCount = 0
      retryWithoutPrompt = false
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
