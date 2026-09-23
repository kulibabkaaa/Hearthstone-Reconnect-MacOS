import AppKit
import Security

/// Validate the running code, not a user-editable application display name.
enum HearthstoneProcessTrust {
  static let bundleIdentifier = "unity.Blizzard Entertainment.Hearthstone"
  private static let requirementText = "identifier \"unity.Blizzard Entertainment.Hearthstone\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"G847MC6JZ5\""

  static func isTrusted(_ application: NSRunningApplication) -> Bool {
    guard !application.isTerminated,
          application.bundleIdentifier == bundleIdentifier,
          let bundleURL = application.bundleURL,
          let executableURL = application.executableURL,
          executableURL.resolvingSymlinksInPath() == bundleURL
            .appendingPathComponent("Contents/MacOS/Hearthstone").resolvingSymlinksInPath()
    else { return false }

    var code: SecCode?
    let attributes = [kSecGuestAttributePid: application.processIdentifier] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
          let requirement,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let staticCode else { return false }
    var runningPath: CFURL?
    guard SecCodeCopyPath(staticCode, [], &runningPath) == errSecSuccess,
          let runningPath else { return false }
    return (runningPath as URL).resolvingSymlinksInPath() == bundleURL.resolvingSymlinksInPath()
  }
}
