public enum ReconnectSetupAction: Equatable, Sendable {
  case none
  case openSystemExtensionSettings
  case retrySystemExtensionApproval
  case retryProxyConfiguration
  case retryProxySetup
}

public enum ReconnectSetupPolicy {
  public static func action(
    extensionInstalled: Bool,
    extensionEnabled: Bool,
    extensionAwaitingApproval: Bool,
    systemExtensionRetryRequired: Bool,
    proxyConfigurationPermissionDenied: Bool,
    proxyPreparationRetryRequired: Bool
  ) -> ReconnectSetupAction {
    guard extensionEnabled else {
      if systemExtensionRetryRequired,
        !extensionInstalled,
        !extensionAwaitingApproval
      {
        return .retrySystemExtensionApproval
      }
      return .openSystemExtensionSettings
    }

    if proxyConfigurationPermissionDenied {
      return .retryProxyConfiguration
    }
    if proxyPreparationRetryRequired {
      return .retryProxySetup
    }
    return .none
  }

  public static func shouldPrepareProxyAutomatically(
    extensionEnabled: Bool,
    proxyReady: Bool,
    action: ReconnectSetupAction
  ) -> Bool {
    extensionEnabled && !proxyReady && action == .none
  }
}
