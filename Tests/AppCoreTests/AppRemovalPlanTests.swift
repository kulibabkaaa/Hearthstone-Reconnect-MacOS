import AppKit
import Foundation
import Testing

@testable import AppCore

@Suite("App removal plan")
struct AppRemovalPlanTests {
  private let home = URL(fileURLWithPath: "/Users/Test Person")

  @Test("removes only the installed app and exact package receipt")
  func installedArtifactsAreExact() {
    let plan = AppRemovalPlan(homeDirectory: home)

    #expect(
      plan.installedApplicationURL.path
        == "/Applications/HS Reconnect.app"
    )
    #expect(
      plan.packageReceiptIdentifier
        == "io.github.kulibabkaaa.HSReconnect.installer"
    )
    #expect(
      plan.legacyPackageReceiptIdentifiers
        == ["io.github.kulibabkaaa.HSReconnect.pkg"]
    )
  }

  @Test("owns only this app's transparent proxy")
  func proxyOwnershipIsExact() {
    #expect(
      AppRemovalPlan.ownsProxyConfiguration(
        providerBundleIdentifier:
          "io.github.kulibabkaaa.HSReconnect.ProxyExtension"
      )
    )
    #expect(
      !AppRemovalPlan.ownsProxyConfiguration(
        providerBundleIdentifier:
          "io.github.kulibabkaaa.HSReconnect.OtherExtension"
      )
    )
    #expect(
      !AppRemovalPlan.ownsProxyConfiguration(
        providerBundleIdentifier: nil
      )
    )
  }

  @Test("removes only the Desktop symlink targeting the installed app")
  func desktopShortcutOwnershipIsExact() {
    let plan = AppRemovalPlan(homeDirectory: home)

    #expect(
      plan.desktopShortcutURL.path
        == "/Users/Test Person/Desktop/HS Reconnect.app"
    )
    #expect(
      plan.ownsDesktopShortcut(
        destination:
          URL(fileURLWithPath: "/Applications/HS Reconnect.app")
      )
    )
    #expect(
      !plan.ownsDesktopShortcut(
        destination:
          URL(fileURLWithPath: "/Applications/Another App.app")
      )
    )
  }

  @Test("user data paths stay inside the current user's Library")
  func userDataIsScoped() {
    let plan = AppRemovalPlan(homeDirectory: home)
    let libraryPrefix = "/Users/Test Person/Library/"

    #expect(!plan.userDataURLs.isEmpty)
    #expect(
      plan.userDataURLs.allSatisfy {
        $0.path.hasPrefix(libraryPrefix)
      }
    )
    #expect(
      plan.userDataURLs.contains {
        $0.path
          == "/Users/Test Person/Library/Group Containers/D8KUYWS8JN.io.github.kulibabkaaa.HSReconnect"
      }
    )
    #expect(
      plan.userDataURLs.contains {
        $0.path
          == "/Users/Test Person/Library/Containers/io.github.kulibabkaaa.HSReconnect.ProxyExtension"
      }
    )
  }

  @Test("privileged removal command quotes paths")
  func privilegedCommandIsSafelyQuoted() {
    let plan = AppRemovalPlan(homeDirectory: home)
    let command = plan.privilegedRemovalCommand()

    #expect(
      command.contains(
        "'/Applications/HS Reconnect.app'"
      )
    )
    #expect(
      command.contains(
        "'/Users/Test Person/Library/Group Containers/D8KUYWS8JN.io.github.kulibabkaaa.HSReconnect'"
      )
    )
    #expect(
      command.contains(
        "'io.github.kulibabkaaa.HSReconnect.installer'"
      )
    )
    #expect(
      command.contains(
        "'io.github.kulibabkaaa.HSReconnect.pkg'"
      )
    )
  }

  @Test("privileged removal is synchronous and ordered")
  func privilegedCommandIsSynchronousAndOrdered() {
    let plan = AppRemovalPlan(homeDirectory: home)
    let command = plan.privilegedRemovalCommand()
    let appRemoval =
      "/bin/rm -rf -- '/Applications/HS Reconnect.app'"
    let shortcutRemoval =
      "/bin/unlink '/Users/Test Person/Desktop/HS Reconnect.app'"

    #expect(!command.contains("/usr/bin/nohup"))
    #expect(!command.contains("/bin/kill -0"))
    #expect(command.contains(appRemoval))
    #expect(command.contains(shortcutRemoval))
    let appRange = command.range(of: appRemoval)
    let shortcutRange = command.range(of: shortcutRemoval)
    let currentReceipt = command.range(
      of: "--forget 'io.github.kulibabkaaa.HSReconnect.installer'"
    )
    let legacyReceipt = command.range(
      of: "--forget 'io.github.kulibabkaaa.HSReconnect.pkg'"
    )
    let preferencesRemoval = command.range(
      of: "'/Users/Test Person/Library/Preferences/io.github.kulibabkaaa.HSReconnect.plist'"
    )
    #expect(appRange != nil)
    #expect(shortcutRange != nil)
    #expect(currentReceipt != nil)
    #expect(legacyReceipt != nil)
    #expect(preferencesRemoval != nil)
    if let appRange, let shortcutRange,
       let currentReceipt, let legacyReceipt,
       let preferencesRemoval
    {
      #expect(shortcutRange.lowerBound < appRange.lowerBound)
      #expect(currentReceipt.lowerBound < appRange.lowerBound)
      #expect(legacyReceipt.lowerBound < appRange.lowerBound)
      #expect(appRange.lowerBound < preferencesRemoval.lowerBound)
    }
  }

  @Test("privileged command removes all planned test artifacts")
  func privilegedCommandRemovesPlannedArtifacts() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let testHome = root
      .appendingPathComponent("Users", isDirectory: true)
      .appendingPathComponent("Test Person", isDirectory: true)
    let testApplication = root
      .appendingPathComponent("Applications", isDirectory: true)
      .appendingPathComponent("HS Reconnect.app", isDirectory: true)
    let plan = AppRemovalPlan(
      homeDirectory: testHome,
      installedApplicationURL: testApplication,
      packageReceiptIdentifier:
        "io.github.kulibabkaaa.HSReconnect.tests.missing"
    )

    try fileManager.createDirectory(
      at: testApplication,
      withIntermediateDirectories: true
    )
    for userDataURL in plan.userDataURLs {
      if userDataURL.pathExtension == "plist" {
        try fileManager.createDirectory(
          at: userDataURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: userDataURL)
      } else {
        try fileManager.createDirectory(
          at: userDataURL,
          withIntermediateDirectories: true
        )
      }
    }
    try fileManager.createDirectory(
      at: plan.desktopShortcutURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.createSymbolicLink(
      at: plan.desktopShortcutURL,
      withDestinationURL: testApplication
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", plan.privilegedRemovalCommand()]
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(!fileManager.fileExists(atPath: testApplication.path))
    #expect(
      (try? fileManager.destinationOfSymbolicLink(
        atPath: plan.desktopShortcutURL.path
      )) == nil
    )
    #expect(
      plan.userDataURLs.allSatisfy {
        !fileManager.fileExists(atPath: $0.path)
      }
    )
  }

  @Test("user cleanup removes planned settings and caches")
  func userCleanupRemovesPlannedData() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let plan = AppRemovalPlan(
      homeDirectory: root,
      installedApplicationURL: root
        .appendingPathComponent("HS Reconnect.app"),
      packageReceiptIdentifier: "test.receipt"
    )

    for userDataURL in plan.userDataURLs {
      if userDataURL.pathExtension == "plist" {
        try fileManager.createDirectory(
          at: userDataURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: userDataURL)
      } else {
        try fileManager.createDirectory(
          at: userDataURL,
          withIntermediateDirectories: true
        )
      }
    }

    plan.removeUserData(using: fileManager)

    #expect(
      plan.userDataURLs.allSatisfy {
        !fileManager.fileExists(atPath: $0.path)
      }
    )
  }

  @Test("AppleScript wraps the fixed command without interpolation")
  func privilegedAppleScriptIsEscaped() {
    let plan = AppRemovalPlan(homeDirectory: home)
    let appleScript = plan.privilegedRemovalAppleScript()

    #expect(
      appleScript.hasPrefix(
        "do shell script \""
      )
    )
    #expect(
      appleScript.hasSuffix(
        "\" with administrator privileges"
      )
    )
  }

  @Test("privileged removal AppleScript compiles")
  func privilegedAppleScriptCompiles() {
    let plan = AppRemovalPlan(homeDirectory: home)
    let script = NSAppleScript(
      source: plan.privilegedRemovalAppleScript()
    )
    var error: NSDictionary?

    #expect(script?.compileAndReturnError(&error) == true)
    #expect(error == nil)
  }
}
