import AppKit
import OSLog

/// App state for the diagnostics header, read on the main thread by `AppDelegate`.
struct BugReportStatusSnapshot: Sendable {
  let extensionState: String
  let proxyState: String
  let trackerRecoveryEnabled: Bool
}

/// Reads the raw material for the optional bug-report diagnostics file. It only reads; every decision about what
/// is kept and what is blanked lives in `BugReportDiagnostics` (AppCore), which is unit-tested.
enum BugReportDiagnosticsCollector {
  private static let defaultLogsRoot = URL(fileURLWithPath: "/Applications/Hearthstone/Logs", isDirectory: true)

  @MainActor
  static func collect(status: BugReportStatusSnapshot) async -> String {
    let bundle = Bundle.main
    let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    let runningDirectory = GameEndpointResolver().currentLogDirectory()
    let hearthstoneRunning = NSRunningApplication.runningApplications(
      withBundleIdentifier: ProxyConstants.hearthstoneSigningIdentifier
    ).contains { !$0.isTerminated }

    return await Task.detached(priority: .userInitiated) {
      let logsRoot = runningDirectory?.deletingLastPathComponent() ?? defaultLogsRoot
      let folders = logFolders(in: logsRoot)
      let directory = runningDirectory
        ?? BugReportDiagnostics.newestLogFolder(among: folders.map { ($0.name, $0.modified) }).map {
          logsRoot.appendingPathComponent($0, isDirectory: true)
        }
      let battleNet = battleNetLog(
        in: logsRoot,
        currentFolder: directory?.lastPathComponent,
        folders: folders
      )
      let input = BugReportDiagnosticsInput(
        appVersion: appVersion,
        buildNumber: buildNumber,
        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: architecture,
        extensionState: status.extensionState,
        proxyState: status.proxyState,
        trackerRecoveryEnabled: status.trackerRecoveryEnabled,
        hearthstoneRunning: hearthstoneRunning,
        logFolderName: directory?.lastPathComponent,
        battleNetLogFolderName: battleNet?.folder,
        gameNetLog: directory.flatMap { readTail(of: $0.appendingPathComponent("GameNetLogger.log")) },
        hearthstoneLog: directory.flatMap { readTail(of: $0.appendingPathComponent("Hearthstone.log")) },
        battleNetLog: battleNet?.text,
        appLogEntries: BugReportDiagnostics.mergedAppLogEntries(
          file: DiagnosticLog.store.entries(),
          currentRun: currentRunLogEntries()
        ),
        generatedAt: Date()
      )
      return BugReportDiagnostics.render(input)
    }.value
  }

  private static var architecture: String {
    #if arch(arm64)
      "arm64"
    #else
      "x86_64"
    #endif
  }

  private static func logFolders(in root: URL) -> [(name: String, modified: Date, hasBattleNetLog: Bool)] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
    guard
      let candidates = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    return candidates.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else {
        return nil
      }
      return (
        url.lastPathComponent,
        values.contentModificationDate ?? .distantPast,
        FileManager.default.fileExists(atPath: url.appendingPathComponent("BattleNet.log").path)
      )
    }
  }

  /// The first `BattleNet.log` (current folder first, then newer before older) that names a region host.
  private static func battleNetLog(
    in root: URL,
    currentFolder: String?,
    folders: [(name: String, modified: Date, hasBattleNetLog: Bool)]
  ) -> (folder: String, text: String)? {
    for name in BugReportDiagnostics.battleNetLogCandidates(currentFolder: currentFolder, among: folders) {
      let file = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("BattleNet.log")
      if let text = readTail(of: file), BugReportDiagnostics.regionHost(inBattleNetLog: text) != nil {
        return (name, text)
      }
    }
    return nil
  }

  /// The end of a log file, starting at a whole line.
  private static func readTail(of file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard let length = try? handle.seekToEnd() else { return nil }
    let limit = UInt64(BugReportDiagnostics.maximumGameLogReadBytes)
    let start = length > limit ? length - limit : 0
    guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else {
      return start == length ? "" : nil
    }
    let text = String(decoding: data, as: UTF8.self)
    guard start > 0, let firstBreak = text.firstIndex(of: "\n") else { return text }
    return String(text[text.index(after: firstBreak)...])
  }

  /// This run's os_log lines. macOS only lets an app read its own process's log; earlier runs come from the file.
  private static func currentRunLogEntries() -> [BugReportAppLogEntry] {
    guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
    let position = store.position(date: Date().addingTimeInterval(-BugReportDiagnostics.appLogLookback))
    let predicate = NSPredicate(
      format: "subsystem == %@ AND category IN %@",
      AppConfiguration.bundleIdentifier,
      Array(BugReportDiagnostics.appLogCategories)
    )
    guard let entries = try? store.getEntries(at: position, matching: predicate) else { return [] }
    return entries.compactMap { entry in
      guard let log = entry as? OSLogEntryLog else { return nil }
      return BugReportAppLogEntry(
        date: log.date,
        category: log.category,
        level: levelName(log.level),
        message: log.composedMessage
      )
    }
  }

  private static func levelName(_ level: OSLogEntryLog.Level) -> String {
    switch level {
    case .debug: "debug"
    case .info: "info"
    case .notice: "notice"
    case .error: "error"
    case .fault: "fault"
    default: "log"
    }
  }
}
