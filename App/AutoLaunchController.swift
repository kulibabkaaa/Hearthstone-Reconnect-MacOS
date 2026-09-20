import AppKit
import ServiceManagement

enum AutoLaunchError: Error {
  case approvalRequired
  case unavailable
}

final class AutoLaunchController {
  private let service = SMAppService.loginItem(
    identifier: AppConfiguration.watcherBundleIdentifier
  )
  private let defaults = UserDefaults.standard

  func synchronizeStoredState() {
    defaults.set(
      service.status == .enabled,
      forKey: DefaultsKey.openWithHearthstone
    )
  }

  func configureDefaultIfNeeded() -> Result<Void, Error> {
    guard
      !defaults.bool(
        forKey: DefaultsKey.didConfigureDefaultLoginItem
      )
    else {
      return .success(())
    }

    return setEnabled(
      AppConfiguration.openWithHearthstoneByDefault
    )
  }

  func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
    do {
      if enabled {
        if service.status == .notRegistered
          || service.status == .notFound
        {
          try service.register()
        }
        if service.status == .requiresApproval {
          defaults.set(
            false,
            forKey: DefaultsKey.openWithHearthstone
          )
          return .failure(AutoLaunchError.approvalRequired)
        }
        guard service.status == .enabled else {
          defaults.set(
            false,
            forKey: DefaultsKey.openWithHearthstone
          )
          return .failure(AutoLaunchError.unavailable)
        }
        defaults.set(
          true,
          forKey: DefaultsKey.openWithHearthstone
        )
      } else {
        if service.status != .notRegistered
          && service.status != .notFound
        {
          try service.unregister()
        }
        defaults.set(
          false,
          forKey: DefaultsKey.openWithHearthstone
        )
        stopRunningWatcher()
      }
      defaults.set(
        true,
        forKey: DefaultsKey.didConfigureDefaultLoginItem
      )
      return .success(())
    } catch {
      defaults.set(
        false,
        forKey: DefaultsKey.openWithHearthstone
      )
      return .failure(error)
    }
  }

  private func stopRunningWatcher() {
    for application in NSRunningApplication.runningApplications(
      withBundleIdentifier:
        AppConfiguration.watcherBundleIdentifier
    ) {
      if !application.terminate() {
        _ = application.forceTerminate()
      }
    }
  }
}
