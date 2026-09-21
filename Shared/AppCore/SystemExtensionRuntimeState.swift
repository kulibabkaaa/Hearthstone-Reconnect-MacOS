import Foundation

public struct SystemExtensionPropertyState: Equatable, Sendable {
  public let isEnabled: Bool
  public let isAwaitingUserApproval: Bool
  public let isUninstalling: Bool

  public init(
    isEnabled: Bool,
    isAwaitingUserApproval: Bool,
    isUninstalling: Bool
  ) {
    self.isEnabled = isEnabled
    self.isAwaitingUserApproval = isAwaitingUserApproval
    self.isUninstalling = isUninstalling
  }
}

public struct SystemExtensionRuntimeState: Equatable, Sendable {
  public let isInstalled: Bool
  public let isEnabled: Bool
  public let isAwaitingUserApproval: Bool
  public let hasPendingUninstall: Bool

  public var isUnavailable: Bool {
    !isInstalled && !isAwaitingUserApproval
  }

  public func allowsReconnect(
    proxyConnected: Bool,
    isUninstalling: Bool
  ) -> Bool {
    isEnabled && proxyConnected && !isUninstalling
  }

  public static func resolve(
    _ properties: [SystemExtensionPropertyState]
  ) -> SystemExtensionRuntimeState {
    let current = properties.filter { !$0.isUninstalling }
    return SystemExtensionRuntimeState(
      isInstalled: !current.isEmpty,
      isEnabled: current.contains { $0.isEnabled },
      isAwaitingUserApproval: current.contains {
        $0.isAwaitingUserApproval
      },
      hasPendingUninstall: properties.contains {
        $0.isUninstalling
      }
    )
  }
}
