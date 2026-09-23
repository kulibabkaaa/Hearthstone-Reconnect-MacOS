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
  private var propertiesRequest: OSSystemExtensionRequest?
  private var propertiesCompletions: [
    (Result<SystemExtensionRuntimeState, Error>) -> Void
  ] = []

  var isOperationPending: Bool {
    operation != nil
  }

  func currentState(
    completion: @escaping (
      Result<SystemExtensionRuntimeState, Error>
    ) -> Void
  ) {
    propertiesCompletions.append(completion)
    guard propertiesRequest == nil else { return }

    let request = OSSystemExtensionRequest.propertiesRequest(
      forExtensionWithIdentifier:
        AppConfiguration.extensionBundleIdentifier,
      queue: .main
    )
    request.delegate = self
    propertiesRequest = request
    OSSystemExtensionManager.shared.submitRequest(request)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      [weak self, weak request] in
      guard let self, let request,
        self.propertiesRequest === request
      else { return }
      self.finishPropertiesRequest(
        .failure(
          SystemExtensionControllerError.stateCheckTimedOut
        )
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
    let completions = propertiesCompletions
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
