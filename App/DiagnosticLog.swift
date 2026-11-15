import Foundation
import OSLog

/// HS Reconnect's log for lines a bug report may include. Each call goes to os_log (as before) and to a small
/// file in `~/Library/Logs/HS Reconnect/` that survives restarts. Messages are redacted first, so the file and
/// os_log hold the same cleaned text. Only `DiagnosticLogCategory` categories exist here by design.
enum DiagnosticLog {
  /// `~/Library/Logs` is where macOS expects app logs: Console.app lists it and people can find or delete it.
  static let store = DiagnosticLogStore(
    directory: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent(AppIdentity.appName, isDirectory: true)
  )

  static func notice(_ category: DiagnosticLogCategory, _ message: String) {
    let clean = DiagnosticLogFormat.clean(message)
    logger(for: category).notice("\(clean, privacy: .public)")
    store.append(category, .notice, clean)
  }

  static func error(_ category: DiagnosticLogCategory, _ message: String) {
    let clean = DiagnosticLogFormat.clean(message)
    logger(for: category).error("\(clean, privacy: .public)")
    store.append(category, .error, clean)
  }

  private static func logger(for category: DiagnosticLogCategory) -> Logger {
    Logger(subsystem: AppConfiguration.bundleIdentifier, category: category.rawValue)
  }
}
