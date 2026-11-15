import Foundation

/// One line from HS Reconnect's own unified log, as read back with `OSLogStore`.
public struct BugReportAppLogEntry: Equatable, Sendable {
  public let date: Date
  public let category: String
  public let level: String
  public let message: String

  public init(date: Date, category: String, level: String, message: String) {
    self.date = date
    self.category = category
    self.level = level
    self.message = message
  }
}

/// Everything the app gathered for an optional diagnostics attachment, before any filtering.
/// The App target fills it with raw text; every choice about what leaves the Mac is made here.
public struct BugReportDiagnosticsInput: Sendable {
  public var appVersion: String
  public var buildNumber: String
  public var macOSVersion: String
  public var architecture: String
  public var extensionState: String
  public var proxyState: String
  public var trackerRecoveryEnabled: Bool
  public var hearthstoneRunning: Bool
  /// Name of the newest `Hearthstone_<date>` folder, or nil when none was found.
  public var logFolderName: String?
  /// Raw text (usually the tail) of each log file, or nil when the file was missing or unreadable.
  public var gameNetLog: String?
  public var hearthstoneLog: String?
  public var battleNetLog: String?
  public var appLogEntries: [BugReportAppLogEntry]
  public var generatedAt: Date

  public init(
    appVersion: String,
    buildNumber: String,
    macOSVersion: String,
    architecture: String,
    extensionState: String,
    proxyState: String,
    trackerRecoveryEnabled: Bool,
    hearthstoneRunning: Bool,
    logFolderName: String?,
    gameNetLog: String?,
    hearthstoneLog: String?,
    battleNetLog: String?,
    appLogEntries: [BugReportAppLogEntry],
    generatedAt: Date
  ) {
    self.appVersion = appVersion
    self.buildNumber = buildNumber
    self.macOSVersion = macOSVersion
    self.architecture = architecture
    self.extensionState = extensionState
    self.proxyState = proxyState
    self.trackerRecoveryEnabled = trackerRecoveryEnabled
    self.hearthstoneRunning = hearthstoneRunning
    self.logFolderName = logFolderName
    self.gameNetLog = gameNetLog
    self.hearthstoneLog = hearthstoneLog
    self.battleNetLog = battleNetLog
    self.appLogEntries = appLogEntries
    self.generatedAt = generatedAt
  }
}

/// Builds the text file attached to a bug report when the person turns on "Include diagnostic logs".
/// Allow-list only: a line is sent because it matches a known-useful pattern, never because it
/// merely failed a deny-list. Redaction then runs over every line as a second safety net.
public enum BugReportDiagnostics {
  public static let attachmentFilename = "hs-reconnect-diagnostics.txt"
  /// Images may use up to 24 MB of Forminit's 25 MB per submission; this stays well inside the rest.
  public static let maximumBytes = 200_000
  public static let maximumLineLength = 300
  public static let maximumGameLinesPerFile = 150
  public static let maximumAppLogLines = 200
  /// How far back the app's own log is read.
  public static let appLogLookback: TimeInterval = 3 * 60 * 60
  /// Only how much of each Hearthstone log file is read from its end.
  public static let maximumGameLogReadBytes = 8 * 1_024 * 1_024

  /// HS Reconnect log categories whose messages are useful and carry no player data.
  /// `LobbyCapture` (developer helper, logs helper output verbatim) is deliberately absent.
  public static let appLogCategories: Set<String> = [
    "ReconnectTarget",
    "TrackerRecovery",
    "LoginItem",
    "Analytics",
  ]

  /// Substrings that make a Hearthstone log line worth sending.
  public static let gameLogMarkers = [
    "GotoGameServe()",
    "DisconnectFromGameServer",
    "GameMgr.ChangeFindGameState",
  ]

  // MARK: - Building the attachment

  public static func render(_ input: BugReportDiagnosticsInput) -> String {
    var header = [
      "HS Reconnect diagnostics",
      "Generated: \(timestamp(input.generatedAt))",
      "App: \(input.appVersion) (\(input.buildNumber)), \(input.architecture)",
      "macOS: \(input.macOSVersion)",
      "Network extension: \(input.extensionState)",
      "Proxy: \(input.proxyState)",
      "Keep HSTracker working: \(input.trackerRecoveryEnabled ? "on" : "off")",
      "Hearthstone running: \(input.hearthstoneRunning ? "yes" : "no")",
      "Hearthstone log folder: \(input.logFolderName.map(safeFolderName) ?? "not found")",
    ]
    if let battleNetLog = input.battleNetLog {
      header.append("Battle.net region host: \(regionHost(inBattleNetLog: battleNetLog) ?? "not found")")
    } else {
      header.append("Battle.net region host: not found")
    }
    header = header.map(clip)

    var sections: [(title: String, lines: [String], missing: String)] = [
      (
        "GameNetLogger.log (matching lines only)",
        input.gameNetLog.map { gameLogLines(in: $0) } ?? [],
        input.gameNetLog == nil ? "file not found" : "no matching lines"
      ),
      (
        "Hearthstone.log (matching lines only)",
        input.hearthstoneLog.map { gameLogLines(in: $0) } ?? [],
        input.hearthstoneLog == nil ? "file not found" : "no matching lines"
      ),
      (
        "HS Reconnect log (this run, last 3 hours)",
        appLogLines(from: input.appLogEntries, now: input.generatedAt),
        "no entries"
      ),
    ]

    func assemble() -> String {
      var output = header
      for section in sections {
        output.append("")
        output.append("== \(section.title) ==")
        output.append(contentsOf: section.lines.isEmpty ? ["(\(section.missing))"] : section.lines)
      }
      return output.joined(separator: "\n") + "\n"
    }

    // Line caps already keep this far below the limit; this only guards against future changes.
    var text = assemble()
    while text.utf8.count > maximumBytes,
      let index = sections.indices.max(by: { sections[$0].lines.count < sections[$1].lines.count }),
      !sections[index].lines.isEmpty
    {
      sections[index].lines.removeFirst(max(1, sections[index].lines.count / 4))
      sections[index].missing = "trimmed to fit"
      text = assemble()
    }
    return text
  }

