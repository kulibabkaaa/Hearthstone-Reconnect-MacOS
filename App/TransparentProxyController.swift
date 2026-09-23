import Foundation
import NetworkExtension

enum TransparentProxyControllerError: Error, Equatable {
  case configurationPermissionDenied
  case configurationMissing
  case sessionUnavailable
  case startTimedOut
  case responseMissing
  case responseInvalid
}

final class TransparentProxyController {
  var onConnectionStatusChanged: ((NEVPNStatus) -> Void)?

  var connectionStatus: NEVPNStatus {
    retainedManager?.connection.status ?? .invalid
  }

  private var retainedManager: NETransparentProxyManager?
  private var connectionStatusObserver: NSObjectProtocol?

  deinit {
    if let connectionStatusObserver {
      NotificationCenter.default.removeObserver(
        connectionStatusObserver
      )
    }
  }

  func hasEnabledConfiguration(
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    NETransparentProxyManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(error))
          return
        }
        let exists = (managers ?? []).contains { manager in
          manager.isEnabled
            && (manager.protocolConfiguration as? NETunnelProviderProtocol)?
              .providerBundleIdentifier
              == AppConfiguration.extensionBundleIdentifier
        }
        completion(.success(exists))
      }
    }
  }

  func removeConfiguration(
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    NETransparentProxyManager.loadAllFromPreferences {
      managers, error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(error))
          return
        }

        let ownedManagers = (managers ?? []).filter {
          AppRemovalPlan.ownsProxyConfiguration(
            providerBundleIdentifier: ($0.protocolConfiguration
              as? NETunnelProviderProtocol)?
              .providerBundleIdentifier
          )
        }
        self.removeConfigurations(
          ownedManagers[...],
          completion: completion
        )
      }
    }
  }

  func prepare(
    allowRecreateConfiguration: Bool = true,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    loadManager { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(.failure(Self.normalized(error)))
      case .success(let manager):
        if !allowRecreateConfiguration,
          (!manager.isEnabled
            || (manager.protocolConfiguration as? NETunnelProviderProtocol)?
              .providerBundleIdentifier
              != AppConfiguration.extensionBundleIdentifier)
        {
          completion(.failure(TransparentProxyControllerError.configurationMissing))
          return
        }
        self.prepare(
          manager,
          canRecreateConfiguration: allowRecreateConfiguration,
          completion: completion
        )
      }
    }
  }

  private func prepare(
    _ manager: NETransparentProxyManager,
    canRecreateConfiguration: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    configureIfNeeded(manager) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let configuredManager):
        self.retainManager(configuredManager)
        self.start(configuredManager) { startResult in
          switch startResult {
          case .success:
            completion(.success(()))
          case .failure(let error):
            guard canRecreateConfiguration else {
              completion(.failure(error))
              return
            }
            self.recreateConfiguration(
              replacing: configuredManager,
              completion: completion
            )
          }
        }
      }
    }
  }

  private func recreateConfiguration(
    replacing manager: NETransparentProxyManager,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    stop(manager) { [weak self] in
      manager.removeFromPreferences { error in
        DispatchQueue.main.async {
          guard let self else { return }
          if let error {
            completion(.failure(Self.normalized(error)))
            return
          }

          self.retainManager(nil)
          self.prepare(
            NETransparentProxyManager(),
            canRecreateConfiguration: false,
            completion: completion
          )
        }
      }
    }
  }

  func reconnect(
    target: ReconnectTarget,
    completion: @escaping (Result<ReconnectResponse, Error>) -> Void
  ) {
    loadManager { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let manager):
        self.retainManager(manager)
        self.ensureStarted(manager) { startResult in
          switch startResult {
          case .failure(let error):
            completion(.failure(error))
          case .success:
            self.sendReconnect(
              through: manager,
              target: target,
              completion: completion
            )
          }
        }
      }
    }
  }

  private func loadManager(
    completion: @escaping (Result<NETransparentProxyManager, Error>) -> Void
  ) {
    NETransparentProxyManager
      .loadAllFromPreferences { managers, error in
        DispatchQueue.main.async {
          if let error {
            completion(.failure(Self.normalized(error)))
            return
          }

          let matching = managers?.first {
            ($0.protocolConfiguration
              as? NETunnelProviderProtocol)?
              .providerBundleIdentifier
              == AppConfiguration.extensionBundleIdentifier
          }
          completion(.success(matching ?? NETransparentProxyManager()))
        }
      }
  }

  private func retainManager(
    _ manager: NETransparentProxyManager?
  ) {
    if let connectionStatusObserver {
      NotificationCenter.default.removeObserver(
        connectionStatusObserver
      )
      self.connectionStatusObserver = nil
    }
    retainedManager = manager
    guard let manager else {
      onConnectionStatusChanged?(.invalid)
      return
    }

    let connection = manager.connection
    connectionStatusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: connection,
      queue: .main
    ) { [weak self, weak connection] _ in
      guard let self, let connection else { return }
      self.onConnectionStatusChanged?(connection.status)
    }
    onConnectionStatusChanged?(connection.status)
  }

  private func removeConfigurations(
    _ managers: ArraySlice<NETransparentProxyManager>,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let manager = managers.first else {
      retainManager(nil)
      completion(.success(()))
      return
    }

    stop(manager) { [weak self] in
      manager.removeFromPreferences { error in
        DispatchQueue.main.async {
          if let error {
            completion(.failure(error))
            return
          }
          self?.removeConfigurations(
            managers.dropFirst(),
            completion: completion
          )
        }
      }
    }
  }

  private func stop(
    _ manager: NETransparentProxyManager,
    completion: @escaping () -> Void
  ) {
    manager.connection.stopVPNTunnel()
    waitUntilStopped(
      manager,
      deadline: Date(timeIntervalSinceNow: 5),
      completion: completion
    )
  }

  private func waitUntilStopped(
    _ manager: NETransparentProxyManager,
    deadline: Date,
    completion: @escaping () -> Void
  ) {
    switch manager.connection.status {
    case .disconnected, .invalid:
      completion()
      return
    default:
      break
    }

    guard Date() < deadline else {
      completion()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      [weak self] in
      self?.waitUntilStopped(
        manager,
        deadline: deadline,
        completion: completion
      )
    }
  }

  private func configureIfNeeded(
    _ manager: NETransparentProxyManager,
    completion: @escaping (Result<NETransparentProxyManager, Error>) -> Void
  ) {
    let protocolConfiguration =
      manager.protocolConfiguration as? NETunnelProviderProtocol
    let isCurrent =
      protocolConfiguration?.providerBundleIdentifier
      == AppConfiguration.extensionBundleIdentifier
      && manager.isEnabled

    guard !isCurrent else {
      completion(.success(manager))
      return
    }

    let configuration = NETunnelProviderProtocol()
    configuration.providerBundleIdentifier =
      AppConfiguration.extensionBundleIdentifier
    configuration.serverAddress = "Local Hearthstone proxy"
    configuration.providerConfiguration = [
      "gamePort": Int(ProxyConstants.gamePort)
    ]

    manager.localizedDescription = AppConfiguration.appName
    manager.protocolConfiguration = configuration
    manager.isEnabled = true
    manager.saveToPreferences { error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(Self.normalized(error)))
          return
        }
        manager.loadFromPreferences { reloadError in
          DispatchQueue.main.async {
            if let reloadError {
              completion(.failure(Self.normalized(reloadError)))
            } else {
              completion(.success(manager))
            }
          }
        }
      }
    }
  }

  private func start(
    _ manager: NETransparentProxyManager,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      if manager.connection.status != .connected
        && manager.connection.status != .connecting
      {
        try manager.connection.startVPNTunnel()
      }
      waitUntilConnected(
        manager,
        deadline: Date(timeIntervalSinceNow: 10),
        completion: completion
      )
    } catch {
      completion(.failure(Self.normalized(error)))
    }
  }

  private static func normalized(_ error: Error) -> Error {
    isConfigurationPermissionDenied(error)
      ? TransparentProxyControllerError
        .configurationPermissionDenied
      : error
  }

  private static func isConfigurationPermissionDenied(
    _ error: Error
  ) -> Bool {
    var candidate: NSError? = error as NSError
    var checked = Set<ObjectIdentifier>()

    while let current = candidate {
      let identifier = ObjectIdentifier(current)
      guard checked.insert(identifier).inserted else { break }

      if current.domain == NEVPNErrorDomain,
        current.code
          == NEVPNError.configurationReadWriteFailed.rawValue
      {
        return true
      }
      if current.domain == NSCocoaErrorDomain,
        current.code == NSUserCancelledError
      {
        return true
      }
      candidate = current.userInfo[NSUnderlyingErrorKey]
        as? NSError
    }
    return false
  }

  private func ensureStarted(
    _ manager: NETransparentProxyManager,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    if manager.connection.status == .connected {
      completion(.success(()))
      return
    }
    start(manager, completion: completion)
  }

  private func waitUntilConnected(
    _ manager: NETransparentProxyManager,
    deadline: Date,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    if manager.connection.status == .connected {
      completion(.success(()))
      return
    }
    guard Date() < deadline else {
      completion(
        .failure(TransparentProxyControllerError.startTimedOut)
      )
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      [weak self] in
      self?.waitUntilConnected(
        manager,
        deadline: deadline,
        completion: completion
      )
    }
  }

  private func sendReconnect(
    through manager: NETransparentProxyManager,
    target: ReconnectTarget,
    completion: @escaping (Result<ReconnectResponse, Error>) -> Void
  ) {
    guard
      let session = manager.connection
        as? NETunnelProviderSession
    else {
      completion(
        .failure(TransparentProxyControllerError.sessionUnavailable)
      )
      return
    }

    do {
      try session.sendProviderMessage(
        ProviderCommand.reconnect(target: target).encoded
      ) { data in
        DispatchQueue.main.async {
          guard let data else {
            completion(
              .failure(
                TransparentProxyControllerError.responseMissing
              )
            )
            return
          }
          do {
            completion(
              .success(
                try JSONDecoder().decode(
                  ReconnectResponse.self,
                  from: data
                )
              )
            )
          } catch {
            completion(
              .failure(
                TransparentProxyControllerError.responseInvalid
              )
            )
          }
        }
      }
    } catch {
      completion(.failure(error))
    }
  }
}
