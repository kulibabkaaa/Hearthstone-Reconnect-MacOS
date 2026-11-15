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
      let directory = runningDirectory ?? newestLogDirectory(in: defaultLogsRoot)
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
        gameNetLog: directory.flatMap { readTail(of: $0.appendingPathComponent("GameNetLogger.log")) },
        hearthstoneLog: directory.flatMap { readTail(of: $0.appendingPathComponent("Hearthstone.log")) },
        battleNetLog: directory.flatMap { readTail(of: $0.appendingPathComponent("BattleNet.log")) },
        appLogEntries: appLogEntries(),
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

  private static func newestLogDirectory(in root: URL) -> URL? {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
    guard
      let candidates = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }
    let folders = candidates.compactMap { url -> (name: String, modified: Date)? in
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else {
        return nil
      }
      return (url.lastPathComponent, values.contentModificationDate ?? .distantPast)
    }
    return BugReportDiagnostics.newestLogFolder(among: folders).map {
      root.appendingPathComponent($0, isDirectory: true)
    }
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

  /// HS Reconnect's own log lines for this run. macOS only lets an app read its own process's log.
  private static func appLogEntries() -> [BugReportAppLogEntry] {
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
