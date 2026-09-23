import Carbon
import Foundation

enum AppConfiguration {
  static let appName = AppIdentity.appName
  static let bundleIdentifier =
    AppIdentity.bundleIdentifier
  static let extensionBundleIdentifier =
    AppIdentity.extensionBundleIdentifier
  static let watcherBundleIdentifier =
    AppIdentity.watcherBundleIdentifier
  static let defaultShortcutKeyCode = UInt32(kVK_ANSI_W)
  static let defaultShortcutDisplay = "Cmd+Shift+W"
  static let defaultLobbyShortcutKeyCode = UInt32(kVK_ANSI_L)
  static let defaultLobbyShortcutDisplay = "Cmd+Shift+L"
  static let openWithHearthstoneByDefault = true
  static let showInDockByDefault = true
  static let supportEmail = "hsreconnect@gmail.com"
}

enum DefaultsKey {
  static let keyCode = "hotkey.keyCode"
  static let modifiers = "hotkey.modifiers"
  static let hotkeyDisplay = "hotkey.display"
  static let openWithHearthstone =
    "openWithHearthstone"
  static let showInDock = "appearance.showInDock"
  static let didConfigureDefaultLoginItem =
    "loginItem.didConfigureDefault"
  static let hasSeenSystemExtensionApprovalPrompt =
    "systemExtension.hasSeenApprovalPrompt"
  static let systemExtensionApprovalWasDenied =
    "systemExtension.approvalWasDenied"
  static let proxyConfigurationPermissionWasDenied =
    "proxyConfiguration.permissionWasDenied"
  static let lastReconnectAt = "reconnect.lastAt"
  static let lobbyEnabled = "lobby.enabled"
  static let lobbyAccessVerified = "lobby.accessVerified"
  static let lobbyOpacity = "lobby.opacity"
  static let lobbyShortcutKeyCode = "lobby.shortcut.keyCode"
  static let lobbyShortcutModifiers = "lobby.shortcut.modifiers"
  static let lobbyShortcutDisplay = "lobby.shortcut.display"
  static let lobbyOriginX = "lobby.layout.originX"
  static let lobbyOriginY = "lobby.layout.originY"
  static let lobbyScale = "lobby.layout.scale"
  static let lobbyResumeCapture = "lobby.resume.capture"
}

func defaultCarbonModifiers() -> UInt32 {
  UInt32(cmdKey) | UInt32(shiftKey)
}
