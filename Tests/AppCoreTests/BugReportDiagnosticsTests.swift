import Foundation
import Testing
@testable import AppCore

struct BugReportDiagnosticsTests {
  // Real line shapes from a Hearthstone session (identifiers replaced).
  private let gameNetLog = """
    D 12:26:27.6986650 ReconnectMgr.OnLoginComplete() - Stored web token provided to BattleNet successfully, login completed.
    I 12:27:22.1111111 GameMgr.ChangeFindGameState() - state: CLIENT_STARTED, previous state: INVALID
    D 12:27:22.1111112 GameMgr.DoDefaultFindGameEventBehavior() -  FindGameEventData: CLIENT_STARTED
    I 12:27:44.8050700 Network.GotoGameServe() - gameConnectionDisconnected True, IsRestoringGameState: False
    I 12:27:44.8050710 Network.GotoGameServe() - address= 5.42.177.80:1119, game=8323, client=123456789, spectateKey=iddahD reconnecting=False
    I 12:27:50.0000000 GameMgr.ChangeFindGameState() - state: SERVER_GAME_STARTED, previous state: SERVER_GAME_CONNECTING
    I 12:30:52.0000000 Network.DisconnectFromGameServer() - Reason: EndGameScreen
    D 12:31:00.0000000 PowerTaskList.DebugPrintPower() - TAG_CHANGE Entity=Somebody#1234 tag=PLAYSTATE value=WON
    """

  private func input(
    gameNetLog: String? = nil,
    hearthstoneLog: String? = nil,
    battleNetLog: String? = nil,
    appLogEntries: [BugReportAppLogEntry] = [],
    logFolderName: String? = "Hearthstone_2026_11_11_12_26_22"
  ) -> BugReportDiagnosticsInput {
    BugReportDiagnosticsInput(
      appVersion: "2.2.0",
      buildNumber: "51",
      macOSVersion: "Version 26.1 (Build 25B78)",
      architecture: "arm64",
      extensionState: "enabled",
      proxyState: "connected",
      trackerRecoveryEnabled: false,
      hearthstoneRunning: true,
      logFolderName: logFolderName,
      gameNetLog: gameNetLog,
      hearthstoneLog: hearthstoneLog,
      battleNetLog: battleNetLog,
      appLogEntries: appLogEntries,
      generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }

  @Test func reconnectTargetLinePassesRedactionUnchanged() {
    for line in [
      "choice=loggedAndOpen logged=1 open=8", "choice=openGameConnection logged=1 open=5",
      "choice=loggedUnchecked logged=3 open=-1", "choice=none logged=0 open=2",
    ] {
      #expect(BugReportDiagnostics.redact(line) == line)
    }
  }

  @Test func matchPresenceLinePassesRedactionUnchangedAndIsAllowed() {
    for line in [
      "inMatch=true detector=attached gamePort=2 loggedServer=true phase=joined kind=battlegrounds logs=true",
      "inMatch=false detector=connecting hearthstone=0",
      "inMatch=false detector=connecting stopped",
      "inMatch=false detector=unavailable gamePort=0 loggedServer=false phase=none kind=unknown logs=false",
    ] {
      #expect(BugReportDiagnostics.redact(line) == line)
      #expect(DiagnosticLogFormat.clean(line) == line)
    }
    #expect(BugReportDiagnostics.appLogCategories.contains("MatchPresence"))
    #expect(!BugReportDiagnostics.appLogCategories.contains("LobbyCapture"))
  }

  @Test func frequentCategoriesCannotPushOutTheReconnectLines() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reconnect = (0 ..< 5).map {
      BugReportAppLogEntry(
        date: now.addingTimeInterval(-3_600 + Double($0)), category: "ReconnectTarget", level: "notice",
        message: "choice=loggedAndOpen logged=1 open=\($0)")
    }
    let presence = (0 ..< 500).map {
      BugReportAppLogEntry(
        date: now.addingTimeInterval(-1_000 + Double($0)), category: "MatchPresence", level: "notice",
        message: "inMatch=\($0 % 2 == 0) detector=attached n=\($0)")
    }
    let lines = BugReportDiagnostics.appLogLines(from: presence + reconnect, now: now)

    #expect(lines.filter { $0.contains("[ReconnectTarget]") }.count == 5)
    #expect(lines.filter { $0.contains("[MatchPresence]") }.count == BugReportDiagnostics.maximumAppLogLinesPerCategory)
    #expect(lines.last?.contains("n=499") == true)
    #expect(lines.first?.contains("[ReconnectTarget]") == true)
  }

