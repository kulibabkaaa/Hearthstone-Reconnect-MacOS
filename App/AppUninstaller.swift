import AppKit

enum AppUninstallerError: Error {
  case notInstalledInApplications
  case removalFailedAfterExtensionDeactivation

  var failureStage: AppUninstallFailureStage {
    switch self {
    case .notInstalledInApplications:
      .extensionStillInstalled
    case .removalFailedAfterExtensionDeactivation:
      .extensionDeactivated
    }
  }
}

final class AppUninstaller {
  private let autoLaunchController: AutoLaunchController
  private let proxyController: TransparentProxyController
  private let systemExtensionController: SystemExtensionController
  private let fileManager: FileManager
  private let plan: AppRemovalPlan

  init(
    autoLaunchController: AutoLaunchController,
    proxyController: TransparentProxyController,
    systemExtensionController: SystemExtensionController,
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default
      .homeDirectoryForCurrentUser
  ) {
    self.autoLaunchController = autoLaunchController
    self.proxyController = proxyController
    self.systemExtensionController = systemExtensionController
    self.fileManager = fileManager
    plan = AppRemovalPlan(homeDirectory: homeDirectory)
  }

  func uninstall(
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard
      Bundle.main.bundleURL.standardizedFileURL
        == plan.installedApplicationURL.standardizedFileURL
    else {
      completion(
        .failure(AppUninstallerError.notInstalledInApplications)
      )
      return
    }

    removeOwnedDesktopShortcut { [weak self] in
      self?.continueUninstall(completion: completion)
    }
  }

  private func continueUninstall(
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    switch autoLaunchController.setEnabled(false) {
    case .failure(let error):
      completion(.failure(error))
    case .success:
      proxyController.removeConfiguration {
        [weak self] result in
        guard let self else { return }
        switch result {
        case .failure(let error):
          completion(.failure(error))
        case .success:
          self.deactivateExtension(completion: completion)
        }
      }
    }
  }

  private func deactivateExtension(
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    systemExtensionController.deactivate {
      [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success:
        self.removeFiles(completion: completion)
      }
    }
  }

  private func removeFiles(
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    var errorInfo: NSDictionary?
    let appleScript = plan.privilegedRemovalAppleScript()
    guard
      NSAppleScript(source: appleScript)?
        .executeAndReturnError(&errorInfo) != nil
    else {
      if let errorInfo {
        NSLog(
          "Privileged uninstall cleanup failed: %@",
          errorInfo
        )
      }
      completion(
        .failure(
          AppUninstallerError
            .removalFailedAfterExtensionDeactivation
        )
      )
      return
    }

    UserDefaults.standard.removePersistentDomain(
      forName: AppIdentity.bundleIdentifier
    )
    UserDefaults.standard.synchronize()
    plan.removeUserData(using: fileManager)
    completion(.success(()))
  }

  private func removeOwnedDesktopShortcut(
    completion: @escaping () -> Void
  ) {
    let shortcutPath = plan.desktopShortcutURL.path
    guard
      let destination =
        try? fileManager
        .destinationOfSymbolicLink(atPath: shortcutPath)
    else {
      completion()
      return
    }

    let destinationURL: URL
    if destination.hasPrefix("/") {
      destinationURL = URL(fileURLWithPath: destination)
    } else {
      destinationURL = plan.desktopShortcutURL
        .deletingLastPathComponent()
        .appendingPathComponent(destination)
    }

    guard plan.ownsDesktopShortcut(destination: destinationURL)
    else {
      completion()
      return
    }
    let shortcutURL = plan.desktopShortcutURL
    NSWorkspace.shared.recycle(
      [shortcutURL]
    ) { [weak self] _, error in
      if error != nil {
        try? self?.fileManager.removeItem(
          at: shortcutURL
        )
      }
      DispatchQueue.main.async {
        completion()
      }
    }
  }
}
