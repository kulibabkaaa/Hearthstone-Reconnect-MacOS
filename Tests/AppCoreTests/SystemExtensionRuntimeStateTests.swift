import Testing

@testable import AppCore

@Suite("System extension runtime state")
struct SystemExtensionRuntimeStateTests {
  @Test("disabled current extension stays disabled beside stale uninstall")
  func disabledCurrentExtensionWinsOverStaleUninstall() {
    let state = SystemExtensionRuntimeState.resolve([
      property(enabled: false),
      property(enabled: false, uninstalling: true),
    ])

    #expect(!state.isUnavailable)
    #expect(state.isInstalled)
    #expect(!state.isEnabled)
    #expect(state.hasPendingUninstall)
  }

  @Test("enabled current extension stays enabled beside stale uninstall")
  func enabledCurrentExtensionWinsOverStaleUninstall() {
    let state = SystemExtensionRuntimeState.resolve([
      property(enabled: true),
      property(enabled: false, uninstalling: true),
    ])

    #expect(!state.isUnavailable)
    #expect(state.isInstalled)
    #expect(state.isEnabled)
    #expect(state.hasPendingUninstall)
  }

  @Test("uninstalling entry alone is not treated as installed")
  func uninstallingEntryIsNotCurrent() {
    let state = SystemExtensionRuntimeState.resolve([
      property(enabled: false, uninstalling: true)
    ])

    #expect(state.isUnavailable)
    #expect(!state.isInstalled)
    #expect(!state.isEnabled)
    #expect(state.hasPendingUninstall)
  }

  @Test("approval state is preserved for the current extension")
  func approvalStateIsPreserved() {
    let state = SystemExtensionRuntimeState.resolve([
      property(enabled: false, awaitingApproval: true)
    ])

    #expect(!state.isUnavailable)
    #expect(state.isInstalled)
    #expect(!state.isEnabled)
    #expect(state.isAwaitingUserApproval)
  }

  @Test("reconnect requires enabled extension and connected proxy")
  func reconnectReadinessRequiresBothLiveStates() {
    let enabled = SystemExtensionRuntimeState.resolve([
      property(enabled: true)
    ])
    let disabled = SystemExtensionRuntimeState.resolve([
      property(enabled: false)
    ])

    #expect(
      enabled.allowsReconnect(
        proxyConnected: true,
        isUninstalling: false
      )
    )
    #expect(
      !enabled.allowsReconnect(
        proxyConnected: false,
        isUninstalling: false
      )
    )
    #expect(
      !disabled.allowsReconnect(
        proxyConnected: true,
        isUninstalling: false
      )
    )
    #expect(
      !enabled.allowsReconnect(
        proxyConnected: true,
        isUninstalling: true
      )
    )
  }

  private func property(
    enabled: Bool,
    awaitingApproval: Bool = false,
    uninstalling: Bool = false
  ) -> SystemExtensionPropertyState {
    SystemExtensionPropertyState(
      isEnabled: enabled,
      isAwaitingUserApproval: awaitingApproval,
      isUninstalling: uninstalling
    )
  }
}
