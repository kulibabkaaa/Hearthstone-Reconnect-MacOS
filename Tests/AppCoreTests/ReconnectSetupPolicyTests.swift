import Testing

@testable import AppCore

@Suite("Reconnect setup policy")
struct ReconnectSetupPolicyTests {
  @Test("cancelled extension approval waits for a user retry")
  func cancelledExtensionApprovalRequiresExplicitRetry() {
    let action = ReconnectSetupPolicy.action(
      extensionInstalled: false,
      extensionEnabled: false,
      extensionAwaitingApproval: false,
      systemExtensionRetryRequired: true,
      proxyConfigurationPermissionDenied: false,
      proxyPreparationRetryRequired: false
    )

    #expect(action == .retrySystemExtensionApproval)
    #expect(
      !ReconnectSetupPolicy.shouldPrepareProxyAutomatically(
        extensionEnabled: false,
        proxyReady: false,
        action: action
      )
    )
  }

  @Test("denied proxy permission waits for a user retry")
  func deniedProxyPermissionRequiresExplicitRetry() {
    let action = ReconnectSetupPolicy.action(
      extensionInstalled: true,
      extensionEnabled: true,
      extensionAwaitingApproval: false,
      systemExtensionRetryRequired: false,
      proxyConfigurationPermissionDenied: true,
      proxyPreparationRetryRequired: true
    )

    #expect(action == .retryProxyConfiguration)
    #expect(
      !ReconnectSetupPolicy.shouldPrepareProxyAutomatically(
        extensionEnabled: true,
        proxyReady: false,
        action: action
      )
    )
  }

  @Test("disabled installed extension opens System Settings")
  func disabledExtensionOpensSettings() {
    let action = ReconnectSetupPolicy.action(
      extensionInstalled: true,
      extensionEnabled: false,
      extensionAwaitingApproval: false,
      systemExtensionRetryRequired: false,
      proxyConfigurationPermissionDenied: false,
      proxyPreparationRetryRequired: false
    )

    #expect(action == .openSystemExtensionSettings)
  }

  @Test("healthy extension prepares the proxy automatically")
  func healthyExtensionPreparesAutomatically() {
    let action = ReconnectSetupPolicy.action(
      extensionInstalled: true,
      extensionEnabled: true,
      extensionAwaitingApproval: false,
      systemExtensionRetryRequired: false,
      proxyConfigurationPermissionDenied: false,
      proxyPreparationRetryRequired: false
    )

    #expect(action == .none)
    #expect(
      ReconnectSetupPolicy.shouldPrepareProxyAutomatically(
        extensionEnabled: true,
        proxyReady: false,
        action: action
      )
    )
  }
}