  @Test func keepsOnlyConnectionLinesFromGameLogs() {
    let lines = BugReportDiagnostics.gameLogLines(in: gameNetLog)

    #expect(lines.count == 5)
    #expect(lines.allSatisfy {
      $0.contains("GotoGameServe()") || $0.contains("DisconnectFromGameServer")
        || $0.contains("ChangeFindGameState")
    })
    #expect(!lines.joined().contains("token"))
    #expect(!lines.joined().contains("Somebody"))
  }

  @Test func blanksGameClientAndSpectateKeysButKeepsTheAddress() {
    let lines = BugReportDiagnostics.gameLogLines(in: gameNetLog)
    let address = lines.first { $0.contains("address=") }

    #expect(
      address
        == "I 12:27:44.8050710 Network.GotoGameServe() - address= 5.42.177.80:1119, game=x, client=x, spectateKey=x reconnecting=False"
    )
  }

  @Test func keepsOnlyTheNewestLinesPerFile() {
    let many = (0 ..< 400).map {
      "I 12:00:00.\($0) GameMgr.ChangeFindGameState() - state: S\($0), previous state: INVALID"
    }.joined(separator: "\n")
    let lines = BugReportDiagnostics.gameLogLines(in: many)

    #expect(lines.count == BugReportDiagnostics.maximumGameLinesPerFile)
    #expect(lines.last?.contains("S399") == true)
    #expect(lines.first?.contains("S250") == true)
  }

  @Test func redactsPersonalValuesAnywhereInALine() {
    let redacted = BugReportDiagnostics.redact(
      "player Somebody#12345 AccountId=hi=1,lo=2 GameAccountId=[hi=3] mail me@example.com path /Users/illia/Library/x"
    )

    #expect(!redacted.contains("Somebody"))
    #expect(!redacted.contains("12345"))
    #expect(!redacted.contains("lo=2"))
    #expect(!redacted.contains("me@example.com"))
    #expect(!redacted.contains("illia"))
    #expect(redacted.contains("<battletag>"))
    #expect(redacted.contains("/Users/~/Library/x"))
  }

  @Test func redactsUnusualSpacingCaseAndPathShapes() {
    let redacted = BugReportDiagnostics.redact(
      "address= 1.2.3.4:1119, game= 8323, Client=99, SpectateKey=abc hi: 1441, lo: 2222 Ли́са#2345 /Users/John Smith/Library"
    )

    #expect(!redacted.contains("8323"))
    #expect(!redacted.contains("99"))
    #expect(!redacted.contains("abc"))
    #expect(!redacted.contains("1441"))
    #expect(!redacted.contains("2222"))
    #expect(!redacted.contains("Ли"))
    #expect(!redacted.contains("Smith"))
    #expect(redacted.contains("1.2.3.4:1119"))
  }

  @Test func readsOnlyTheRegionHostFromBattleNetLog() {
    let battleNet = """
      I 12:26:26.1 [] Connection Request to 'eu.actual.battle.net:1119' with Aurora Version '37.0.0.0'
      D 12:26:27.1 [] Logged in as Somebody#1234 account 99999
      """

    #expect(BugReportDiagnostics.regionHost(inBattleNetLog: battleNet) == "eu.actual.battle.net")
    #expect(BugReportDiagnostics.regionHost(inBattleNetLog: "nothing here") == nil)

    let text = BugReportDiagnostics.render(input(battleNetLog: battleNet))
    #expect(text.contains("Battle.net region host: eu.actual.battle.net"))
    #expect(!text.contains("Somebody"))
    #expect(!text.contains("99999"))
  }

  @Test func keepsOnlyAllowedAppLogCategoriesInTheLookbackWindow() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let entries = [
      BugReportAppLogEntry(
        date: now.addingTimeInterval(-60), category: "ReconnectTarget", level: "notice",
        message: "Closing flow for game server"),
      BugReportAppLogEntry(
        date: now.addingTimeInterval(-30), category: "LobbyCapture", level: "notice",
        message: "helper: lobby of Somebody"),
      BugReportAppLogEntry(
        date: now.addingTimeInterval(-4 * 24 * 60 * 60), category: "TrackerRecovery", level: "notice",
        message: "too old"),
      BugReportAppLogEntry(
        date: now.addingTimeInterval(-10), category: "TrackerRecovery", level: "notice",
        message: "Recovery for HSTracker build 4000: wrote"),
    ]
    let lines = BugReportDiagnostics.appLogLines(from: entries, now: now)

    #expect(lines.count == 2)
    #expect(lines[0].contains("[ReconnectTarget] notice: Closing flow"))
    #expect(lines[1].contains("[TrackerRecovery]"))
    #expect(!lines.joined().contains("Somebody"))
    #expect(!lines.joined().contains("too old"))
  }

  @Test func rendersHeaderAndExplainsMissingFiles() {
    let text = BugReportDiagnostics.render(input(gameNetLog: gameNetLog, logFolderName: nil))

    #expect(text.hasPrefix("HS Reconnect diagnostics\n"))
    #expect(text.contains("App: 2.2.0 (51), arm64"))
    #expect(text.contains("Network extension: enabled"))
    #expect(text.contains("Hearthstone log folder: not found"))
    #expect(text.contains("== Hearthstone.log (matching lines only) ==\n(file not found)"))
    #expect(text.contains("== HS Reconnect log (last 3 days) ==\n(no entries)"))
    #expect(text.contains("spectateKey=x"))
  }

  @Test func hidesUnexpectedFolderNames() {
    let text = BugReportDiagnostics.render(input(logFolderName: "Somebody's logs"))

    #expect(text.contains("Hearthstone log folder: found"))
    #expect(!text.contains("Somebody"))
  }

  @Test func staysWithinTheSizeLimitEvenWithHugeInput() {
    let longLine = "I 12:00:00.0 Network.GotoGameServe() - " + String(repeating: "a", count: 5_000)
    let huge = Array(repeating: longLine, count: 1_600).joined(separator: "\n")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let entries = (0 ..< 5_000).map {
      BugReportAppLogEntry(
        date: now.addingTimeInterval(-Double($0)), category: "ReconnectTarget", level: "notice",
        message: String(repeating: "b", count: 2_000))
    }
    let text = BugReportDiagnostics.render(
      input(gameNetLog: huge, hearthstoneLog: huge, appLogEntries: entries)
    )

    #expect(text.utf8.count <= BugReportDiagnostics.maximumBytes)
    #expect(text.contains("GotoGameServe()"))
  }

  @Test func retriesWithoutTheFileOnlyForContentRefusals() {
    for status in [400, 403, 413, 415, 422] {
      #expect(BugReportDiagnostics.shouldRetryWithoutAttachment(statusCode: status))
    }
    for status in [200, 301, 408, 429, 500, 502, 503] {
      #expect(!BugReportDiagnostics.shouldRetryWithoutAttachment(statusCode: status))
    }
  }

  @Test func findsTheBattleNetRegionInAnOlderFolderAndSaysWhere() {
    let folders: [(name: String, modified: Date, hasBattleNetLog: Bool)] = [
      ("Hearthstone_2026_11_15_18_00_00", Date(timeIntervalSince1970: 900), false),
      ("Hearthstone_2026_11_11_12_26_22", Date(timeIntervalSince1970: 500), true),
      ("Hearthstone_2026_11_10_00_47_36", Date(timeIntervalSince1970: 100), true),
      ("Other", Date(timeIntervalSince1970: 999), true),
    ]

    #expect(
      BugReportDiagnostics.battleNetLogCandidates(currentFolder: "Hearthstone_2026_11_15_18_00_00", among: folders)
        == ["Hearthstone_2026_11_11_12_26_22", "Hearthstone_2026_11_10_00_47_36"]
    )
    #expect(
      BugReportDiagnostics.battleNetLogCandidates(currentFolder: "Hearthstone_2026_11_10_00_47_36", among: folders)
        == ["Hearthstone_2026_11_10_00_47_36", "Hearthstone_2026_11_11_12_26_22"]
    )
    let many = (0 ..< 9).map { ("Hearthstone_\($0)", Date(timeIntervalSince1970: Double($0)), true) }
    #expect(
      BugReportDiagnostics.battleNetLogCandidates(currentFolder: nil, among: many).count
        == BugReportDiagnostics.maximumBattleNetLogFolders
    )

    var withSource = input(battleNetLog: "Connecting to wss://eu.actual.battle.net:1119/")
    withSource.battleNetLogFolderName = "Hearthstone_2026_11_10_00_47_36"
    #expect(
      BugReportDiagnostics.render(withSource)
        .contains("Battle.net region host: eu.actual.battle.net (from Hearthstone_2026_11_10_00_47_36)")
    )
    #expect(BugReportDiagnostics.render(input(battleNetLog: "no host")).contains("Battle.net region host: not found"))
    var sameFolder = input(battleNetLog: "Connecting to wss://eu.actual.battle.net:1119/")
    sameFolder.battleNetLogFolderName = sameFolder.logFolderName
    #expect(BugReportDiagnostics.render(sameFolder).contains("Battle.net region host: eu.actual.battle.net\n"))
  }

  @Test func picksTheNewestHearthstoneLogFolder() {
    let folders: [(name: String, modified: Date)] = [
      ("Hearthstone_2026_11_10_00_47_36", Date(timeIntervalSince1970: 100)),
      ("Hearthstone_2026_11_11_12_26_22", Date(timeIntervalSince1970: 300)),
      ("Other", Date(timeIntervalSince1970: 900)),
    ]

    #expect(BugReportDiagnostics.newestLogFolder(among: folders) == "Hearthstone_2026_11_11_12_26_22")
    #expect(BugReportDiagnostics.newestLogFolder(among: []) == nil)
  }

  @Test func multipartBodyAttachesDiagnosticsOnlyWhenGiven() throws {
    let content = try BugReportContent(
      description: "Every match after the first says no game found.",
      replyEmail: "player@example.com",
      appVersion: "2.2.0",
      buildNumber: "51",
      macOSVersion: "26.1"
    )
    let without = BugReportMultipartBody(content: content, imageJPEGs: [], boundary: "B")
    let with = BugReportMultipartBody(
      content: content, imageJPEGs: [], diagnosticsText: "HS Reconnect diagnostics\n", boundary: "B"
    )
    let withoutText = String(decoding: without.data, as: UTF8.self)
    let withText = String(decoding: with.data, as: UTF8.self)

    #expect(!withoutText.contains("fi-file-diagnostics"))
    #expect(
      withText.contains(
        "Content-Disposition: form-data; name=\"fi-file-diagnostics\"; filename=\"hs-reconnect-diagnostics.txt\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHS Reconnect diagnostics\n\r\n"
      )
    )
    #expect(withText.hasSuffix("--B--\r\n"))

    let note = BugReportMultipartBody(
      content: content, imageJPEGs: [], diagnosticsNote: "left out", boundary: "B"
    )
    let noteText = String(decoding: note.data, as: UTF8.self)
    #expect(noteText.contains("name=\"fi-text-diagnostics\"\r\n\r\nleft out\r\n"))
    #expect(!noteText.contains("fi-file-diagnostics"))
  }
}
