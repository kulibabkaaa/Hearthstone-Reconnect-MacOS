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
  /// Folder the `BattleNet.log` came from, which can be older than `logFolderName`.
  public var battleNetLogFolderName: String?
  /// Raw text (usually the tail) of each log file, or nil when the file was missing or unreadable.
  public var gameNetLog: String?
  public var hearthstoneLog: String?
  public var battleNetLog: String?
  /// The region from the newest older folder's `Hearthstone.log`, used when the current one has no login yet.
  public var olderFolderRegion: (region: String, folder: String)?
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
    battleNetLogFolderName: String? = nil,
    gameNetLog: String?,
    hearthstoneLog: String?,
    battleNetLog: String?,
    olderFolderRegion: (region: String, folder: String)? = nil,
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
    self.battleNetLogFolderName = battleNetLogFolderName
    self.gameNetLog = gameNetLog
    self.hearthstoneLog = hearthstoneLog
    self.battleNetLog = battleNetLog
    self.olderFolderRegion = olderFolderRegion
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
  /// No single category may fill the app-log section, so frequent lines (such as match presence) can't push the
  /// reconnect lines of the incident being reported out of it.
  public static let maximumAppLogLinesPerCategory = 80
  /// How far back the app's own log is read (the same span its log file keeps).
  public static let appLogLookback: TimeInterval = DiagnosticLogStore.retention
  /// Only how much of each Hearthstone log file is read from its end.
  public static let maximumGameLogReadBytes = 8 * 1_024 * 1_024

  /// HS Reconnect log categories whose messages are useful and carry no player data.
  /// `LobbyCapture` (developer helper, logs helper output verbatim) is deliberately absent.
  public static let appLogCategories = Set(DiagnosticLogCategory.allCases.map(\.rawValue))
  /// Region codes Hearthstone logs at login. Any other upper-case word is reported as `other`, never as itself.
  public static let knownRegions: Set<String> = ["US", "EU", "KR", "CN", "TW"]
  /// How many older Hearthstone log folders are searched for a `BattleNet.log` (or a login's region).
  public static let maximumBattleNetLogFolders = 5

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
    // Hearthstone.log names the region at every login, with or without `log.config` or lobby info; current
    // BattleNet.log files often name no host at all, so the host line is extra detail when it exists.
    if let region = input.hearthstoneLog.flatMap(region(inHearthstoneLog:)) {
      header.append("Battle.net region: \(region)")
    } else if let older = input.olderFolderRegion, let region = knownRegion(older.region) {
      header.append("Battle.net region: \(region) (from \(safeFolderName(older.folder)))")
    } else {
      header.append("Battle.net region: not found")
    }
    if let battleNetLog = input.battleNetLog, let host = regionHost(inBattleNetLog: battleNetLog) {
      let source = input.battleNetLogFolderName
        .flatMap { $0 == input.logFolderName ? nil : " (from \(safeFolderName($0)))" } ?? ""
      header.append("Battle.net region host: \(host)\(source)")
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
        "HS Reconnect log (last 3 days)",
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
    return matching.map { cleanLine(String($0)) }
  }

  /// The app's own log lines from the allowed categories within the lookback window, redacted.
  public static func appLogLines(from entries: [BugReportAppLogEntry], now: Date) -> [String] {
    let earliest = now.addingTimeInterval(-appLogLookback)
    return entries
      .filter { appLogCategories.contains($0.category) && $0.date >= earliest && $0.date <= now }
      .sorted { $0.date < $1.date }
      .reversed()
      .reduce(into: (kept: [BugReportAppLogEntry](), perCategory: [String: Int]())) { result, entry in
        let count = result.perCategory[entry.category, default: 0]
        guard count < maximumAppLogLinesPerCategory else { return }
        result.perCategory[entry.category] = count + 1
        result.kept.append(entry)
      }
      .kept
      .reversed()
      .suffix(maximumAppLogLines)
      .map { entry in
        let message = entry.message.replacingOccurrences(of: "\n", with: " ")
        return cleanLine("\(timestamp(entry.date)) [\(entry.category)] \(entry.level): \(message)")
      }
  }

  /// The region Hearthstone logged at its latest login (`I 22:20:48.1234567 Region: EU`), or nil. Only a short
  /// upper-case code is taken from the line, nothing else.
  public static func region(inHearthstoneLog text: String) -> String? {
    lastMatch(of: "(?m)^[A-Z] [0-9:.]+ Region: ([A-Z]{2,8})[ \\t]*$", in: text, group: 1).flatMap(knownRegion)
  }

  /// A known region code as itself, any other code as `other`.
  static func knownRegion(_ code: String) -> String? {
    guard !code.isEmpty else { return nil }
    return knownRegions.contains(code) ? code : "other"
  }

  /// Older folders to try for the region when the current `Hearthstone.log` has none: the newest first, never the
  /// current one, at most `maximumBattleNetLogFolders`.
  public static func olderRegionFolders(currentFolder: String?, among folders: [(name: String, modified: Date)])
    -> [String] {
    Array(folders
      .filter { $0.name.hasPrefix("Hearthstone_") && $0.name != currentFolder }
      .sorted { $0.modified > $1.modified }
      .map(\.name)
      .prefix(maximumBattleNetLogFolders))
  }

  /// Only the Battle.net region host name (for example `eu.actual.battle.net`), nothing else from that log.
  /// The newest one, when the log names several.
  public static func regionHost(inBattleNetLog text: String) -> String? {
    lastMatch(of: "\\b(us|eu|kr|cn|tw|sg|apac|test)\\.actual\\.battle\\.net\\b", in: text, group: 0)
  }

  /// The last match in `text`. `String.range(of:options: [.regularExpression, .backwards])` returns the first
  /// match, not the last, so the matches are walked instead.
  private static func lastMatch(of pattern: String, in text: String, group: Int) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let all = NSRange(text.startIndex..., in: text)
    guard let match = expression.matches(in: text, range: all).last,
          let range = Range(match.range(at: group), in: text) else { return nil }
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
    // Game, client and spectator keys in `GotoGameServe() - address=` lines, in any case and spacing.
    ("(?i)\\b(game|client|spectateKey)(\\s*=\\s*)[^ ,]*", "$1=x"),
    // Account and player identifiers in `Key=value`, `Key=[hi=… lo=…]` or `key: value` form.
    (
      "(?i)\\b(AccountId|GameAccountId|playerId|BattleTag|gameUuid|uuid|token)(\\s*[=:]\\s*)(\\[[^\\]]{0,200}\\]|[^ ,\\]]*)",
      "$1$2x"
    ),
    // Loose Blizzard account id halves.
    ("(?i)\\b(hi|lo)(\\s*[=:]\\s*)[0-9]+", "$1$2x"),
    // BattleTags (Name#1234) and email addresses. Quantifiers are bounded so long lines stay fast.
    ("[\\p{L}\\p{M}\\p{N}_]{2,40}#[0-9]{3,6}", "<battletag>"),
    ("[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(\\.[A-Za-z0-9-]{1,63}){1,8}", "<email>"),
    // Home folder names in file paths.
    // Home folder names in file paths (may contain spaces, so everything up to the next slash goes).
    ("/Users/[^/\\n]+", "/Users/~"),
  ]

  // MARK: - Helpers

  /// Shortens a raw line before redaction (bounds regex work), redacts, then applies the final length.
  public static func cleanLine(_ line: String) -> String {
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
    date.formatted(.iso8601)
  }

  // MARK: - Submission

  /// Whether a refused report should be resent once without the diagnostics file. Only client errors that
  /// point at the request's contents qualify: a timeout (408), a rate limit (429) or a server error (5xx) may
  /// have stored the first request already, and resending would create a duplicate.
  public static func shouldRetryWithoutAttachment(statusCode: Int) -> Bool {
    (400 ... 499).contains(statusCode) && statusCode != 408 && statusCode != 429
  }

  /// The log file's entries (earlier runs) plus this run's os_log entries, without the copies both hold.
  /// An entry counts as a copy when category, level and message match and the times are within 2 seconds.
  public static func mergedAppLogEntries(
    file: [BugReportAppLogEntry],
    currentRun: [BugReportAppLogEntry]
  ) -> [BugReportAppLogEntry] {
    var fileDates: [String: [Date]] = [:]
    for entry in file {
      fileDates[key(entry), default: []].append(entry.date)
    }
    let extra = currentRun.filter { entry in
      let normalized = BugReportAppLogEntry(
        date: entry.date,
        category: entry.category,
        level: entry.level,
        message: DiagnosticLogFormat.clean(entry.message)
      )
      return !(fileDates[key(normalized)] ?? []).contains { abs($0.timeIntervalSince(entry.date)) <= 2 }
    }
    return (file + extra).sorted { $0.date < $1.date }
  }

  private static func key(_ entry: BugReportAppLogEntry) -> String {
    // Compared on the first 200 characters, so a copy that was length-capped twice still matches.
    "\(entry.category)\t\(entry.level)\t\(entry.message.prefix(200))"
  }

  /// Folders to try for the Battle.net region, best first: the current folder when it has a `BattleNet.log`,
  /// then the newest other folders that have one.
  public static func battleNetLogCandidates(
    currentFolder: String?,
    among folders: [(name: String, modified: Date, hasBattleNetLog: Bool)]
  ) -> [String] {
    let withLog = folders
      .filter { $0.name.hasPrefix("Hearthstone_") && $0.hasBattleNetLog }
      .sorted { $0.modified > $1.modified }
      .map(\.name)
    let ordered = withLog.contains { $0 == currentFolder }
      ? [currentFolder!] + withLog.filter { $0 != currentFolder }
      : withLog
    return Array(ordered.prefix(maximumBattleNetLogFolders))
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