  /// The newest matching lines of one Hearthstone log, redacted, oldest first.
  public static func gameLogLines(in text: String) -> [String] {
    let matching = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
      .filter { line in gameLogMarkers.contains { line.contains($0) } }
      .suffix(maximumGameLinesPerFile)
    return matching.map { clean(String($0)) }
  }

  /// The app's own log lines from the allowed categories within the lookback window, redacted.
  public static func appLogLines(from entries: [BugReportAppLogEntry], now: Date) -> [String] {
    let earliest = now.addingTimeInterval(-appLogLookback)
    return entries
      .filter { appLogCategories.contains($0.category) && $0.date >= earliest && $0.date <= now }
      .sorted { $0.date < $1.date }
      .suffix(maximumAppLogLines)
      .map { entry in
        let message = entry.message.replacingOccurrences(of: "\n", with: " ")
        return clean("\(timestamp(entry.date)) [\(entry.category)] \(entry.level): \(message)")
      }
  }

  /// Only the Battle.net region host name (for example `eu.actual.battle.net`), nothing else from that log.
  public static func regionHost(inBattleNetLog text: String) -> String? {
    guard
      let range = text.range(
        of: "\\b(us|eu|kr|cn|tw|sg|apac|test)\\.actual\\.battle\\.net\\b",
        options: [.regularExpression, .backwards]
      )
    else {
      return nil
    }
    return String(text[range])
  }

  // MARK: - Redaction

  /// Blanks values that identify a game, a person or a Mac, wherever they appear in a line.
  public static func redact(_ line: String) -> String {
    var result = line
    for (pattern, replacement) in redactions {
      result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    return result
  }

  private static let redactions: [(String, String)] = [
    // Game, client and spectator keys in `GotoGameServe() - address=` lines.
    ("\\b(game|client|spectateKey)=[^ ,]*", "$1=x"),
    // Account and player identifiers in `Key=value`, `Key=[hi=… lo=…]` or `key: value` form.
    (
      "(?i)\\b(AccountId|GameAccountId|playerId|BattleTag|gameUuid|uuid|token)(\\s*[=:]\\s*)(\\[[^\\]]{0,200}\\]|[^ ,\\]]*)",
      "$1$2x"
    ),
    // Loose Blizzard account id halves.
    ("\\b(hi|lo)=[0-9]+", "$1=x"),
    // BattleTags (Name#1234) and email addresses. Quantifiers are bounded so long lines stay fast.
    ("[\\p{L}\\p{N}_]{2,24}#[0-9]{3,6}", "<battletag>"),
    ("[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(\\.[A-Za-z0-9-]{1,63}){1,8}", "<email>"),
    // Home folder names in file paths.
    ("/Users/[^/\\s]+", "/Users/~"),
  ]

  // MARK: - Helpers

  /// Shortens a raw line before redaction (bounds regex work), redacts, then applies the final length.
  private static func clean(_ line: String) -> String {
    clip(redact(String(line.prefix(maximumLineLength * 3))))
  }

  private static func clip(_ line: String) -> String {
    guard line.count > maximumLineLength else { return line }
    return String(line.prefix(maximumLineLength)) + "…"
  }

  /// `Hearthstone_<date>` folders hold only a date; anything else is reported generically.
  private static func safeFolderName(_ name: String) -> String {
    name.range(of: "^Hearthstone_[0-9_]+$", options: .regularExpression) != nil ? name : "found"
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  // MARK: - Finding the newest log folder

  /// Picks the newest `Hearthstone_<date>` folder from (name, modification date) pairs.
  public static func newestLogFolder(among folders: [(name: String, modified: Date)]) -> String? {
    folders
      .filter { $0.name.hasPrefix("Hearthstone_") }
      .max { $0.modified < $1.modified }?
      .name
  }

  public static func byteCountDescription(_ text: String) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
  }
}
