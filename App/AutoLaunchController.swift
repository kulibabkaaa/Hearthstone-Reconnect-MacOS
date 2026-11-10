import AppKit
import OSLog
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
  private let logger = Logger(
    subsystem: AppConfiguration.bundleIdentifier,
    category: "LoginItem"
  )
  private var repairPolicy = LoginItemRepairPolicy()
  private var healthCheckGeneration = 0
  private var isReregistrationPending = false

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
    cancelHealthChecks()
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
        startHealthChecks()
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

  /// macOS can report the login item as enabled while launchd cannot start
  /// the helper (see `LoginItemRepairPolicy`). Check that the helper is really
  /// running and register it again when it is not.
  func startHealthChecks() {
    cancelHealthChecks()
    repairPolicy = LoginItemRepairPolicy()
    scheduleHealthCheck(
      after: LoginItemRepairPolicy.firstCheckDelay
    )
  }

  /// A repair switches the login item off for a moment. Never quit in that
  /// gap, or the option would stay off.
  func finishPendingRepair() {
    guard isReregistrationPending else {
      return
    }
    cancelHealthChecks()
    registerForRepair()
  }

  private func cancelHealthChecks() {
    healthCheckGeneration += 1
    isReregistrationPending = false
  }

  private func scheduleHealthCheck(after delay: TimeInterval) {
    let generation = healthCheckGeneration
    DispatchQueue.main.asyncAfter(
      deadline: .now() + delay
    ) { [weak self] in
      guard
        let self,
        generation == self.healthCheckGeneration
      else {
        return
      }
      self.runHealthCheck()
    }
  }

  private func runHealthCheck() {
    let decision = repairPolicy.evaluate(
      registration: registration,
      isHelperRunning: isWatcherRunning
    )
    switch decision {
    case .healthy, .notApplicable:
      break
    case .gaveUp:
      logger.error(
        "The Open with Hearthstone helper still isn't running after \(LoginItemRepairPolicy.maximumRepairs) repairs."
      )
    case .reregister:
      logger.notice(
        "The Open with Hearthstone helper isn't running. Registering it again (repair \(self.repairPolicy.repairsStarted))."
      )
      reregister()
    }
  }

  private func reregister() {
    if service.status != .notRegistered
      && service.status != .notFound
    {
      do {
        try service.unregister()
      } catch {
        logger.error(
          "Couldn't unregister the helper for repair: \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    isReregistrationPending = true
    let generation = healthCheckGeneration
    DispatchQueue.main.asyncAfter(
      deadline: .now() + LoginItemRepairPolicy.reregisterPause
    ) { [weak self] in
      guard
        let self,
        generation == self.healthCheckGeneration
      else {
        return
      }
      self.isReregistrationPending = false
      self.registerForRepair()
      self.scheduleHealthCheck(
        after: LoginItemRepairPolicy.recheckDelay
      )
    }
  }

  private func registerForRepair() {
    do {
      try service.register()
    } catch {
      logger.error(
        "Couldn't register the helper again: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private var registration: LoginItemRegistration {
    switch service.status {
    case .enabled:
      return .enabled
    case .requiresApproval:
      return .requiresApproval
    case .notRegistered:
      return .notRegistered
    case .notFound:
      return .notFound
    @unknown default:
      return .notFound
    }
  }

  private var isWatcherRunning: Bool {
    !NSRunningApplication.runningApplications(
      withBundleIdentifier:
        AppConfiguration.watcherBundleIdentifier
    ).isEmpty
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
