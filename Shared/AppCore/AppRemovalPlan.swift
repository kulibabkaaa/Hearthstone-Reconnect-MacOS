import Foundation

public enum AppIdentity {
  public static let appName = "HS Reconnect"
  public static let bundleIdentifier =
    "io.github.kulibabkaaa.HSReconnect"
  public static let extensionBundleIdentifier =
    "io.github.kulibabkaaa.HSReconnect.ProxyExtension"
  public static let watcherBundleIdentifier =
    "io.github.kulibabkaaa.HSReconnect.Watcher"
  public static let packageReceiptIdentifier =
    "io.github.kulibabkaaa.HSReconnect.installer"
  public static let legacyPackageReceiptIdentifier =
    "io.github.kulibabkaaa.HSReconnect.pkg"
  public static let applicationGroupIdentifier =
    "D8KUYWS8JN.io.github.kulibabkaaa.HSReconnect"
}

public struct AppRemovalPlan: Sendable {
  public let installedApplicationURL: URL
  public let packageReceiptIdentifier: String
  public let legacyPackageReceiptIdentifiers: [String]
  public let desktopShortcutURL: URL
  public let userDataURLs: [URL]

  public init(homeDirectory: URL) {
    self.init(
      homeDirectory: homeDirectory,
      installedApplicationURL: URL(
        fileURLWithPath: "/Applications/HS Reconnect.app"
      ),
      packageReceiptIdentifier:
        AppIdentity.packageReceiptIdentifier,
      legacyPackageReceiptIdentifiers: [
        AppIdentity.legacyPackageReceiptIdentifier
      ]
    )
  }

  init(
    homeDirectory: URL,
    installedApplicationURL: URL,
    packageReceiptIdentifier: String,
    legacyPackageReceiptIdentifiers: [String] = []
  ) {
    self.installedApplicationURL = installedApplicationURL
    self.packageReceiptIdentifier = packageReceiptIdentifier
    self.legacyPackageReceiptIdentifiers =
      legacyPackageReceiptIdentifiers
    desktopShortcutURL =
      homeDirectory
      .appendingPathComponent("Desktop", isDirectory: true)
      .appendingPathComponent(
        "HS Reconnect.app",
        isDirectory: false
      )

    let library = homeDirectory.appendingPathComponent(
      "Library",
      isDirectory: true
    )
    userDataURLs = [
      library
        .appendingPathComponent("Preferences", isDirectory: true)
        .appendingPathComponent(
          "\(AppIdentity.bundleIdentifier).plist"
        ),
      library
        .appendingPathComponent("Preferences", isDirectory: true)
        .appendingPathComponent(
          "\(AppIdentity.watcherBundleIdentifier).plist"
        ),
      library
        .appendingPathComponent("Caches", isDirectory: true)
        .appendingPathComponent(
          AppIdentity.bundleIdentifier,
          isDirectory: true
        ),
      library
        .appendingPathComponent(
          "Application Support",
          isDirectory: true
        )
        .appendingPathComponent(
          AppIdentity.appName,
          isDirectory: true
        ),
      library
        .appendingPathComponent(
          "Containers",
          isDirectory: true
        )
        .appendingPathComponent(
          AppIdentity.bundleIdentifier,
          isDirectory: true
        ),
      library
        .appendingPathComponent(
          "Containers",
          isDirectory: true
        )
        .appendingPathComponent(
          AppIdentity.extensionBundleIdentifier,
          isDirectory: true
        ),
      library
        .appendingPathComponent(
          "Group Containers",
          isDirectory: true
        )
        .appendingPathComponent(
          AppIdentity.applicationGroupIdentifier,
          isDirectory: true
        ),
    ]
  }

  public static func ownsProxyConfiguration(
    providerBundleIdentifier: String?
  ) -> Bool {
    providerBundleIdentifier
      == AppIdentity.extensionBundleIdentifier
  }

  public func ownsDesktopShortcut(
    destination: URL
  ) -> Bool {
    destination.standardizedFileURL
      == installedApplicationURL.standardizedFileURL
  }

  public func privilegedRemovalCommand() -> String {
    cleanupCommand
  }

  public func privilegedRemovalAppleScript() -> String {
    let command = privilegedRemovalCommand()
    return
      "do shell script \(Self.appleScriptQuote(command))"
      + " with administrator privileges"
  }

  public func removeUserData(
    using fileManager: FileManager
  ) {
    for userDataURL in userDataURLs {
      try? fileManager.removeItem(at: userDataURL)
    }
  }

  private var cleanupCommand: String {
    let desktopShortcut = Self.shellQuote(
      desktopShortcutURL.path
    )
    let installedApplication = Self.shellQuote(
      installedApplicationURL.path
    )
    let desktopShortcutCommand =
      "if [ -L \(desktopShortcut) ]"
      + " && [ \"$(/usr/bin/readlink \(desktopShortcut))\""
      + " = \(installedApplication) ];"
      + " then /bin/unlink \(desktopShortcut)"
      + " >/dev/null 2>&1 || true; fi"
    let userDataCommands = userDataURLs.map {
      "/bin/rm -rf -- \(Self.shellQuote($0.path))"
        + " >/dev/null 2>&1 || true"
    }
    let receiptCommands =
      ([packageReceiptIdentifier] + legacyPackageReceiptIdentifiers)
      .map {
        "/usr/sbin/pkgutil --forget "
          + Self.shellQuote($0)
          + " >/dev/null 2>&1 || true"
      }
    return
      ([
        "set -e",
        desktopShortcutCommand,
      ] + receiptCommands + [
        "/bin/rm -rf -- "
          + installedApplication,
      ] + userDataCommands).joined(separator: "; ")
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private static func appleScriptQuote(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
  }
}
