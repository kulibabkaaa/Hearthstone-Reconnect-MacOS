import Foundation
import SystemExtensions

enum SystemExtensionActivationResult {
  case activated
  case requiresReboot
}

enum SystemExtensionDeactivationResult {
  case deactivated
  case requiresReboot
}

enum SystemExtensionControllerError: Error {
  case stateCheckTimedOut
}

final class SystemExtensionController:
  NSObject, OSSystemExtensionRequestDelegate
{
  var onApprovalRequired: (() -> Void)?
  var onDeactivationApprovalRequired: (() -> Void)?

  private enum Operation {
    case activation(
      (Result<SystemExtensionActivationResult, Error>) -> Void
    )
    case deactivation(
      (Result<SystemExtensionDeactivationResult, Error>) -> Void
    )
  }

  private var operation: Operation?
  private var pendingDeactivation: ((Result<SystemExtensionDeactivationResult, Error>) -> Void)?
  private var request: OSSystemExtensionRequest?
  /// How long a caller waits for sysextd. The request itself stays outstanding after this, so later checks
  /// wait for its answer instead of piling more requests onto a sysextd that is already slow.
  private static let stateCheckTimeout: TimeInterval = 5
  /// A properties request unanswered this long is treated as lost and replaced.
  private static let abandonedStateCheckAge: TimeInterval = 30
  /// An answer that arrives while no caller is waiting (just after a timeout) is handed to the next caller
  /// if it asks within this window, instead of being thrown away.
  private static let unclaimedResultLifetime: TimeInterval = 2

  private var propertiesRequest: OSSystemExtensionRequest?
  /// Monotonic time that keeps counting during sleep (see `monotonicNow`).
  private var propertiesRequestStartedAt: TimeInterval?
  private var unclaimedPropertiesResult: (
    result: Result<SystemExtensionRuntimeState, Error>,
    receivedAt: TimeInterval
  )?
  private var propertiesCompletions: [
    UUID: (Result<SystemExtensionRuntimeState, Error>) -> Void
  ] = [:]

  /// Seconds on a clock that can't jump with wall-clock changes but, unlike `systemUptime`, includes
  /// sleep, so a request left unanswered across a long sleep is replaced right after wake.
  private static var monotonicNow: TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
  }

  var isOperationPending: Bool {
    operation != nil
  }

  func currentState(
    completion: @escaping (
      Result<SystemExtensionRuntimeState, Error>
    ) -> Void
  ) {
    let now = Self.monotonicNow
    if let unclaimed = unclaimedPropertiesResult {
      unclaimedPropertiesResult = nil
      if now - unclaimed.receivedAt < Self.unclaimedResultLifetime {
        DispatchQueue.main.async { completion(unclaimed.result) }
        return
      }
    }

    let completionID = UUID()
    propertiesCompletions[completionID] = completion

    let hasLiveRequest =
      propertiesRequest != nil
      && propertiesRequestStartedAt.map {
        now - $0 < Self.abandonedStateCheckAge
      } == true
    if !hasLiveRequest {
      let request = OSSystemExtensionRequest.propertiesRequest(
        forExtensionWithIdentifier:
          AppConfiguration.extensionBundleIdentifier,
        queue: .main
      )
      request.delegate = self
      propertiesRequest = request
      propertiesRequestStartedAt = now
      OSSystemExtensionManager.shared.submitRequest(request)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + Self.stateCheckTimeout) {
      [weak self] in
      guard let self,
        let completion = self.propertiesCompletions.removeValue(
          forKey: completionID
        )
      else { return }
      completion(
        .failure(SystemExtensionControllerError.stateCheckTimedOut)
      )
    }
  }

  func activate(
    completion: @escaping (Result<SystemExtensionActivationResult, Error>) -> Void
  ) {
    guard operation == nil else { return }

    operation = .activation(completion)
    let request = OSSystemExtensionRequest.activationRequest(
      forExtensionWithIdentifier:
        AppConfiguration.extensionBundleIdentifier,
      queue: .main
    )
    request.delegate = self
    self.request = request
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  func deactivate(
    completion:
      @escaping (Result<SystemExtensionDeactivationResult, Error>) -> Void
  ) {
    guard operation == nil else {
      pendingDeactivation = completion
      return
    }

    operation = .deactivation(completion)
    let request = OSSystemExtensionRequest.deactivationRequest(
      forExtensionWithIdentifier:
        AppConfiguration.extensionBundleIdentifier,
      queue: .main
    )
    request.delegate = self
    self.request = request
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  func requestNeedsUserApproval(
    _ request: OSSystemExtensionRequest
  ) {
    switch operation {
    case .activation:
      onApprovalRequired?()
    case .deactivation:
      onDeactivationApprovalRequired?()
    case nil:
      break
    }
  }

  func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing:
      OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    .replace
  }

  func request(
    _ request: OSSystemExtensionRequest,
    didFinishWithResult result: OSSystemExtensionRequest.Result
  ) {
    guard request === self.request else { return }
    guard let operation = beginFinishing() else { return }
    switch operation {
    case .activation(let completion):
      completion(
        .success(
          result == .willCompleteAfterReboot
            ? .requiresReboot
            : .activated
        )
      )
    case .deactivation(let completion):
      completion(
        .success(
          result == .willCompleteAfterReboot
            ? .requiresReboot
            : .deactivated
        )
      )
    }
    startPendingDeactivationIfNeeded()
  }

  func request(
    _ request: OSSystemExtensionRequest,
    didFailWithError error: Error
  ) {
    if request === propertiesRequest {
      finishPropertiesRequest(.failure(error))
      return
    }
    guard request === self.request else { return }
    guard let operation = beginFinishing() else { return }
    switch operation {
    case .activation(let completion):
      completion(.failure(error))
    case .deactivation(let completion):
      if Self.isExtensionNotFound(error) {
        completion(.success(.deactivated))
      } else {
        completion(.failure(error))
      }
    }
    startPendingDeactivationIfNeeded()
  }

  func request(
    _ request: OSSystemExtensionRequest,
    foundProperties properties: [OSSystemExtensionProperties]
  ) {
    guard request === propertiesRequest else { return }
    let state = SystemExtensionRuntimeState.resolve(
      properties.map {
        SystemExtensionPropertyState(
          isEnabled: $0.isEnabled,
          isAwaitingUserApproval:
            $0.isAwaitingUserApproval,
          isUninstalling: $0.isUninstalling
        )
      }
    )
    finishPropertiesRequest(.success(state))
  }

  private func beginFinishing() -> Operation? {
    let operation = self.operation
    self.operation = nil
    request = nil
    return operation
  }

  private func startPendingDeactivationIfNeeded() {
    if let pendingDeactivation {
      self.pendingDeactivation = nil
      deactivate(completion: pendingDeactivation)
    }
  }

  private func finishPropertiesRequest(
    _ result: Result<SystemExtensionRuntimeState, Error>
  ) {
    propertiesRequest = nil
    propertiesRequestStartedAt = nil
    guard !propertiesCompletions.isEmpty else {
      unclaimedPropertiesResult = (result, Self.monotonicNow)
      return
    }
    let completions = propertiesCompletions.values
    propertiesCompletions.removeAll()
    completions.forEach { $0(result) }
  }

  private static func isExtensionNotFound(
    _ error: Error
  ) -> Bool {
    let error = error as NSError
    return error.domain == OSSystemExtensionErrorDomain
      && error.code
        == OSSystemExtensionError.Code.extensionNotFound.rawValue
  }
}
